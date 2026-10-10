#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 判定の表（PR の state・キューの状態（mergeQueueEntry とタイムラインの最後のキューの出入りのイベント）・外れた後の push → status）。
# 上から順に最初に当てはまったもの。
#
#   PR の state / 入力                                             status      その他
#   MERGED                                                          merged
#   CLOSED                                                          not_queued
#   OPEN でも、マージキューを使わない（ルールに merge_queue が無い）      not_queued  キューの状態を読まない
#   キューに並んでいる（mergeQueueEntry がある）                    waiting     queue に state・position。入れた直後で実行が無くても
#   並んでおらず、最後が外れたイベントで理由が merged               waiting     （PR が MERGED に変わる直前）
#   並んでおらず、最後が外れたイベントで、入れた後に push が無い    removed     removed に reason・at。CI の失敗なら failed に
#                                                                               失敗したチェック（外れたイベントのコミットの実行）。
#                                                                               衝突（merge_conflict）なら failed は空
#   並んでおらず、最後が外れたイベントで、入れた後に push がある    not_queued  （直して、まだ入れ直していない。並んでいる間の
#                                                                               push で外れたときも。push は外れた時刻より前になる）
#   並んでおらず、最後が入れたイベント                              waiting     （並んだ直後）
#   並んでおらず、イベントも無い                                    not_queued
#   フォークからの PR は push を読まない（外れたままなら removed）
#   push を読めなければ、warn を出して removed（止まらない）
#
# 偽の gh。
# - gh pr view ... --json ...   $FIX/pr-<n>.json（n は pr view の呼び出し回数。無ければ $FIX/pr.json）を返す
# - gh api graphql --input -    $FIX/gql-<n>.json（無ければ $FIX/gql.json）を返す。$FIX/gql-fail があれば失敗する
# - gh api repos/<owner>/<repo>/activity?...  $FIX/activity.json を返す。$FIX/activity-fail があれば失敗する
# - gh run list ...             $FIX/runs.json を返す。引数に --event merge_group が無ければ失敗する
# - gh api --paginate repos/.../rules/branches/...  $FIX/rules.json（既定は merge_queue のルールあり）を返す
# - それ以外（書き込みを含む）は、$CALLS に「WRITE <引数>」を記録して失敗する
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
pick() { # pick <名前>: 呼び出し回数に合うファイルを選ぶ
  local n
  n="$(grep -c "^READ $1 " "$CALLS" || true)"
  if [ -f "$FIX/$1-$n.json" ]; then cat "$FIX/$1-$n.json"; else cat "$FIX/$1.json"; fi
}
case "$1 $2" in
  "pr view") pick pr; echo "READ pr $*" >>"$CALLS" ;;
  "api graphql")
    [ ! -f "$FIX/gql-fail" ] || { echo "READ gql-failed" >>"$CALLS"; echo "gh: GraphQL が失敗しました" >&2; exit 1; }
    pick gql; echo "READ gql $(tr '\n' ' ')" >>"$CALLS"
    ;;
  "run list")
    case " $* " in *" --event merge_group "*) ;; *) echo "gh: --event merge_group が無い" >&2; exit 1 ;; esac
    cat "$FIX/runs.json"; echo "READ runs $*" >>"$CALLS"
    ;;
  "api --paginate") cat "$FIX/rules.json" ;;
  "api repos/"*/activity\?*)
    [ ! -f "$FIX/activity-fail" ] || { echo "READ activity-failed" >>"$CALLS"; echo "gh: 権限がありません" >&2; exit 1; }
    cat "$FIX/activity.json"; echo "READ activity $*" >>"$CALLS"
    ;;
  *) echo "WRITE $*" >>"$CALLS"; echo "gh: 想定外の呼び出し: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
  pr_json '{}'
  gql_json '{}'
  echo '[]' >"$FIX/runs.json"
  echo '[]' >"$FIX/activity.json"
  echo '[{"type": "merge_queue"}, {"type": "pull_request"}]' >"$FIX/rules.json"
}

