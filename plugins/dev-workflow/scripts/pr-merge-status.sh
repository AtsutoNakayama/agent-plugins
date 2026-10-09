#!/usr/bin/env bash
# PR のマージの状態を1回確かめて、JSON で出力する。マージキューの CI が失敗して PR がキューから外れたことも見分ける。
# 何も変えない（読むだけ）。task-finish が、マージ前に呼ばれたときの待ち方を決めるために使う（gh-pr-check からも使える）。
#
# 使い方: pr-merge-status.sh [--pr N | --branch ブランチ] [--wait [--interval 秒] [--timeout 秒]]
#   --pr N          PR の番号（#N でもよい）
#   --branch NAME   PR のブランチ名。--pr と同時には使えない。どちらも省略すると今のブランチの PR
#   --wait          status が waiting の間、繰り返し確かめて、waiting 以外になるか時間切れになったら出力する
#   --interval 秒   --wait の確かめる間隔（既定 300 = 5分）
#   --timeout 秒    --wait の時間切れ（既定 3600 = 60分）。待った秒数（間隔の合計）で数える
#   待つ秒数は環境変数 DW_WAIT_SLEEP で差し替えられる（テスト用。DW_RETRY_SLEEP と同じ形。時間切れの数え方は変わらない）
#
# 出力（JSON）:
#   pr          number・url・state（OPEN・MERGED・CLOSED）・base（マージ先）・branch
#   status      merged       マージ済み
#               removed      マージキューの CI が失敗して、キューから外れた（PR は OPEN のまま）
#               waiting      マージキューの CI が動いている、または通ってマージを待っている
#               not_queued   キューに入っていない（OPEN の PR で、キューの CI も自動マージの予約も無い）、または PR が閉じている
#   merge_queue base ブランチへのマージがマージキューを通すか（true・false）
#   queue_runs  base ブランチのキューの一番新しい実行の、チェック（name・conclusion・status・url）。実行が無ければ空
#   failed      キューの CI で失敗したチェック（name・url）。status が removed のときだけ入る
#   timed_out   --wait が時間切れで終わったときだけ true（status は waiting のまま）
#
# 判定:
#   - PR の state が MERGED なら merged。CLOSED なら not_queued
#   - base ブランチへのマージがマージキューを通さない（ブランチに効いているルールに merge_queue が無い。読めないときも同じ）なら、
#     OPEN の PR は not_queued。キューを使わないリポジトリ（strict と branch-update の方式）の動きを変えないため
#   - キューを使うとき、gh run list --event merge_group を、ブランチ gh-readonly-queue/<base>/pr-<番号>- に絞って読む
#     （GraphQL は使わない）。PR ごとに実行のブランチが違うので、一番新しい実行のブランチだけを見る。
#     失敗（failure・cancelled・timed_out・startup_failure）があれば removed（自動マージの予約が残っていても）。
#     なければ、動いている実行があれば waiting
#   - 失敗も動いている実行も無いとき、実行がすべて成功していれば（マージ待ち）waiting。実行が無ければ、
#     autoMergeRequest（gh pr view。「マージ待ち」の予約）があれば waiting、無ければ not_queued
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

pr="" branch="" wait=false interval=300 timeout=3600
while [ $# -gt 0 ]; do
  case "$1" in
    --pr)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || dw_die "--pr に値がありません" 64
      pr="$2"
      shift 2
      ;;
    --branch)
      { [ $# -ge 2 ] && [ -n "$2" ]; } || dw_die "--branch に値がありません" 64
      branch="$2"
      shift 2
      ;;
    --wait) wait=true; shift ;;
    --interval | --timeout)
      { [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]]; } || dw_die "$1 に秒数（0 以上の整数）がありません" 64
      if [ "$1" = --interval ]; then interval="$2"; else timeout="$2"; fi
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -z "$pr" ] || [ -z "$branch" ] || dw_die "--pr と --branch は同時に使えません" 64
[ -z "$pr" ] || pr="$(dw_number --pr "$pr" PR)"
[ -z "${DW_WAIT_SLEEP:-}" ] || [[ "$DW_WAIT_SLEEP" =~ ^[0-9]+$ ]] || dw_die "DW_WAIT_SLEEP は秒数（0 以上の整数）にしてください" 64
[ "$interval" -ge 1 ] || dw_die "--interval は 1 以上にしてください" 64

