#!/usr/bin/env bats
# main を守るフック（hooks/guard-git.sh）。

load test_helper

HOOKS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/hooks"

# フックの入力（JSON）を作って渡す。cwd は既定で今のディレクトリ
# 使い方: run_hook <コマンド> [cwd]
run_hook() {
  jq -n --arg c "$1" --arg d "${2:-$PWD}" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $d}' \
    >"$TMP/input.json"
  run "${TEST_BASH:-bash}" "$HOOKS/guard-git.sh" <"$TMP/input.json"
}

# 通すコマンド
allowed() {
  local c
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 0 ] || fail "止めてしまった（$status）: $c / $output"
  done
}

# 止めるコマンド。使い方: denied <理由の一部> <コマンド>...
denied() {
  local msg="$1" c
  shift
  for c in "$@"; do
    run_hook "$c"
    [ "$status" -eq 2 ] || fail "止めなかった（$status）: $c"
    assert_output --partial "$msg"
  done
}

@test "hooks.json は Bash の前にフックを呼び、呼ぶスクリプトがある" {
  jq -e '.hooks.PreToolUse[0].matcher == "Bash"' "$HOOKS/hooks.json"
  run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS/hooks.json"
  # ${CLAUDE_PLUGIN_ROOT} は Claude Code が置き換える文字なので、そのまま比べる
  # shellcheck disable=SC2016
  assert_output 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/guard-git.sh"'
  [ -f "$HOOKS/guard-git.sh" ]
}

@test "git を使わないコマンドは通す" {
  allowed "ls -la" "echo hello" ""
}

@test "main の上での commit を止める" {
  denied "main の上ではコミットしません" \
    "git commit -m x" \
    "git add a && git commit -m x" \
    "FOO=1 git commit --amend" \
    "git -c user.name=t commit -m x" \
    "git commit -m x 2>&1 | tail -1"
}

@test "作業用のブランチの上の commit は通す" {
  git checkout -q -b feat/21-x
  allowed "git commit -m x" "git commit -m 'fix: main'"
}

@test "main の上でも commit 以外の git の操作は通す" {
  allowed "git status" "git log --oneline -3" "git pull --ff-only" "git fetch origin" "git switch -c feat/21-x"
}

@test "cd や -C で移った先のブランチで判断する" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  allowed "cd $TMP/wt && git commit -m x" "git -C $TMP/wt commit -m x" "cd ../repo/../../${TMP##*/}/wt; git push"
  cd "$TMP/wt"
  denied "main の上ではコミットしません" "cd $REPO && git commit -m x" "git -C $REPO commit -m x" "git -C ../repo commit -m x"
}

@test "base_branch の設定に従う" {
  echo '{"base_branch": "develop"}' >.claude/workflow.json
  allowed "git commit -m x" "git push origin HEAD:main"
  git checkout -q -b develop
  denied "develop の上ではコミットしません" "git commit -m x"
  denied "develop へは push しません" "git push"
}

@test "main への push を止める" {
  denied "main へは push しません" \
    "git push" \
    "git push origin" \
    "git push -u origin HEAD" \
    "git push origin main" \
    "git push origin feat/21-x:main" \
    "git push origin HEAD:refs/heads/main" \
    "git push origin --delete main"
  git checkout -q -b feat/21-x
  denied "main へは push しません" "git push origin main" "git push origin HEAD:main" "git push origin -- main"
}

@test "作業用のブランチの push は通す" {
  git checkout -q -b feat/21-x
  allowed "git push" "git push -u origin HEAD" "git push origin feat/21-x" "git push -o ci.skip origin feat/21-x" \
    "git push --force-with-lease" "git push --force-with-lease=feat/21-x origin HEAD" "git push --force-if-includes --force-with-lease"
}

@test "main の上でも、別のブランチを明示した push は通す" {
  allowed "git push origin feat/21-x" "git push origin --delete feat/21-x"
}

@test "強制 push を止める（--force-with-lease は通す）" {
  git checkout -q -b feat/21-x
  denied "強制 push" \
    "git push --force" \
    "git push -f" \
    "git push -uf origin HEAD" \
    "git push origin +feat/21-x" \
    "git push origin +HEAD:feat/21-x" \
    "git push --force-with-lease --force" \
    "git push --mirror"
}

@test "引用符・ヒアドキュメント・コメントの中の文字は、コマンドとみなさない" {
  git checkout -q -b feat/21-x
  allowed \
    "echo 'git push --force'" \
    "echo \"a; git push -f\"" \
    "git commit -m 'docs: git push -f を止める'" \
    "ls # git push -f" \
    "$(printf 'git commit -F - <<EOF\nfix: x\ngit push --force\nEOF\ngit push')" \
    "$(printf "git commit -m \"\$(cat <<'EOF'\nfix: don't (git push -f)\nEOF\n)\" && git push -u origin HEAD")"
}

@test "if・for・{ }・! の中のコマンドも調べる" {
  denied "強制 push" "if true; then git push --force; fi" "{ git push --force; }" "! git push -f" \
    "while false; do :; done && until true; do git push -f; done"
  denied "main の上ではコミットしません" "for b in a; do git commit -m x; done" "if false; then :; else git commit -m x; fi"
}

@test "( ) の中の cd は、括弧の外に効かない" {
  git worktree add -q -b feat/21-x "$TMP/wt"
  denied "main の上ではコミットしません" "(cd $TMP/wt && git status); git commit -m x" "(cd $TMP/wt) && git commit -m x"
  allowed "(cd $TMP/wt && git commit -m x)" "cd $TMP/wt && (git status) && git commit -m x"
}

@test "算術式の << はヒアドキュメントとみなさない" {
  git checkout -q -b feat/21-x
  # $((...)) はフックに渡す文字として書く
  # shellcheck disable=SC2016
  denied "強制 push" "$(printf 'x=$((1<<2))\ngit push --force')" "$(printf '(( x = 1 << 2 ))\ngit push --force')"
}

@test "長いコマンドでも速く終わる" {
  git checkout -q -b feat/21-x
  msg="$(head -c 50000 /dev/zero | tr '\0' a | fold -w 76)"
  words="$(printf 'w%d ' $(seq 1 10000))"
  SECONDS=0
  denied "強制 push" "git commit -m \"$msg\"; git push -f" "echo $words; git push -f" \
    "$(printf 'git commit -F - <<EOF\n%s\nEOF\ngit push -f' "$msg")"
  [ "$SECONDS" -lt 10 ] || fail "${SECONDS} 秒かかった"
}

@test "ヒアドキュメントの後ろのコマンドは調べる" {
  git checkout -q -b feat/21-x
  denied "強制 push" "$(printf 'git commit -F - <<EOF\nfix: x\nEOF\ngit push -f')"
}

@test "リポジトリの外や、行き先の分からない cd の後は、ブランチでは止めない" {
  allowed "cd $TMP && git commit -m x" "cd \$SOMEWHERE && git commit -m x"
}