# PR の JSON を作る。使い方: pr_json <既定の値に上書きするオブジェクト（jq の式）> [ファイル名（既定 pr.json）]
pr_json() {
  jq -n "$1 as \$o | "'{number: 5, url: "https://github.com/me/demo/pull/5", state: "OPEN", baseRefName: "main",
    headRefName: "feat/5-x", isCrossRepository: false} + $o' >"$FIX/${2:-pr.json}"
}

# GraphQL の答えを作る。使い方: gql_json <PR の既定の値に上書きするオブジェクト（jq の式）> [ファイル名（既定 gql.json）]
# 既定はキューに並んでおらず、キューの出入りのイベントも無い
gql_json() {
  jq -n "$1 as \$o | "'{data: {resource: ({mergeQueueEntry: null, timelineItems: {nodes: []}} + $o)}}' >"$FIX/${2:-gql.json}"
}

# キューに並んでいる。使い方: queued <state> [ファイル名]
queued() { gql_json "{mergeQueueEntry: {state: \"$1\", position: 1}, timelineItems: {nodes: [{__typename: \"AddedToMergeQueueEvent\", createdAt: \"2026-10-01T00:00:00Z\"}]}}" "${2:-gql.json}"; }

# 最後のイベントがキューから外れたイベント。使い方: removed_ev <reason> <時刻> [beforeCommit の oid] [ファイル名]
removed_ev() {
  jq -n --arg r "$1" --arg t "$2" --arg o "${3:-}" '{data: {resource: {mergeQueueEntry: null, timelineItems: {nodes: [
    {__typename: "RemovedFromMergeQueueEvent", reason: $r, createdAt: $t,
     beforeCommit: (if $o == "" then null else {oid: $o} end)}]}}}}' >"$FIX/${4:-gql.json}"
}

# キューに入れた（00:05）後に外れた。使い方: added_removed_ev <reason> <外れた時刻> [beforeCommit の oid]
added_removed_ev() {
  jq -n --arg r "$1" --arg t "$2" --arg o "${3:-}" '{data: {resource: {mergeQueueEntry: null, timelineItems: {nodes: [
    {__typename: "AddedToMergeQueueEvent", createdAt: "2026-10-01T00:05:00Z"},
    {__typename: "RemovedFromMergeQueueEvent", reason: $r, createdAt: $t,
     beforeCommit: (if $o == "" then null else {oid: $o} end)}]}}}}' >"$FIX/gql.json"
}

# PR のブランチへの push の activity を作る。使い方: activity <activity_type> <時刻>...（2つずつ）
activity() {
  local a=()
  while [ $# -ge 2 ]; do
    a+=("$(jq -nc --arg ty "$1" --arg t "$2" '{ref: "refs/heads/feat/5-x", activity_type: $ty, timestamp: $t}')")
    shift 2
  done
  printf '%s\n' "${a[@]}" | jq -s . >"$FIX/activity.json"
}

# キューの実行を1つ作る。使い方: qrun <ブランチ> <status> <conclusion（null か文字列）> <名前> <作った時刻>
qrun() {
  jq -nc --arg b "$1" --arg s "$2" --arg c "$3" --arg n "$4" --arg t "$5" \
    '{headBranch: $b, status: $s, conclusion: (if $c == "null" then null else $c end), name: $n, workflowName: $n,
      url: "https://github.com/me/demo/actions/runs/\($n)-\($t)", createdAt: $t}'
}
Q5=gh-readonly-queue/main/pr-5-aaa

# 実行の一覧にする。使い方: runs_file <ファイル名> <qrun の出力>...
runs_file() { local f="$1"; shift; printf '%s\n' "$@" | jq -s . >"$FIX/$f"; }

st() { jq -r .status <<<"$output"; }

setup() {
  test_helper_setup
  setup_fake_gh
}

teardown() { rm -rf "$TMP"; }

@test "表: MERGED は merged" {
  pr_json '{state: "MERGED"}'
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" merged
}

@test "表: CLOSED は not_queued（キューから外れたイベントが残っていても）" {
  pr_json '{state: "CLOSED"}'
  removed_ev failed_checks 2026-10-01T00:00:00Z
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
}

