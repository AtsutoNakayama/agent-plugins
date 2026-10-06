#!/usr/bin/env bats
# git の操作のあとに、関連する PR・Issue・CI のリンクを出すフック（hooks/pr-link.sh）。

load test_helper
load fake_gh

HOOKS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/hooks"

setup() {
  test_helper_setup
  # 作業用のブランチ（Issue 17）に移る
  git switch -q -c feat/17-demo
  setup_fake_gh
}

# フックの入力（JSON）を作って渡す。使い方: run_hook <コマンド> [出力（標準出力）] [cwd]
run_hook() {
  jq -n --arg c "$1" --arg o "${2:-}" --arg d "${3:-$PWD}" \
    '{hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: $c}, tool_response: {stdout: $o, stderr: "", interrupted: false}, cwd: $d}' \
    >"$TMP/input.json"
  run "${TEST_BASH:-bash}" "$HOOKS/pr-link.sh" <"$TMP/input.json"
}

# リンクを出す。使用者の画面（systemMessage）と Claude（additionalContext）の両方に、同じリンクを伝える
# 使い方: shows <コマンド> <含むべき文字>...
shows() {
  local c="$1" want
  shift
  run_hook "$c"
  [ "$status" -eq 0 ] || fail "止めてしまった（$status）: $c / $output"
  jq -e . <<<"$output" >/dev/null || fail "JSON を出していない: $c / $output"
  assert_equal "$(jq -r .hookSpecificOutput.hookEventName <<<"$output")" PostToolUse
  [[ "$(jq -r .hookSpecificOutput.additionalContext <<<"$output")" == "$(jq -r .systemMessage <<<"$output")"* ]] \
    || fail "additionalContext が systemMessage で始まっていない: $output"
  for want in "$@"; do
    [[ "$(jq -r .systemMessage <<<"$output")" == *"$want"* ]] || fail "$want が無い: $c / $output"
  done
}

# 何も出さずに通す
silent() {
  local c
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 0 ] || fail "止めてしまった（$status）: $c / $output"
    [ -z "$output" ] || fail "何か出した: $c / $output"
  done
}

# 移った先を確かめるために、Issue 23 のブランチのワークツリー（$TMP/wt）を作る
make_wt() {
  fake_issue 23 '["feat"]'
  git worktree add -q -b feat/23-x "$TMP/wt"
}

# 移った先のブランチ（feat/23-x）の Issue・PR・CI を出し、移る前のブランチ（feat/17-demo）のものは出さない。
# 使い方: shows_wt <コマンド> [cwd]
shows_wt() {
  run_hook "$1" "" "${2:-$PWD}"
  [ "$status" -eq 0 ] || fail "止めてしまった（$status）: $1 / $output"
  [[ "$(jq -r .systemMessage <<<"$output")" == *"Issue #23: https://github.com/me/demo/issues/23"* ]] || fail "移った先の Issue が無い: $1 / $output"
  [[ "$output" != *"issues/17"* ]] || fail "移る前の Issue を出した: $1 / $output"
}

@test "hooks.json は Bash の後にフックを呼び、呼ぶスクリプトがある" {
  jq -e '.hooks.PostToolUse[0].matcher == "Bash"' "$HOOKS/hooks.json"
  run jq -r '.hooks.PostToolUse[0].hooks[0].command' "$HOOKS/hooks.json"
  # ${CLAUDE_PLUGIN_ROOT} は Claude Code が置き換える文字なので、そのまま比べる
  # shellcheck disable=SC2016
  assert_output 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/pr-link.sh"'
  [ -f "$HOOKS/pr-link.sh" ]
}

@test "git push の後に、開いた PR と Issue と CI のリンクを出す" {
  echo '[{"url": "https://github.com/me/demo/pull/42", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  shows "git push -u origin feat/17-demo" \
    "PR: https://github.com/me/demo/pull/42" \
    "Issue #17: https://github.com/me/demo/issues/17" \
    "CI: https://github.com/me/demo/pull/42/checks"
}

@test "PR が無い git push では、PR を作る URL と、ブランチの CI の実行ページを出す" {
  shows "git push -u origin feat/17-demo" \
    "PR を作る: https://github.com/me/demo/pull/new/feat/17-demo" \
    "CI: https://github.com/me/demo/actions?query=branch%3Afeat%2F17-demo" \
    "Issue #17: https://github.com/me/demo/issues/17"
}