# 1回確かめる。結果の JSON を標準出力に出す
check_once() {
  local view base queue run_json
  view="$(gh pr view ${pr:+"$pr"} ${branch:+"$branch"} --json number,url,state,baseRefName,headRefName,autoMergeRequest 2>&1)" \
    || dw_die "PR を読めません: $view"
  jq -e 'type == "object" and has("number") and has("state")' >/dev/null 2>&1 <<<"$view" \
    || dw_die "PR を読めません: $view"
  base="$(jq -r .baseRefName <<<"$view")"
  # キューを使うかは、ブランチに効いているルールで決める（pr-create.sh・doctor.sh と同じ読み方）。読めなければ使わないものとして扱う
  queue=false
  if [ "$(jq -r .state <<<"$view")" = OPEN ]; then
    queue="$(dw_merge_queue_enabled '{owner}/{repo}' "$base")" || queue=false
  fi
  # キューの実行は、OPEN でキューを使うときだけ読む（MERGED・CLOSED やキューを使わないリポジトリでは、Actions が無効でも権限が無くても動きを変えない）
  run_json='[]'
  if [ "$queue" = true ]; then
    # --limit は、キューに並んだ PR が多くても、この PR の実行を取りこぼさないよう大きめにする
    run_json="$(gh run list --event merge_group --limit 200 --json headBranch,name,workflowName,status,conclusion,url,createdAt 2>&1)" \
      || dw_die "マージキューの CI の実行を読めません: $run_json"
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$run_json" \
      || dw_die "マージキューの CI の実行を読めません: $run_json"
  fi

  # jq の変数（$v など）を bash に展開させないため、シングルクォートで書く
  # shellcheck disable=SC2016
  jq -n --argjson v "$view" --argjson q "$queue" --argjson runs "$run_json" '
    def failed: . as $r | ["failure", "cancelled", "timed_out", "startup_failure"] | index($r.conclusion // "") != null;
    ("gh-readonly-queue/" + $v.baseRefName + "/pr-" + ($v.number | tostring) + "-") as $prefix
    | ([$runs[] | select(.headBranch | startswith($prefix))]) as $mine
    | (if ($mine | length) == 0 then []
       else ($mine | max_by(.createdAt) | .headBranch) as $b | [$mine[] | select(.headBranch == $b)] end) as $latest
    | ([$latest[] | {name: (if (.workflowName // "") != "" then .workflowName else .name end),
                     conclusion: (.conclusion // null), status, url}]) as $checks
    | (if $v.state == "MERGED" then "merged"
       elif $v.state != "OPEN" or $q != true then "not_queued"
       elif any($latest[]; failed) then "removed"
       elif any($latest[]; .status != "completed") then "waiting"
       elif ($latest | length) > 0 then "waiting"
       elif $v.autoMergeRequest != null then "waiting"
       else "not_queued" end) as $s
    | {pr: {number: $v.number, url: $v.url, state: $v.state, base: $v.baseRefName, branch: $v.headRefName},
       status: $s, merge_queue: ($q == true),
       queue_runs: $checks,
       failed: (if $s == "removed" then [$checks[] | select(failed) | {name, url}] else [] end)}'
}

out="$(check_once)"
waited=0
timed_out=false
if [ "$wait" = true ]; then
  while [ "$(jq -r .status <<<"$out")" = waiting ]; do
    if [ "$waited" -ge "$timeout" ]; then timed_out=true; break; fi
    sleep "${DW_WAIT_SLEEP:-$interval}"
    waited=$((waited + interval))
    out="$(check_once)"
  done
fi
jq --argjson t "$timed_out" \
  '. + (if $t then {timed_out: true} else {} end)' <<<"$out"