@test "表: キューを使わないリポジトリでは、キューに並んでいても OPEN は not_queued" {
  echo '[{"type": "pull_request"}]' >"$FIX/rules.json"
  queued AWAITING_CHECKS
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
  assert_equal "$(jq -r .merge_queue <<<"$output")" false
}

@test "キューの状態は、OPEN でキューを使うときだけ読む（MERGED・CLOSED・キューを使わないときは GraphQL が失敗しても動きを変えない）" {
  echo 'GraphQL を呼んだ' >"$FIX/gql-fail"
  pr_json '{state: "MERGED"}'
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" merged
  pr_json '{state: "CLOSED"}'
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" not_queued
  pr_json '{}'
  echo '[]' >"$FIX/rules.json"
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
  if grep -q '^READ gql' "$CALLS"; then fail "GraphQL を呼んでいます"; fi
  # キューを使うときは読み、読めなければ失敗する
  echo '[{"type": "merge_queue"}]' >"$FIX/rules.json"
  run_script pr-merge-status.sh --pr 5
  assert_failure
}

@test "表: ルールを読めないときは、キューを使わないものとして not_queued" {
  rm "$FIX/rules.json"
  queued AWAITING_CHECKS
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
}

@test "表: キューを使わなくても MERGED は merged" {
  echo '[]' >"$FIX/rules.json"
  pr_json '{state: "MERGED"}'
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" merged
}

@test "表: キューに並んでいれば waiting で、キューでの状態と順番を返す" {
  queued AWAITING_CHECKS
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" waiting
  assert_equal "$(jq -c .queue <<<"$output")" '{"state":"AWAITING_CHECKS","position":1}'
  assert_equal "$(jq -c '[.removed, .queue_runs, .failed]' <<<"$output")" '[null,[],[]]'
  # GraphQL は PR の URL で引く
  grep -q '^READ gql .*"url": *"https://github.com/me/demo/pull/5"' "$CALLS"
}

@test "表: キューに入れた直後（キューの CI の実行も自動マージの予約も無い）でも、並んでいれば waiting（#323）" {
  queued QUEUED
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" waiting
}

@test "表: CI が通ってマージを待っている（MERGEABLE）も waiting" {
  queued MERGEABLE
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" waiting
  assert_equal "$(jq -r .queue.state <<<"$output")" MERGEABLE
}

@test "表: 並んだ直後で mergeQueueEntry にまだ出ていなくても、最後が入れたイベントなら waiting" {
  gql_json '{timelineItems: {nodes: [{__typename: "AddedToMergeQueueEvent", createdAt: "2026-10-01T00:00:00Z"}]}}'
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" waiting
  assert_equal "$(jq -c .queue <<<"$output")" null
}

@test "表: 最後が merged で外れたイベントなら（PR が MERGED に変わる直前）waiting" {
  removed_ev merged 2026-10-01T00:00:00Z sha1
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" waiting
  if grep -q '^READ \(runs\|activity\)' "$CALLS"; then fail "外れたときだけ読むものを読んでいます"; fi
}

@test "表: OPEN で、並んでおらずイベントも無ければ not_queued" {
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
  assert_equal "$(jq -c '[.queue, .removed, .queue_runs, .failed]' <<<"$output")" "[null,null,[],[]]"
}

@test "表: CI が失敗して外れたら removed で、外れたイベントのコミットの実行から失敗したチェックと URL を返す" {
  removed_ev failed_checks 2026-10-01T00:10:00Z sha1
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)" "$(qrun $Q5 completed success lint 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" removed
  assert_equal "$(jq -c .removed <<<"$output")" '{"reason":"failed_checks","at":"2026-10-01T00:10:00Z"}'
  assert_equal "$(jq -c .failed <<<"$output")" '[{"name":"test","url":"https://github.com/me/demo/actions/runs/test-2026-10-01T00:00:00Z"}]'
  assert_equal "$(jq -r '.queue_runs | length' <<<"$output")" 2
}

@test "キューの CI の実行は、外れたイベントのコミットで絞って読む（リポジトリ全体の新しい方から数えない。#323）" {
  removed_ev failed_checks 2026-10-01T00:10:00Z sha1
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_success
  grep -q '^READ runs .*--commit sha1' "$CALLS" || fail "コミットで絞っていません: $(cat "$CALLS")"
}