@test "fork からの PR は、自分の PR として出さない" {
  echo '[{"url": "https://github.com/me/demo/pull/9", "isCrossRepository": true}]' >"$FIX/pr-list.json"
  shows "git push" "PR を作る:"
  [[ "$output" != *"pull/9"* ]]
}

@test "git commit の後に、Issue のリンクだけを出す" {
  echo '[{"url": "https://github.com/me/demo/pull/42", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  shows "git commit -m x" "Issue #17: https://github.com/me/demo/issues/17"
  [[ "$output" != *"pull/42"* ]]
  [ "$(called pr-list)" -eq 0 ]
}

@test "commit.sh 経由でも出す" {
  shows "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh\" --message x" "Issue #17: https://github.com/me/demo/issues/17"
}

@test "ブランチを作るコマンドの後に、Issue のリンクを出す" {
  local c
  for c in "git switch -c feat/17-demo" "git switch --create feat/17-demo" "git checkout -b feat/17-demo" \
    "git worktree add -b feat/17-demo ../wt" "git branch feat/17-demo"; do
    shows "$c" "Issue #17: https://github.com/me/demo/issues/17"
  done
}

@test "ブランチを作るコマンドは、今のブランチではなく、作るブランチの Issue を出す" {
  fake_issue 23 '["feat"]'
  shows "git branch feat/23-x" "Issue #23: https://github.com/me/demo/issues/23"
  [[ "$output" != *"issues/17"* ]]
  shows "git switch -c feat/23-x" "Issue #23: https://github.com/me/demo/issues/23"
  shows "git checkout -b feat/23-x origin/main" "Issue #23: https://github.com/me/demo/issues/23"
  git switch -q main
  shows "git worktree add -b feat/23-x ../wt" "Issue #23: https://github.com/me/demo/issues/23"
  shows "cd .. && git worktree add ../wt -b \"feat/23-x\"" "Issue #23: https://github.com/me/demo/issues/23"
}

@test "-b を付けない git worktree add <パス> <ブランチ> でも、そのブランチの Issue を出す" {
  fake_issue 23 '["feat"]'
  git switch -q main
  shows "git worktree add ../wt feat/23-x" "Issue #23: https://github.com/me/demo/issues/23"
  shows "git worktree add --reason 作業 ../wt feat/23-x" "Issue #23: https://github.com/me/demo/issues/23"
  shows "git worktree add -f ../wt \"feat/23-x\"" "Issue #23: https://github.com/me/demo/issues/23"
  # パスだけのときは、ブランチの名前を拾えないので、今のブランチの Issue も出さない
  git switch -q feat/17-demo
  silent "git worktree add ../wt"
}

@test "作るブランチの名前に Issue の番号が無い、またはブランチを作らないときは、今のブランチの Issue を出さない" {
  fake_issue 23 '["feat"]'
  silent "git branch scratch" "git switch -c scratch" "git branch --set-upstream-to origin/main feat/23-x"
}

@test "guard-git.sh が名前を確かめる書き方（-cname・-qc name・--create=name）でも、作るブランチの Issue を出す" {
  fake_issue 23 '["feat"]'
  local c
  for c in "git switch -cfeat/23-x" "git switch -qc feat/23-x" "git switch --create=feat/23-x" "git checkout -qbfeat/23-x" \
    "git branch -f feat/23-x"; do
    shows "$c" "Issue #23: https://github.com/me/demo/issues/23"
    [[ "$output" != *"issues/17"* ]] || fail "今のブランチの Issue を出した: $c / $output"
  done
}

@test "task-start.sh 経由では、出力の Issue の番号を使う（main の上からでも出す）" {
  fake_issue 23 '["feat"]'
  git switch -q main
  run_hook "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/task-start.sh\" --issue 23 --slug x" '{"issue": 23, "branch": "feat/23-x"}'
  [ "$status" -eq 0 ]
  assert_equal "$(jq -r .systemMessage <<<"$output" | tail -n 1)" "- Issue #23: https://github.com/me/demo/issues/23"
}

