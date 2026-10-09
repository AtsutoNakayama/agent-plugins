#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 判定の表（PR の state・自動マージの予約・マージキューの実行 → status）。上から順に最初に当てはまったもの。
#
#   PR の state / 入力                                         status      その他
#   MERGED                                                      merged
#   CLOSED                                                      not_queued
#   OPEN でも、マージキューを使わない（ルールに merge_queue が無い）  not_queued  autoMergeRequest や実行があっても
#   キューを使い、一番新しいキューのブランチに失敗した実行がある  removed     failed に失敗したチェックと URL（autoMergeRequest が残っていても）
#   キューを使い、そのブランチに動いている実行がある            waiting
#   キューを使い、実行が無く autoMergeRequest がある            waiting
#   キューを使い、実行も予約も無い                              not_queued
#   OPEN で、そのブランチの実行がすべて成功                     waiting     （マージ待ち）
#   別の PR（pr-50- と pr-5-）や別の base のキューの実行は見ない
#
# 偽の gh。
# - gh pr view ... --json ...   $FIX/pr-<n>.json（n は pr view の呼び出し回数。無ければ $FIX/pr.json）を返す
# - gh run list ...             $FIX/runs-<n>.json（無ければ $FIX/runs.json）を返す。引数に --event merge_group が無ければ失敗する
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
  n="$(grep -c "^READ $1" "$CALLS" || true)"
  if [ -f "$FIX/$1-$n.json" ]; then cat "$FIX/$1-$n.json"; else cat "$FIX/$1.json"; fi
}
case "$1 $2" in
  "pr view") pick pr; echo "READ pr $*" >>"$CALLS" ;;
  "run list")
    [ ! -f "$FIX/run-fail" ] || { echo "READ runs-failed" >>"$CALLS"; echo "gh: Actions が無効です" >&2; exit 1; }
    case " $* " in *" --event merge_group "*) ;; *) echo "gh: --event merge_group が無い" >&2; exit 1 ;; esac
    pick runs; echo "READ runs $*" >>"$CALLS"
    ;;
  "api --paginate") cat "$FIX/rules.json" ;;
  *) echo "WRITE $*" >>"$CALLS"; echo "gh: 想定外の呼び出し: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
  pr_json '{}'
  echo '[]' >"$FIX/runs.json"
  echo '[{"type": "merge_queue"}, {"type": "pull_request"}]' >"$FIX/rules.json"
}

# PR の JSON を作る。使い方: pr_json <既定の値に上書きするオブジェクト（jq の式）> [ファイル名（既定 pr.json）]
pr_json() {
  jq -n "$1 as \$o | "'{number: 5, url: "https://github.com/me/demo/pull/5", state: "OPEN", baseRefName: "main",
    headRefName: "feat/5-x", autoMergeRequest: null} + $o' >"$FIX/${2:-pr.json}"
}

# キューの実行を1つ作る。使い方: qrun <ブランチ> <status> <conclusion（null か文字列）> <名前> <作った時刻>
qrun() {
  jq -nc --arg b "$1" --arg s "$2" --arg c "$3" --arg n "$4" --arg t "$5" \
    '{headBranch: $b, status: $s, conclusion: (if $c == "null" then null else $c end), name: $n, workflowName: $n,
      url: "https://github.com/me/demo/actions/runs/\($n)-\($t)", createdAt: $t}'
}
Q5=gh-readonly-queue/main/pr-5-aaa
Q5B=gh-readonly-queue/main/pr-5-bbb

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

@test "表: CLOSED は not_queued（実行が残っていても）" {
  pr_json '{state: "CLOSED"}'
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
}

@test "表: OPEN で autoMergeRequest があれば waiting" {
  pr_json '{autoMergeRequest: {enabledAt: "2026-10-01T00:00:00Z"}}'
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" waiting
}

@test "表: キューを使わないリポジトリでは、予約や実行があっても OPEN は not_queued" {
  echo '[{"type": "pull_request"}]' >"$FIX/rules.json"
  pr_json '{autoMergeRequest: {enabledAt: "2026-10-01T00:00:00Z"}}'
  runs_file runs.json "$(qrun $Q5 in_progress null test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
  assert_equal "$(jq -r .merge_queue <<<"$output")" false
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" not_queued
}

@test "キューの実行は、OPEN でキューを使うときだけ読む（MERGED・CLOSED・キューを使わないときは gh run list が失敗しても動きを変えない）" {
  echo 'run list を呼んだ' >"$FIX/run-fail"
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
  if grep -q '^READ runs' "$CALLS"; then fail "gh run list を呼んでいます"; fi
  # キューを使うときは読み、読めなければ失敗する
  echo '[{"type": "merge_queue"}]' >"$FIX/rules.json"
  run_script pr-merge-status.sh --pr 5
  assert_failure
}

