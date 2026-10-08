#!/usr/bin/env bash
# PR を見回すときに、今すぐ Claude を動かして直すべきかを、PR の今の状態だけから決めて JSON で出力する。
# 何も変えない（読むだけ）。状態は持たない（前回の結果を覚えない）ので、後から人が push したり指摘が付いたりすれば、
# 次に呼んだときに自動で変わる。対応するものが無い回で Claude を動かさないために、先にこのスクリプトで決める（#286）。
#
# 使い方: pr-watch.sh [--pr N]
#   --pr N   PR の番号（#N でもよい）。省略すると今のブランチの PR
#
# 出力（JSON）:
#   pr        number・url・state・draft・head_sha
#   action    idle（何もしない）・wait（待つ）・act（対応する）・conflict（コンフリクトを直す）のどれか
#   reasons   action の理由（文字列の配列。下の表）
#   details   failed_checks（失敗したチェックの名前）・unanswered（対応が要る指摘の数。threads・reviews・comments）・
#             waiting_for（最初のレビューを待っている投稿者）
#
# 判定（上から順に最初に当てはまったもの。ただし act の理由は、当てはまるものをすべて並べる）:
#   1. idle  not_open      PR が OPEN でない（マージ済み・閉じた）
#            draft         ドラフトの PR（対象外）
#            fork          フォークからの PR（対象外。push できない）
#   2. wait  in_merge_queue  マージキューに入っている（キューの結果を待つ）
#   3. conflict  conflicting  main などとコンフリクトしている（mergeable が CONFLICTING、または merge_state が DIRTY）
#                behind       base_branch に遅れている（merge_state が BEHIND）
#   4. act   ci_failed             CI のチェックが失敗している
#            unresolved_threads    resolved でないスレッドで、PR の作者がまだ返事をしていないものがある
#            unanswered_reviews    変更の要求か本文のあるレビューで、その後に PR の作者のコメントが無いものがある
#            unanswered_comments   PR のコメント（作者以外）で、その後に PR の作者のコメントが無いものがある
#   5. wait  ci_pending            CI が実行中
#            awaiting_review:<投稿者>  設定の pr_check.handlers の投稿者（CodeRabbit など）の最初のレビューが、まだ付いていない
#                                  （PR を作ってから 60 分たつまで待つ。障害などで際限なく待たないため）
#            mergeable_unknown     GitHub がマージできるかを計算中（mergeable が UNKNOWN）
#   6. idle  nothing_to_do  上のどれでもない（CI が全部通るか無く、対応する指摘も無い）
#
# 決まり:
#   - 材料は pr-feedback.sh の出力と、GraphQL で読むマージキューの状態・作成時刻・フォークか・レビューの投稿者（PR の URL から引く）
#     （マージキューの状態は gh pr view に無い。設計書 §10）
#   - テストのため、環境変数 PR_WATCH_NOW（UNIX 秒）で今の時刻を差し替えられる
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# 最初のレビューを待つ時間の上限（分）
review_wait_minutes=60

pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || dw_die "--pr に値がありません" 64
      pr="$2"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -z "$pr" ] || pr="$(dw_number --pr "$pr" PR)"

# pr-feedback.sh のエラー（終了コードと1行のメッセージ）はそのまま伝える
if [ -n "$pr" ]; then
  fb="$("$BASH" "$DW_SCRIPTS_DIR/pr-feedback.sh" --pr "$pr")" || exit $?
else
  fb="$("$BASH" "$DW_SCRIPTS_DIR/pr-feedback.sh")" || exit $?
fi
number="$(jq -r .pr.number <<<"$fb")"
# マージキューの状態などは gh pr view にも REST にも無いので GraphQL で読む（設計書 §10）。PR の URL から引くので、
# リポジトリの所有者と名前を別に調べなくてよい（branch-status.sh と同じ）。
# reviews は新しい方の 100 件だけ見る。超えても、待つのは PR を作ってから 60 分までなので害は小さい
# shellcheck disable=SC2016 # GraphQL の変数（$url）を bash に展開させないため、シングルクォートで書く
res="$(dw_gql 'query PrWatch($url: URI!) {
    resource(url: $url) {
      ... on PullRequest {
        createdAt isCrossRepository
        mergeQueueEntry { state }
        reviews(last: 100) { nodes { author { login } } }
      }
    }
  }' "$(jq -c '{url: .pr.url}' <<<"$fb")" 2>&1)" \
  || dw_die "PR #${number} のマージキューの状態を読めません: $res"