@test "task-start.sh の出力から Issue の番号を取れないときは、今のブランチの Issue を出さない" {
  silent "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/task-start.sh\" --issue 23 --slug x"
  run_hook "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/task-start.sh\" --issue 23 --slug x" 'not json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "task-start.sh の標準エラーに警告があっても、標準出力の Issue の番号を読む" {
  fake_issue 23 '["feat"]'
  jq -n --arg d "$PWD" '{tool_input: {command: "bash task-start.sh --issue 23 --slug x"},
    tool_response: {stdout: "{\n  \"issue\": 23,\n  \"branch\": \"feat/23-x\"\n}\n", stderr: "warn: サブモジュールを初期化できません\n"}, cwd: $d}' >"$TMP/input.json"
  run "${TEST_BASH:-bash}" "$HOOKS/pr-link.sh" <"$TMP/input.json"
  [ "$status" -eq 0 ]
  [[ "$(jq -r .systemMessage <<<"$output")" == *"Issue #23: https://github.com/me/demo/issues/23"* ]]
}

@test "hooks.json のフックにはタイムアウトがある（gh が詰まっても、作業を止めない）" {
  jq -e '.hooks.PostToolUse[0].hooks[0].timeout | . > 0 and . <= 30' "$HOOKS/hooks.json"
}

@test "gh pr create・gh issue create の後に、作った PR・Issue の URL を出す（main の上でも）" {
  git switch -q main
  run_hook "gh pr create --title x" "https://github.com/me/demo/pull/42"
  [ "$status" -eq 0 ]
  assert_equal "$(jq -r .systemMessage <<<"$output")" "$(printf '関連するリンク:\n- PR: https://github.com/me/demo/pull/42')"
  run_hook "gh issue create --title x" "https://github.com/me/demo/issues/50"
  [ "$status" -eq 0 ]
  assert_equal "$(jq -r .systemMessage <<<"$output")" "$(printf '関連するリンク:\n- Issue: https://github.com/me/demo/issues/50')"
}

@test "pr-create.sh・issue-create.sh 経由でも出す。出力の JSON の URL を拾い、重複させない" {
  run_hook "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/pr-create.sh\"" \
    '{"url": "https://github.com/me/demo/pull/42", "pr": {"url": "https://github.com/me/demo/pull/42"}}'
  [ "$status" -eq 0 ]
  msg="$(jq -r .systemMessage <<<"$output")"
  assert_equal "$(grep -c 'pull/42$' <<<"$msg")" 1
  [[ "$msg" == *"Issue #17: https://github.com/me/demo/issues/17"* ]]
  run_hook "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/issue-create.sh\" --title x" '{"number": 50, "url": "https://github.com/me/demo/issues/50"}'
  [ "$status" -eq 0 ]
  [[ "$(jq -r .systemMessage <<<"$output")" == *"Issue: https://github.com/me/demo/issues/50"* ]]
}

@test "作った PR・Issue は、出力の url から拾い、body の中の別の URL は拾わない" {
  run_hook "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/pr-create.sh\"" \
    '{"created": true, "pr": {"number": 42, "url": "https://github.com/me/demo/pull/42"}, "body": "Closes https://github.com/me/demo/issues/99 と https://github.com/me/demo/pull/7"}'
  [ "$status" -eq 0 ]
  [[ "$(jq -r .systemMessage <<<"$output")" == *"pull/42"* ]]
  [[ "$output" != *"issues/99"* && "$output" != *"pull/7"* ]]
  run_hook "gh pr create --body x" "Creating pull request for feat/17-demo into main
https://github.com/me/demo/pull/42"
  [ "$status" -eq 0 ]
  [[ "$(jq -r .systemMessage <<<"$output")" == *"PR: https://github.com/me/demo/pull/42"* ]]
}

@test "--dry-run や git push -n では、何もしていないので何も出さない" {
  silent "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/pr-create.sh\" --issue 17 --dry-run" \
    "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/commit.sh\" --message x --dry-run" \
    "git push --dry-run" "git push -n origin feat/17-demo" "git commit --dry-run -m x" \
    "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/task-start.sh\" --issue 17 --slug x --dry-run"
}