@test "表: ルールを読めないときは、キューを使わないものとして not_queued" {
  rm "$FIX/rules.json"
  pr_json '{autoMergeRequest: {enabledAt: "2026-10-01T00:00:00Z"}}'
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

@test "表: 失敗した実行は、自動マージの予約が残っていても removed（予約より先に見る）" {
  pr_json '{autoMergeRequest: {enabledAt: "2026-10-01T00:00:00Z"}}'
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)" "$(qrun $Q5 in_progress null lint 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" removed
}

@test "表: OPEN で実行も予約も無ければ not_queued" {
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" not_queued
  assert_equal "$(jq -c '[.queue_runs, .failed]' <<<"$output")" "[[],[]]"
}

@test "表: 動いている実行があれば waiting" {
  runs_file runs.json "$(qrun $Q5 in_progress null test 2026-10-01T00:00:00Z)" "$(qrun $Q5 completed success lint 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" waiting
}

@test "表: 失敗した実行があれば removed で、失敗したチェックと URL を返す" {
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)" "$(qrun $Q5 completed success lint 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" removed
  assert_equal "$(jq -c .failed <<<"$output")" '[{"name":"test","url":"https://github.com/me/demo/actions/runs/test-2026-10-01T00:00:00Z"}]'
  assert_equal "$(jq -r '.queue_runs | length' <<<"$output")" 2
}

@test "表: 実行がすべて成功していて PR が OPEN なら、マージ待ちの waiting" {
  runs_file runs.json "$(qrun $Q5 completed success test 2026-10-01T00:00:00Z)" "$(qrun $Q5 completed success lint 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_success
  assert_equal "$(st)" waiting
}

@test "表: キューの実行が取り消し（cancelled）で終わったときも removed" {
  runs_file runs.json "$(qrun $Q5 completed cancelled test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" removed
}

@test "古い失敗したキューのブランチではなく、一番新しいブランチを見る（入れ直した後は waiting）" {
  runs_file runs.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)" "$(qrun $Q5B in_progress null test 2026-10-01T01:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" waiting
  assert_equal "$(jq -r '.queue_runs | length' <<<"$output")" 1
}

@test "別の PR（pr-50-）や別の base のキューの失敗は見ない" {
  runs_file runs.json "$(qrun gh-readonly-queue/main/pr-50-aaa completed failure test 2026-10-01T00:00:00Z)" \
    "$(qrun gh-readonly-queue/develop/pr-5-aaa completed failure test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" not_queued
}

@test "PR の base がマージ先になる（develop へのキュー）" {
  pr_json '{baseRefName: "develop"}'
  runs_file runs.json "$(qrun gh-readonly-queue/develop/pr-5-aaa completed failure test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" removed
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
  runs_file runs.json "$(qrun $Q5 in_progress null test 2026-10-01T00:00:00Z)"
  pr_json '{state: "MERGED"}' pr-2.json
  DW_WAIT_SLEEP=0 run_script pr-merge-status.sh --pr 5 --wait --interval 300
  assert_success
  assert_equal "$(st)" merged
  assert_equal "$(grep -c '^READ pr ' "$CALLS")" 3
  assert_equal "$(jq -r 'has("timed_out")' <<<"$output")" false
}

@test "--wait: 動いている実行が失敗に変わったら removed で終わる" {
  runs_file runs-0.json "$(qrun $Q5 in_progress null test 2026-10-01T00:00:00Z)"
  runs_file runs-1.json "$(qrun $Q5 completed failure test 2026-10-01T00:00:00Z)"
  DW_WAIT_SLEEP=0 run_script pr-merge-status.sh --pr 5 --wait
  assert_success
  assert_equal "$(st)" removed
  assert_equal "$(jq -r '.failed[0].name' <<<"$output")" test
}

@test "--wait: 時間切れになったら waiting のまま timed_out を付けて出力する（間隔の合計で数える）" {
  runs_file runs.json "$(qrun $Q5 in_progress null test 2026-10-01T00:00:00Z)"
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
  runs_file runs.json "$(qrun $Q5 in_progress null test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5
  assert_equal "$(st)" waiting
  assert_equal "$(grep -c '^READ pr ' "$CALLS")" 1
}

@test "GitHub に書き込まない" {
  runs_file runs.json "$(qrun $Q5 in_progress null test 2026-10-01T00:00:00Z)"
  run_script pr-merge-status.sh --pr 5 --wait --timeout 0
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

@test "PR や実行を読めなければ失敗する" {
  rm "$FIX/pr.json"
  run_script pr-merge-status.sh --pr 5
  assert_failure
  pr_json '{}'
  echo '{"message": "x"}' >"$FIX/runs.json"
  run_script pr-merge-status.sh --pr 5
  assert_failure
}

@test "--help は使い方を出す" {
  run_script pr-merge-status.sh --help
  assert_success
  assert_output --partial "使い方"
}