@test "表: キューの実行が取り消し（cancelled）で終わって外れたときも removed で、failed に入る" {
  removed_ev failed_checks 2026-10-01T00:10:00Z sha1
  runs_file runs.json "$(qrun $Q5 completed cancelled test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" removed
  assert_equal "$(jq -r '.failed[0].name' <<<"$output")" test
}

@test "表: コンフリクトで外れた（CI の実行が無い）ときも removed で、failed は空（#323）" {
  removed_ev merge_conflict 2026-10-01T00:10:00Z
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" removed
  assert_equal "$(jq -r .removed.reason <<<"$output")" merge_conflict
  assert_equal "$(jq -c '[.queue_runs, .failed]' <<<"$output")" '[[],[]]'
  if grep -q '^READ runs' "$CALLS"; then fail "コミットが無いのに実行を読んでいます"; fi
}

@test "表: 外れた後に修正を push して、まだ入れ直していなければ not_queued（#323）" {
  removed_ev failed_checks 2026-10-01T00:10:00Z sha1
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)"
  activity push 2026-10-01T00:20:00Z
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
  assert_equal "$(jq -c '[.removed, .failed]' <<<"$output")" '[null,[]]'
  # PR の URL のリポジトリの、PR のブランチの activity を読む
  grep -q '^READ activity api repos/me/demo/activity?ref=refs%2Fheads%2Ffeat%2F5-x&' "$CALLS" || fail "$(cat "$CALLS")"
  # force push も push として数える
  activity force_push 2026-10-01T00:20:00Z
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" not_queued
}

@test "表: キューに入れる前の push や、push 以外の activity では removed のまま" {
  added_removed_ev merge_conflict 2026-10-01T00:10:00Z
  activity push 2026-10-01T00:04:00Z branch_creation 2026-10-01T00:20:00Z
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" removed
}

@test "表: キューに並んでいる間の push で外れた（push の時刻が外れた時刻より前）ときも、入れた時刻より後の push として not_queued（#323）" {
  added_removed_ev dequeued 2026-10-01T00:10:00Z
  activity push 2026-10-01T00:07:00Z
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
}

@test "外れた後の push を読めなければ、warn を出して removed を返す（--wait でも止まらない。#323）" {
  added_removed_ev merge_conflict 2026-10-01T00:10:00Z
  echo 'activity を読めない' >"$FIX/activity-fail"
  out="$(DW_WAIT_SLEEP=0 "${TEST_BASH:-bash}" "$SCRIPTS/pr-merge-status.sh" --pr 5 --wait 2>"$TMP/err")"
  assert_equal "$(jq -c '[.status, .removed.reason]' <<<"$out")" '["removed","merge_conflict"]'
  grep -q '^warn: PR のブランチへの push を読めないので' "$TMP/err" || fail "warn がありません: $(cat "$TMP/err")"
}

@test "表: 直して入れ直したら、古い失敗の実行が残っていても waiting（#323）" {
  queued QUEUED
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)"
  activity push 2026-10-01T00:20:00Z
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" waiting
}

@test "フォークからの PR は、外れた後の push を読まずに removed" {
  pr_json '{isCrossRepository: true}'
  removed_ev merge_conflict 2026-10-01T00:10:00Z
  echo 'activity を呼んだ' >"$FIX/activity-fail"
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" removed
  if grep -q '^READ activity' "$CALLS"; then fail "フォークの PR で activity を読んでいます"; fi
}

@test "PR の base がマージ先になる（develop へのキュー）" {
  pr_json '{baseRefName: "develop"}'
  queued QUEUED
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" waiting
  assert_equal "$(jq -r .pr.base <<<"$output")" develop
}

@test "--pr・--branch・省略で、gh pr view に渡す引数が変わる" {
  run_script pr-merge-status.sh --pr '#5'
  assert_success
  grep -q '^READ pr pr view 5 --json' "$CALLS"
  : >"$CALLS"
  run_script pr-merge-status.sh --branch feat/5-x
  assert_success
  grep -q '^READ pr pr view feat/5-x --json' "$CALLS"
  : >"$CALLS"
  run_script pr-merge-status.sh
  assert_success
  grep -q '^READ pr pr view --json' "$CALLS"
}