@test "pr-create.sh の実際の出力から、作った PR の URL を拾う（body の別の URL は拾わない）" {
  git add .claude/dev-workflow/config.json
  git commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  echo work >work.txt
  git add work.txt
  git commit -q -m "feat: work"
  printf '## 概要\n詳しくは https://github.com/me/demo/issues/99\n\n## 変更点\n- work.txt\n\n## 確認方法\n- 見た\n' >"$TMP/body.md"
  run_script pr-create.sh --issue 17 --body-file "$TMP/body.md"
  assert_success
  out="$(json_of "$output")"
  # 出力の形が変わって、PR の URL を読めなくなったら、ここで気づく
  assert_equal "$(jq -r .pr.url <<<"$out")" "https://github.com/me/demo/pull/42"
  run_hook "bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/pr-create.sh\" --issue 17 --body-file b.md" "$out"
  [ "$status" -eq 0 ]
  [[ "$(jq -r .systemMessage <<<"$output")" == *"PR: https://github.com/me/demo/pull/42"* ]]
  [[ "$output" != *"issues/99"* ]]
}

@test "引用符の中の --dry-run には反応せず、リンクを出す" {
  shows "git commit -m \"--dry-run を説明する\"" "Issue #17: https://github.com/me/demo/issues/17"
  shows "git commit -m 'document --dry-run'" "Issue #17: https://github.com/me/demo/issues/17"
}

@test "1つのコマンドで同じブランチに何度も commit・push しても、Issue と PR は1回だけ調べる" {
  shows "git commit -m x && git push && git commit -m y && git push" "Issue #17: https://github.com/me/demo/issues/17" "PR を作る:"
  assert_equal "$(called issue-view)" 1
  assert_equal "$(called pr-list)" 1
}

@test "長いコマンドでも速く終わる" {
  local msg words TIMEFORMAT='%U %S' c cpu
  msg="$(head -c 50000 /dev/zero | tr '\0' a | fold -w 76)"
  words="$(printf 'w%d ' $(seq 1 10000))"
  # guard-git.bats の同じテストと同じく、bats の並列の実行に左右されないよう、CPU 時間（子プロセスを含む）で測る
  : >"$TMP/cpu"
  SECONDS=0
  for c in "git commit -m \"$msg\"" "echo $words; git commit -m x" \
    "$(printf 'git commit -F - <<EOF\n%s\nEOF' "$msg")"; do
    { time run_hook "$c"; } 2>>"$TMP/cpu"
    [ "$status" -eq 0 ] || fail "止めてしまった（$status）: ${c:0:80}"
    [[ "$(jq -r .systemMessage <<<"$output")" == *"Issue #17: https://github.com/me/demo/issues/17"* ]] || fail "Issue が無い: ${c:0:80}"
  done
  cpu="$(awk '{ t += $1 + $2 } END { printf "%.1f", t }' "$TMP/cpu")"
  awk -v t="$cpu" 'BEGIN { exit !(t < 10) }' || fail "CPU 時間で ${cpu} 秒かかった"
  [ "$SECONDS" -lt 120 ] || fail "壁時計で ${SECONDS} 秒かかった"
}

@test "同じリンクも、連続で毎回出す" {
  shows "git commit -m x" "Issue #17: https://github.com/me/demo/issues/17"
  shows "git commit -m x" "Issue #17: https://github.com/me/demo/issues/17"
  shows "git commit -m y" "Issue #17: https://github.com/me/demo/issues/17"
}

@test "git のオプションを飛ばして、サブコマンドで判定する" {
  shows "git -C . push" "PR を作る:"
  shows "git -c user.name=x commit -m x" "Issue #17: https://github.com/me/demo/issues/17"
  shows "git --no-pager -C . commit -m x" "Issue #17: https://github.com/me/demo/issues/17"
  shows "git add a && git commit -m x" "Issue #17: https://github.com/me/demo/issues/17"
}

@test "push・commit ではないサブコマンドでは、push・commit の語があっても出さない" {
  silent "git stash push -m x" "git stash commit" "git log --grep commit" "git log --grep=push" "git-lfs push origin" \
    "git config alias.push x" "echo digit push"
}