jq -e '.data.resource | type == "object" and has("createdAt")' >/dev/null 2>&1 <<<"$res" \
  || dw_die "PR #${number} のマージキューの状態を読めません: $res"

now="${PR_WATCH_NOW:-$(date -u +%s)}"

# jq の変数（$f など）を bash に展開させないため、シングルクォートで書く
# shellcheck disable=SC2016
jq -n --argjson f "$fb" --argjson g "$(jq -c .data.resource <<<"$res")" \
  --argjson now "$now" --argjson wait_min "$review_wait_minutes" '
  def norm: ascii_downcase | sub("\\[bot\\]$"; "");
  ($f.pr) as $p
  | ($f.own_comments | map(.created_at) | max // "") as $last_own
  | ([$f.feedback[] | .threads[] | select(.replied | not)] | length) as $n_threads
  | ([$f.feedback[].reviews[]
      | select(.state == "CHANGES_REQUESTED" or .body != "")
      | select(.submitted_at > $last_own)] | length) as $n_reviews
  | ([$f.feedback[].comments[] | select(.created_at > $last_own)] | length) as $n_comments
  # 最初のレビューを待つ投稿者。担当の skill がある投稿者のうち、レビュー・スレッド・コメントのどれも付けていない人
  | ([$g.reviews.nodes[].author.login // empty | norm] + [$f.feedback[].author | norm]) as $arrived
  | (($now - ($g.createdAt | fromdateiso8601)) < ($wait_min * 60)) as $in_wait_window
  | (if $in_wait_window then [$f.handlers | keys[] | select(norm as $k | $arrived | index($k) | not)] else [] end) as $waiting_for
  | ($p.merge_state) as $ms
  | (if $p.state != "OPEN" then {action: "idle", reasons: ["not_open"]}
     elif $p.draft then {action: "idle", reasons: ["draft"]}
     elif $g.isCrossRepository then {action: "idle", reasons: ["fork"]}
     elif $g.mergeQueueEntry != null then {action: "wait", reasons: ["in_merge_queue"]}
     elif $p.mergeable == "CONFLICTING" or $ms == "DIRTY" or $ms == "BEHIND" then
       {action: "conflict", reasons: ([if $p.mergeable == "CONFLICTING" or $ms == "DIRTY" then "conflicting" else empty end,
                                       if $ms == "BEHIND" then "behind" else empty end])}
     elif $f.checks.state == "failure" or $n_threads > 0 or $n_reviews > 0 or $n_comments > 0 then
       {action: "act", reasons: ([if $f.checks.state == "failure" then "ci_failed" else empty end,
                                  if $n_threads > 0 then "unresolved_threads" else empty end,
                                  if $n_reviews > 0 then "unanswered_reviews" else empty end,
                                  if $n_comments > 0 then "unanswered_comments" else empty end])}
     elif $f.checks.state == "pending" or ($waiting_for | length) > 0 or $p.mergeable == "UNKNOWN" then
       {action: "wait", reasons: ([if $f.checks.state == "pending" then "ci_pending" else empty end,
                                   ($waiting_for[] | "awaiting_review:" + .),
                                   if $p.mergeable == "UNKNOWN" then "mergeable_unknown" else empty end])}
     else {action: "idle", reasons: ["nothing_to_do"]} end) as $d
  | {pr: {number: $p.number, url: $p.url, state: $p.state, draft: $p.draft, head_sha: $p.head_sha},
     action: $d.action, reasons: $d.reasons,
     details: {failed_checks: [$f.checks.failed[].name],
               unanswered: {threads: $n_threads, reviews: $n_reviews, comments: $n_comments},
               waiting_for: $waiting_for}}'