@test "--wait: waiting の間は繰り返し、merged になったら終わる" {
  queued AWAITING_CHECKS
  pr_json '{state: "MERGED"}' pr-2.json
  DW_WAIT_SLEEP=0 run_script pr-merge-status.sh --pr 5 --wait --interval 300
  assert_success
  assert_equal "$(st)" merged
  assert_equal "$(grep -c '^READ pr ' "$CALLS")" 3
  assert_equal "$(jq -r 'has("timed_out")' <<<"$output")" false
}

@test "--wait: 並んでいた PR が CI の失敗で外れたら removed で終わる" {
  queued AWAITING_CHECKS gql-0.json
  removed_ev failed_checks 2026-10-01T00:10:00Z sha1 gql-1.json
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)"
  DW_WAIT_SLEEP=0 run_script pr-merge-status.sh --pr 5 --wait
  assert_success
  assert_equal "$(st)" removed
  assert_equal "$(jq -r '.failed[0].name' <<<"$output")" test
}

@test "--wait: 時間切れになったら waiting のまま timed_out を付けて出力する（間隔の合計で数える）" {
  queued AWAITING_CHECKS
  DW_WAIT_SLEEP=0 run_script pr-merge-status.sh --pr 5 --wait --interval 300 --timeout 900
  assert_success
  assert_equal "$(st)" waiting
  assert_equal "$(jq -r .timed_out <<<"$output")" true
  # 最初の1回と、300 秒ごとの 3 回
  assert_equal "$(grep -c '^READ pr ' "$CALLS")" 4
}

@test "--wait: waiting でなければ待たずに出力する（not_queued）" {
  DW_WAIT_SLEEP=0 run_script pr-merge-status.sh --pr 5 --wait
  assert_success
  assert_equal "$(st)" not_queued
  assert_equal "$(grep -c '^READ pr ' "$CALLS")" 1
}

@test "--wait なしは1回だけ確かめる" {
  queued AWAITING_CHECKS
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" waiting
  assert_equal "$(grep -c '^READ pr ' "$CALLS")" 1
}

@test "GitHub に書き込まない" {
  queued AWAITING_CHECKS
  run_script pr-merge-status.sh --pr 5 --wait --timeout 0
  assert_success
  removed_ev failed_checks 2026-10-01T00:10:00Z sha1
  activity push 2026-10-01T00:20:00Z
  run_script pr-merge-status.sh --pr 5
  assert_success
  if grep -q '^WRITE' "$CALLS"; then fail "GitHub に書き込んでいます: $(cat "$CALLS")"; fi
}

@test "引数の誤りは終了コード 64" {
  for a in "--pr" "--branch" "--interval x" "--interval 0" "--timeout -1" "--pr 5 --branch b" "--bogus" "--pr abc"; do
    # shellcheck disable=SC2086
    run_script pr-merge-status.sh $a
    assert_failure
    [ "$status" -eq 64 ] || { echo "$a: $status"; return 1; }
  done
  DW_WAIT_SLEEP=x run_script pr-merge-status.sh --pr 5
  assert_failure 64
}

@test "PR・キューの状態・実行を読めなければ失敗する" {
  rm "$FIX/pr.json"
  run_script pr-merge-status.sh --pr 5
  assert_failure
  pr_json '{}'
  echo '{"errors": [{"message": "x"}]}' >"$FIX/gql.json"
  run_script pr-merge-status.sh --pr 5
  assert_failure
  assert_output --partial "マージキューの状態を読めません"
  removed_ev failed_checks 2026-10-01T00:10:00Z sha1
  echo '{"message": "x"}' >"$FIX/runs.json"
  run_script pr-merge-status.sh --pr 5
  assert_failure
  assert_output --partial "実行を読めません"
}

@test "--help は使い方を出す" {
  run_script pr-merge-status.sh --help
  assert_success
  assert_output --partial "使い方"
}