@test "push と、ブランチを作るコマンドを続けても、PR・CI は今のブランチ、Issue は両方のものを出す" {
  fake_issue 23 '["feat"]'
  echo '[{"url": "https://github.com/me/demo/pull/42", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  shows "git push && git switch -c feat/23-x" \
    "Issue #17: https://github.com/me/demo/issues/17" \
    "Issue #23: https://github.com/me/demo/issues/23" \
    "PR: https://github.com/me/demo/pull/42"
  assert_equal "$(args pr-list 1)" "--head feat/17-demo --state open --json url,isCrossRepository -q map(select(.isCrossRepository | not)) | .[0].url // empty"
}

@test "関係のないコマンドでは何も出さない" {
  silent "ls -la" "echo hello" "" "git status" "git log --oneline" "git diff" "git switch main" "git checkout main" \
    "git branch" "git branch -d x" "gh pr view 1" "gh issue list" "bash tests.sh"
}

@test "Issue の番号が分からないブランチ（main など）では、ブランチから導くリンクを出さない" {
  git switch -q main
  silent "git push" "git commit -m x" "git switch -c y"
  git switch -q -c scratch
  silent "git push" "git commit -m x"
  [ "$(called pr-list)" -eq 0 ]
}

@test "gh が失敗しても止めず、失敗した分のリンクだけを出さない" {
  # PR の一覧を取れないときは、PR が無いのか分からないので、PR・CI のリンクは出さず、Issue のリンクだけを出す
  FAKE_FAIL=pr-list run_hook "git push"
  [ "$status" -eq 0 ]
  assert_equal "$(jq -r .systemMessage <<<"$output")" "$(printf '関連するリンク:\n- Issue #17: https://github.com/me/demo/issues/17')"
  # Issue を取れないときは、Issue のリンクだけを出さない
  echo '[{"url": "https://github.com/me/demo/pull/42", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  FAKE_FAIL=issue-view run_hook "git push"
  [ "$status" -eq 0 ]
  assert_equal "$(jq -r .systemMessage <<<"$output")" "$(printf '関連するリンク:\n- PR: https://github.com/me/demo/pull/42\n- CI: https://github.com/me/demo/pull/42/checks')"
  # Issue も PR も取れなければ、リンクは1つも無い
  echo 'exit 1' >"$TMP/bin/gh"
  silent "git push" "git commit -m x"
}

@test "gh が無くても、何も出さずに通す" {
  rm "$TMP/bin/gh"
  PATH="/usr/bin:/bin" silent "git push" "git commit -m x"
}

@test "解析できない入力でも、止めずに通す" {
  run "${TEST_BASH:-bash}" "$HOOKS/pr-link.sh" <<<"これは JSON ではありません"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "${TEST_BASH:-bash}" "$HOOKS/pr-link.sh" <<<'{"tool_input": {"command": "git push"}, "cwd": "/no/such/dir"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tool_response が文字列でも出力から拾える" {
  jq -n --arg d "$PWD" '{tool_input: {command: "gh pr create"}, tool_response: "https://github.com/me/demo/pull/42", cwd: $d}' >"$TMP/input.json"
  run "${TEST_BASH:-bash}" "$HOOKS/pr-link.sh" <"$TMP/input.json"
  [ "$status" -eq 0 ]
  [[ "$(jq -r .systemMessage <<<"$output")" == *"PR: https://github.com/me/demo/pull/42"* ]]
}

@test "導入していないリポジトリでは、何も出さない" {
  rm .claude/dev-workflow/config.json
  silent "git push" "git commit -m x" "git switch -c feat/23-x"
  [ "$(called issue-view)" -eq 0 ]
  # 作った PR・Issue も出さない
  run_hook "gh issue create --title x" "https://github.com/me/demo/issues/50"
  assert_success
  assert_output ""
}

@test "git -C で指したリポジトリのブランチの Issue・PR・CI を出す" {
  make_wt
  shows_wt "git -C ../wt push"
  [[ "$output" == *"PR を作る: https://github.com/me/demo/pull/new/feat/23-x"* ]]
  assert_equal "$(args pr-list 1)" "--head feat/23-x --state open --json url,isCrossRepository -q map(select(.isCrossRepository | not)) | .[0].url // empty"
  shows_wt "git -C $TMP/wt commit -m x"
}

