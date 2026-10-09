#!/usr/bin/env bash
# PR のマージの状態を1回確かめて、JSON で出力する。PR がマージキューから外れたまま（CI の失敗・衝突など）かも見分ける。
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
#               removed      キューから外れたまま（PR は OPEN のまま。外れた後に push も入れ直しもしていない）。
#                            理由は removed.reason（CI の失敗なら failed_checks、衝突なら merge_conflict など GitHub の値）
#               waiting      キューに並んでいる（CI が動いている、または通ってマージを待っている）
#               not_queued   キューに入っていない（OPEN の PR で、並んでおらず、外れた後に push した、または一度も入れていない）、
#                            または PR が閉じている
#   merge_queue base ブランチへのマージがマージキューを通すか（true・false）
#   queue       キューに並んでいるときの状態（state・position）。state は GitHub の値（QUEUED・AWAITING_CHECKS・
#               MERGEABLE・UNMERGEABLE・LOCKED）で、AWAITING_CHECKS は CI が動いている、MERGEABLE は通ってマージを待っている。
#               並んでいなければ null
#   removed     status が removed のときの、外れた理由と時刻（{reason, at}）。それ以外は null
#   queue_runs  status が removed のときの、外れる原因になったキューの CI の実行のチェック（name・conclusion・status・url）。
#               それ以外や、CI を動かす前に外れた（衝突など）ときは空
#   failed      キューの CI で失敗したチェック（name・url）。status が removed のときだけ入る
#   timed_out   --wait が時間切れで終わったときだけ true（status は waiting のまま）
#
# 判定（branch-status.sh・pr-watch.sh と同じく、キューの状態は GraphQL で読む。ADR 000323）:
#   - PR の state が MERGED なら merged。CLOSED なら not_queued
#   - base ブランチへのマージがマージキューを通さない（ブランチに効いているルールに merge_queue が無い。読めないときも同じ）なら、
#     OPEN の PR は not_queued。キューを使わないリポジトリ（strict と branch-update の方式）の動きを変えないため
#   - キューを使うとき、PR の mergeQueueEntry があれば（並んでいる。入れた直後で CI がまだ動いていなくても）waiting
#   - 並んでいなければ、タイムラインのキューの出入りのイベントの最後を見る
#     - 最後が外れたイベント（RemovedFromMergeQueueEvent）で、理由が merged なら waiting（PR の state が MERGED に
#       変わる直前。次に確かめれば merged になる）
#     - それ以外の理由で、外れた後に PR のブランチへの push（リポジトリの activity の push・force_push。common.sh の
#       dw_pushed_since。branch-status.sh と共通）が無ければ removed。push があれば、直して入れ直す前なので not_queued。
#       フォークからの PR は push を読めないので、removed のまま
#     - 最後が入れたイベント（AddedToMergeQueueEvent）なら waiting（並んだ直後で、まだ mergeQueueEntry に出ていない）
#     - イベントが無ければ not_queued
#   - removed のとき、外れたイベントのコミット（beforeCommit。キューの一時的なブランチのコミット）の merge_group の実行を、
#     gh run list --commit で読み、queue_runs と failed に入れる（衝突などで CI を動かす前に外れたときは、コミットが無いので空）
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
  local view base queue res q pushed run_json sha
  view="$(gh pr view ${pr:+"$pr"} ${branch:+"$branch"} --json number,url,state,baseRefName,headRefName,isCrossRepository 2>&1)" \
    || dw_die "PR を読めません: $view"
  jq -e 'type == "object" and has("number") and has("state")' >/dev/null 2>&1 <<<"$view" \
    || dw_die "PR を読めません: $view"
  base="$(jq -r .baseRefName <<<"$view")"
  # キューを使うかは、ブランチに効いているルールで決める（pr-create.sh・doctor.sh と同じ読み方）。読めなければ使わないものとして扱う
  queue=false
  if [ "$(jq -r .state <<<"$view")" = OPEN ]; then
    queue="$(dw_merge_queue_enabled '{owner}/{repo}' "$base")" || queue=false
  fi
  # キューの状態は、OPEN でキューを使うときだけ読む（MERGED・CLOSED やキューを使わないリポジトリでは、読めなくても動きを変えない）
  q='{"entry": null, "event": null}'
  pushed=false
  run_json='[]'
  if [ "$queue" = true ]; then
    # キューに並んでいるか（mergeQueueEntry）とキューから外れたイベント（RemovedFromMergeQueueEvent）は、gh pr view にも
    # REST にも無いので GraphQL で読む（設計書 §10・ADR 000323。branch-status.sh と同じ読み方）。PR は URL で引く。
    # 外れたことはタイムラインの最後のキューの出入りのイベントで見る（衝突で外れると CI の実行が作られず、
    # mergeQueueEntry もすぐに null になるため）
    # shellcheck disable=SC2016 # GraphQL の変数（$url）を bash に展開させないため、シングルクォートで書く
    res="$(dw_gql 'query PrMergeStatus($url: URI!) {
        resource(url: $url) {
          ... on PullRequest {
            mergeQueueEntry { state position }
            timelineItems(itemTypes: [ADDED_TO_MERGE_QUEUE_EVENT, REMOVED_FROM_MERGE_QUEUE_EVENT], last: 1) {
              nodes {
                __typename
                ... on AddedToMergeQueueEvent { createdAt }
                ... on RemovedFromMergeQueueEvent { reason createdAt beforeCommit { oid } }
              }
            }
          }
        }
      }' "$(jq -c '{url}' <<<"$view")" 2>&1)" \
      || dw_die "マージキューの状態を読めません: $res"
    q="$(jq -c '.data.resource | select(type == "object" and has("mergeQueueEntry"))
      | {entry: .mergeQueueEntry, event: (.timelineItems.nodes[0] // null)}' <<<"$res" 2>/dev/null)" || q=""
    [ -n "$q" ] || dw_die "マージキューの状態を読めません: $res"

    # 外れたまま（並んでおらず、最後が merged 以外の理由で外れたイベント）のときだけ、外れた後の push と失敗した CI を読む
    if jq -e '.entry == null and .event.__typename == "RemovedFromMergeQueueEvent" and .event.reason != "merged"' >/dev/null <<<"$q"; then
      # 外れた後に push したか（直して、まだ入れ直していないか）は、PR のブランチへの push の時刻で見る（branch-status.sh と共通。
      # フォークからの PR は読まずに false）
      pushed="$(dw_pushed_since "$(jq -r .url <<<"$view")" "$(jq -r .headRefName <<<"$view")" \
        "$(jq -r .isCrossRepository <<<"$view")" "$(jq -r .event.createdAt <<<"$q")" 2>&1)" \
        || dw_die "PR のブランチへの push を読めません: $pushed"
      # 外れる原因になったキューの CI は、外れたイベントのコミット（キューの一時的なブランチのコミット）で絞って読む。
      # リポジトリ全体の merge_group の実行の新しい方から数えると、忙しいリポジトリでは自分の実行が窓から外れうるため
      sha="$(jq -r '.event.beforeCommit.oid // empty' <<<"$q")"
      if [ -n "$sha" ]; then
        run_json="$(gh run list --event merge_group --commit "$sha" --limit 100 --json name,workflowName,status,conclusion,url 2>&1)" \
          || dw_die "マージキューの CI の実行を読めません: $run_json"
        jq -e 'type == "array"' >/dev/null 2>&1 <<<"$run_json" \
          || dw_die "マージキューの CI の実行を読めません: $run_json"
      fi
    fi
  fi

  # jq の変数（$v など）を bash に展開させないため、シングルクォートで書く
  # shellcheck disable=SC2016
  printf '%s\n' "$view" "$q" "$run_json" | jq -s --argjson qe "$queue" --argjson pushed "$pushed" '
    def failed: . as $r | ["failure", "cancelled", "timed_out", "startup_failure"] | index($r.conclusion // "") != null;
    .[0] as $v | .[1] as $q | .[2] as $runs
    | ($q.event // null) as $ev
    | ($ev != null and $ev.__typename == "RemovedFromMergeQueueEvent") as $was_removed
    | (if $v.state == "MERGED" then "merged"
       elif $v.state != "OPEN" or $qe != true then "not_queued"
       elif $q.entry != null then "waiting"
       elif $was_removed and $ev.reason == "merged" then "waiting"
       elif $was_removed and ($pushed | not) then "removed"
       elif $was_removed then "not_queued"
       elif $ev != null and $ev.__typename == "AddedToMergeQueueEvent" then "waiting"
       else "not_queued" end) as $s
    | ([$runs[] | {name: (if (.workflowName // "") != "" then .workflowName else .name end),
                   conclusion: (.conclusion // null), status, url}]) as $checks
    | {pr: {number: $v.number, url: $v.url, state: $v.state, base: $v.baseRefName, branch: $v.headRefName},
       status: $s, merge_queue: ($qe == true),
       queue: (if $s == "waiting" and $q.entry != null then {state: $q.entry.state, position: $q.entry.position} else null end),
       removed: (if $s == "removed" then {reason: $ev.reason, at: $ev.createdAt} else null end),
       queue_runs: (if $s == "removed" then $checks else [] end),
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
