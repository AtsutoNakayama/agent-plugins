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
#               removed      キューから外れたまま（PR は OPEN のまま。キューに入れた後に push も、入れ直しもしていない）。
#                            理由は removed.reason（CI の失敗なら failed_checks、衝突なら merge_conflict など GitHub の値）
#               waiting      キューの中（並んでいる（CI がまだ動いていない・動いている・通ってマージを待っている）、入れた直後、
#                            またはマージの直前）
#               not_queued   キューに入っていない（OPEN の PR で、キューの中でなく、入れた後に push した、または一度も入れていない）、
#                            または PR が閉じている
#   merge_queue base ブランチへのマージがマージキューを通すか（true・false）
#   queue       キューに並んでいるときの状態（state・position）。state は GitHub の値（QUEUED・AWAITING_CHECKS・
#               MERGEABLE・UNMERGEABLE・LOCKED）で、QUEUED は入れた直後で CI がまだ動いていない、AWAITING_CHECKS は CI が
#               動いている、MERGEABLE は通ってマージを待っている。waiting でも、入れた直後でまだ並びに出ていないときや、
#               マージの直前（merged の理由で外れた直後）は null。waiting でなければ null
#   removed     status が removed のときの、外れた理由と時刻（{reason, at}）。それ以外は null
#   queue_runs  status が removed のときの、外れる原因になったキューの CI の実行のチェック（name・conclusion・status・url）。
#               それ以外や、CI を動かす前に外れた（衝突など）ときは空
#   failed      キューの CI で失敗したチェック（name・url）。status が removed のときだけ入る
#   timed_out   --wait が時間切れで終わったときだけ true（status は waiting のまま）
#
# 判定（キューの状態は GraphQL で読む。読み方と、並んでいる・外れたままの判定は branch-status.sh と共通で、common.sh の
# dw_merge_queue_state にある。ADR 000323）:
#   - PR の state が MERGED なら merged。CLOSED なら not_queued
#   - base ブランチへのマージがマージキューを通さない（ブランチに効いているルールに merge_queue が無い。読めないときも同じ）なら、
#     OPEN の PR は not_queued。キューを使わないリポジトリ（strict と branch-update の方式）の動きを変えないため
#   - キューを使うとき、キューの中（mergeQueueEntry がある。入れた直後で、まだ mergeQueueEntry に出ていない、または
#     merged の理由で外れた直後（マージの直前）も含む）なら waiting。並んでいれば queue に state・position を入れる
#   - キューから外れたまま（最後が merged 以外の理由で外れたイベントで、最後にキューに入れた時刻より後に PR のブランチへの
#     push（リポジトリの activity の push・force_push）が無い）なら removed。push があれば、直して入れ直す前なので
#     not_queued。フォークからの PR は push を読めないので removed のまま。push を読めなければ、warn を出して removed
#   - それ以外（イベントが無いなど）は not_queued
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
  local view base queue ms run_json sha
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
  # キューの状態は、OPEN でキューを使うときだけ読む（MERGED・CLOSED やキューを使わないリポジトリでは、読めなくても動きを変えない）。
  # 読み方と判定（並んでいる・外れたまま・入っていない）は branch-status.sh と共通（common.sh の dw_merge_queue_state）
  ms='{"queued": false, "removed": null, "before_commit": null}'
  run_json='[]'
  if [ "$queue" = true ]; then
    ms="$(dw_merge_queue_state "$(jq -r .url <<<"$view")" "$(jq -r .headRefName <<<"$view")" \
      "$(jq -r .isCrossRepository <<<"$view")")" || dw_die "マージキューの状態を読めません: $ms"
    # 外れる原因になったキューの CI は、外れたイベントのコミット（キューの一時的なブランチのコミット）で絞って読む。
    # リポジトリ全体の merge_group の実行の新しい方から数えると、忙しいリポジトリでは自分の実行が窓から外れうるため
    sha="$(jq -r '.before_commit // empty' <<<"$ms")"
    if [ -n "$sha" ]; then
      run_json="$(gh run list --event merge_group --commit "$sha" --limit 100 --json name,workflowName,status,conclusion,url 2>&1)" \
        || dw_die "マージキューの CI の実行を読めません: $run_json"
      jq -e 'type == "array"' >/dev/null 2>&1 <<<"$run_json" \
        || dw_die "マージキューの CI の実行を読めません: $run_json"
    fi
  fi

  # jq の変数（$v など）を bash に展開させないため、シングルクォートで書く
  # shellcheck disable=SC2016
  printf '%s\n' "$view" "$ms" "$run_json" | jq -s --argjson qe "$queue" '
    def failed: . as $r | ["failure", "cancelled", "timed_out", "startup_failure"] | index($r.conclusion // "") != null;
    .[0] as $v | .[1] as $m | .[2] as $runs
    | (if $v.state == "MERGED" then "merged"
       elif $v.state != "OPEN" or $qe != true then "not_queued"
       elif $m.queued then "waiting"
       elif $m.removed != null then "removed"
       else "not_queued" end) as $s
    | ([$runs[] | {name: (if (.workflowName // "") != "" then .workflowName else .name end),
                   conclusion: (.conclusion // null), status, url}]) as $checks
    | {pr: {number: $v.number, url: $v.url, state: $v.state, base: $v.baseRefName, branch: $v.headRefName},
       status: $s, merge_queue: ($qe == true),
       queue: (if $s == "waiting" and $m.state != null then {state: $m.state, position: $m.position} else null end),
       removed: (if $s == "removed" then $m.removed else null end),
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