@test "cd で移った先のブランチの Issue を出す（cwd は、コマンドを実行した後のディレクトリ）" {
  make_wt
  # 外側の cd で移ると、Claude Code は cwd を移った先に引き継ぐので、cwd は既に移った先にある。相対パスの cd はたどり直さない
  shows_wt "cd ../wt && git push" "$TMP/wt"
  shows_wt "cd ../wt; git commit -m x" "$TMP/wt"
  # 絶対パスへの cd は、cwd に関係なく移った先で判断する（プロジェクトの外へ移ると、Claude Code が cwd を戻すため）
  shows_wt "cd $TMP/wt && git push"
  # $HOME・~ も展開する。絶対パスへ移った後の相対パスの cd はたどる
  HOME="$REPO" shows_wt "cd \$HOME/../wt && cd . && git push"
  HOME="$TMP/wt" shows_wt "cd ~ && cd ../wt && git push"
  # ( ) の中の cd は外に効かないので、cwd は移る前のまま。移った先をたどる
  shows_wt "(cd ../wt && git push)"
  # ( ) を出た後は、移る前のディレクトリに戻る
  echo '[{"url": "https://github.com/me/demo/pull/42", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  : >"$CALLS"
  run_hook "(cd ../wt && git commit -m x) && git push"
  [ "$status" -eq 0 ]
  [[ "$(jq -r .systemMessage <<<"$output")" == *"Issue #23: https://github.com/me/demo/issues/23"* ]]
  [[ "$(jq -r .systemMessage <<<"$output")" == *"Issue #17: https://github.com/me/demo/issues/17"* ]]
  assert_equal "$(args pr-list 1)" "--head feat/17-demo --state open --json url,isCrossRepository -q map(select(.isCrossRepository | not)) | .[0].url // empty"
}

@test "引用符やヒアドキュメントの中の git には反応しない" {
  silent "echo \"git push\"" "echo 'git commit -m x'" "cat <<'EOF'
git push
EOF"
  shows "git commit -m \"git push の説明\"" "Issue #17: https://github.com/me/demo/issues/17"
  [ "$(called pr-list)" -eq 0 ]
}

@test "導入していないリポジトリへ移った git の操作では、何も出さない" {
  fake_issue 23 '["feat"]'
  git init -q -b feat/23-x "$TMP/other"
  silent "git -C ../other commit -m x" "(cd ../other && git push)"
  [ "$(called issue-view)" -eq 0 ]
}

@test "--git-dir・GIT_DIR で指したリポジトリは、guard-git.sh と同じ求め方で、そのリポジトリのブランチと設定で判断する" {
  fake_issue 23 '["feat"]'
  git init -q -b feat/23-x "$TMP/other"
  git -C "$TMP/other" commit -q --allow-empty -m init
  # 導入していないリポジトリを指したときは、今のディレクトリ（導入済み）の設定で判断しない
  silent "GIT_DIR=$TMP/other/.git git push" "git --git-dir=$TMP/other/.git commit -m x" "git --git-dir $TMP/other/.git push"
  [ "$(called issue-view)" -eq 0 ]
  mark_set_up "$TMP/other"
  shows_wt "GIT_DIR=$TMP/other/.git git push"
  assert_equal "$(args pr-list 1)" "--head feat/23-x --state open --json url,isCrossRepository -q map(select(.isCrossRepository | not)) | .[0].url // empty"
}

@test "外側の相対パスへの cd で、cwd がプロジェクトのルートなら、外へ出て戻されたのかもしれないので何も出さない" {
  make_wt
  # cwd（REPO）がプロジェクトのルート：cd ../wt がプロジェクトの外なら、Claude Code が cwd を REPO に戻している
  CLAUDE_PROJECT_DIR="$REPO" silent "cd ../wt && git push" "cd ../wt; git commit -m x"
  [ "$(called issue-view)" -eq 0 ]
  # 絶対パスへの cd と、( ) の中の cd は、プロジェクトのルートでもたどる
  CLAUDE_PROJECT_DIR="$REPO" shows_wt "cd $TMP/wt && git push"
  CLAUDE_PROJECT_DIR="$REPO" shows_wt "(cd ../wt && git push)"
  # cwd がプロジェクトのルートでなければ、cwd は移った先
  CLAUDE_PROJECT_DIR="$REPO" shows_wt "cd ../wt && git push" "$TMP/wt"
}

