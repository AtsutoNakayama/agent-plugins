#!/usr/bin/env bats
# eval の偽の gh（tests/eval/bin/gh・fake-gh.sh）のテスト

load test_helper

setup() {
  test_helper_setup
  FAKE_GH="$BATS_TEST_DIRNAME/eval/bin/gh"
  mkdir -p .fake-gh/res
  : >.fake-gh/routes
  : >.fake-gh/calls
}

# 表に応答を足す。使い方: route <パターン> <応答> [終了コード]
route() {
  local n
  n="$(($(wc -l <.fake-gh/routes) + 1))"
  printf '%s\n' "$2" >".fake-gh/res/${n}"
  printf '%s\t%s\t%s\n' "$1" "res/${n}" "${3:-0}" >>.fake-gh/routes
}

fake_gh() {
  run "${TEST_BASH:-bash}" "$FAKE_GH" "$@"
}

@test "表のパターンに合う呼び出しに応答を返し、引数を記録する" {
  route 'issue list*' '[{"number": 1}]'
  fake_gh issue list --state open --json number
  assert_success
  assert_output '[{"number": 1}]'
  assert_equal "$(cat .fake-gh/calls)" "issue list --state open --json number"
}

@test "合うパターンが複数あれば、上の行を使う" {
  route 'issue view 1 *' '{"number": 1}'
  route 'issue view *' '{"number": 0}'
  fake_gh issue view 1 --json number
  assert_success
  assert_output '{"number": 1}'
  fake_gh issue view 2 --json number
  assert_output '{"number": 0}'
}

@test "-q と --jq の式を応答に当てる" {
  route 'repo view*' '{"nameWithOwner": "me/demo"}'
  fake_gh repo view --json nameWithOwner -q .nameWithOwner
  assert_success
  assert_output "me/demo"
  fake_gh repo view --json nameWithOwner --jq .nameWithOwner
  assert_output "me/demo"
}

@test "終了コードが 0 でない応答は、標準エラーに出して、その終了コードで終わる" {
  route 'pr view*' 'no pull requests found' 1
  run "${TEST_BASH:-bash}" -c "\"$FAKE_GH\" pr view 2>/dev/null"
  assert_failure 1
  assert_output ""
  run "${TEST_BASH:-bash}" -c "\"$FAKE_GH\" pr view 2>&1 >/dev/null"
  assert_output "no pull requests found"
}

@test "gh api graphql は操作名で当て、操作名と変数を記録する" {
  route 'api graphql TodoItems' '{"data": {}}'
  run "${TEST_BASH:-bash}" -c "printf '%s' '{\"query\": \"query TodoItems(\$n: Int!) { x }\", \"variables\": {\"n\": 4}}' | \"$FAKE_GH\" api graphql --input -"
  assert_success
  assert_output '{"data": {}}'
  assert_equal "$(cat .fake-gh/calls)" 'api graphql TodoItems {"n":4}'
}

@test "合うパターンが無い呼び出しは、記録してから失敗する" {
  route 'issue list*' '[]'
  fake_gh pr create --title t
  assert_failure
  assert_output --partial "応答が用意されていない呼び出しです: gh pr create --title t"
  assert_equal "$(cat .fake-gh/calls)" "pr create --title t"
}

@test "下のディレクトリ（ワークツリーなど）から呼んでも、上の .fake-gh を使う" {
  route 'issue list*' '[]'
  mkdir -p .claude/worktrees/feat/1-x
  cd .claude/worktrees/feat/1-x
  fake_gh issue list
  assert_success
  assert_output '[]'
  assert_equal "$(cat "$REPO/.fake-gh/calls")" "issue list"
}

@test ".fake-gh/routes が見つからなければ失敗する" {
  rm -rf .fake-gh
  fake_gh issue list
  assert_failure
  assert_output --partial ".fake-gh/routes が見つかりません"
}
