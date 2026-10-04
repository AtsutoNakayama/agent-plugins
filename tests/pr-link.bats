#!/usr/bin/env bats
# git の操作のあとに、関連する PR・Issue・CI のリンクを出すフック（hooks/pr-link.sh）。

load test_helper
load fake_gh

HOOKS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/hooks"

setup() {
  # test_helper の setup を呼んでから、作業用のブランチ（Issue 17）に移る
  TMP="$(cd "$(mktemp -d)" && pwd -P)"
  REPO="$TMP/repo"
  export WORKFLOW_USER_DIR="$TMP/user"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  mkdir -p "$REPO/.claude/dev-workflow" "$WORKFLOW_USER_DIR"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  cd "$REPO" || return 1
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

@test "作るブランチの名前に Issue の番号が無い、または名前を拾えないときは、今のブランチの Issue を出さない" {
  # guard-git.sh が警告する書き方でも、拾えなければ何も出さない（間違った Issue を出さないため）
  silent "git branch scratch" "git switch -c scratch" "git switch -cfeat/23-x" "git branch --set-upstream-to origin/main feat/23-x"
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
    '{"url": "https://github.com/me/demo/pull/42", "body": "Closes https://github.com/me/demo/issues/99 と https://github.com/me/demo/pull/7"}'
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

@test "gh が失敗しても、何も出さずに通す" {
  local op
  for op in issue-view pr-list; do
    FAKE_FAIL=$op run_hook "git push"
    [ "$status" -eq 0 ] || fail "止めてしまった: $op"
    [[ "$output" != *"{"*"pull/42"* ]]
  done
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