@test "外側の popd の後は、移った先が分からないので何も出さない（( ) の中の pushd はたどる）" {
  make_wt
  silent "pushd $TMP/wt && popd && git push" "pushd $TMP/wt; popd; git commit -m x" "popd; git push"
  [ "$(called issue-view)" -eq 0 ]
  shows_wt "(pushd ../wt && git push)"
}

@test "短いオプションをまとめた git push -nu も dry-run とみなし、何も出さない" {
  silent "git push -nu origin feat/17-demo" "git push -vn" "git push --porcelain -n"
  shows "git push -u origin feat/17-demo" "PR を作る:"
  shows "git push -o n origin feat/17-demo" "PR を作る:"
  # -- の後ろと、値を取るオプションの値は、オプションとみなさない（guard-git.sh と同じ gc_push_args で読む）
  shows "git push origin -- -n" "PR を作る:"
  shows "git push --push-option -n origin feat/17-demo" "PR を作る:"
  shows "git push -o -n origin feat/17-demo" "PR を作る:"
}

@test "同じリポジトリの別のワークツリーにまたがっても、同じ Issue は1回だけ調べる" {
  make_wt
  shows "git worktree add -b feat/23-x ../wt && git -C ../wt push -u origin feat/23-x" "Issue #23: https://github.com/me/demo/issues/23"
  assert_equal "$(called issue-view)" 1
}

@test "cwd が導入していない場所でも、git -C で導入したリポジトリを指せば、そのリンクを出す（作った PR・Issue は出さない）" {
  git init -q -b main "$TMP/other"
  mkdir "$TMP/plain"
  local d
  for d in "$TMP/other" "$TMP/plain"; do
    run_hook "git -C $REPO commit -m x" "" "$d"
    [[ "$(jq -r .systemMessage <<<"$output")" == *"Issue #17: https://github.com/me/demo/issues/17"* ]] || fail "Issue が無い: $d / $output"
    run_hook "git -C $REPO push" "" "$d"
    [[ "$(jq -r .systemMessage <<<"$output")" == *"PR を作る: https://github.com/me/demo/pull/new/feat/17-demo"* ]] || fail "PR を作る URL が無い: $d / $output"
    # gh issue create は cwd で判断するので、cwd が導入していなければ出さない
    run_hook "gh issue create --title x" "https://github.com/me/demo/issues/50" "$d"
    assert_success
    assert_output ""
  done
}

@test "移った先が分からない（-C の先が無い・リポジトリでない、cd - の後）ときは、cwd のリンクを出さず、gh も呼ばない" {
  silent "git -C $TMP/no-such push" "git -C $TMP commit -m x" "cd - && git push" "cd $TMP/no-such; git commit -m x"
  [ "$(called pr-list)" -eq 0 ]
  [ "$(called issue-view)" -eq 0 ]
}

@test "ブランチを複数作るときは、作るブランチごとに Issue を出し、今のブランチの Issue を先に並べる" {
  fake_issue 23 '["feat"]'
  fake_issue 24 '["feat"]'
  shows "git switch -c feat/23-x && git branch feat/24-y" "Issue #23: https://github.com/me/demo/issues/23" "Issue #24: https://github.com/me/demo/issues/24"
  [[ "$output" != *"issues/17"* ]]
  run_hook "git branch feat/23-x && git commit -m x && git commit -m y"
  assert_success
  assert_equal "$(jq -r .systemMessage <<<"$output")" "$(printf '関連するリンク:\n- Issue #17: https://github.com/me/demo/issues/17\n- Issue #23: https://github.com/me/demo/issues/23')"
}

@test "task-start.sh と、同じ Issue のブランチへの commit を続けても、Issue は1回だけ調べる" {
  run_hook "git commit -m x && bash \"\${CLAUDE_PLUGIN_ROOT}/scripts/task-start.sh\" --issue 17 --slug x" '{"issue": 17, "branch": "feat/17-demo"}'
  assert_success
  assert_equal "$(jq -r .systemMessage <<<"$output")" "$(printf '関連するリンク:\n- Issue #17: https://github.com/me/demo/issues/17')"
  assert_equal "$(called issue-view)" 1
}
