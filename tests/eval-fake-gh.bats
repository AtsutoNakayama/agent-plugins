#!/usr/bin/env bats
# eval の偽の gh（tests/eval/bin/gh・fake-gh.sh）のテスト

load test_helper

# 表は、ケースの準備と同じ処理（scaffold.bash の fake_gh_init・fake_gh）で作る
load ../plugins/dev-workflow/evals/lib/scaffold

setup() {
  test_helper_setup
  FAKE_GH="$BATS_TEST_DIRNAME/eval/bin/gh"
  fake_gh_init
}

run_fake_gh() {
  run "${TEST_BASH:-bash}" "$FAKE_GH" "$@"
}

@test "表のパターンに合う呼び出しに応答を返し、引数を記録する" {
  fake_gh 'issue list*' '[{"number": 1}]'
  run_fake_gh issue list --state open --json number
  assert_success
  assert_output '[{"number": 1}]'
  assert_equal "$(cat .fake-gh/calls)" "issue list --state open --json number"
}

@test "合うパターンが複数あれば、上の行を使う" {
  fake_gh 'issue view 1 *' '{"number": 1}'
  fake_gh 'issue view *' '{"number": 0}'
  run_fake_gh issue view 1 --json number
  assert_success
  assert_output '{"number": 1}'
  run_fake_gh issue view 2 --json number
  assert_output '{"number": 0}'
}

@test "-q と --jq の式を応答に当てる" {
  fake_gh 'repo view*' '{"nameWithOwner": "me/demo"}'
  run_fake_gh repo view --json nameWithOwner -q .nameWithOwner
  assert_success
  assert_output "me/demo"
  run_fake_gh repo view --json nameWithOwner --jq .nameWithOwner
  assert_output "me/demo"
}

@test "終了コードが 0 でない応答は、標準エラーに出して、その終了コードで終わる" {
  fake_gh 'pr view*' 'no pull requests found' 1
  run "${TEST_BASH:-bash}" -c "\"$FAKE_GH\" pr view 2>/dev/null"
  assert_failure 1
  assert_output ""
  run "${TEST_BASH:-bash}" -c "\"$FAKE_GH\" pr view 2>&1 >/dev/null"
  assert_output "no pull requests found"
}

@test "gh api graphql は操作名で当て、操作名と変数を記録する" {
  fake_gh 'api graphql TodoItems' '{"data": {}}'
  run "${TEST_BASH:-bash}" -c "printf '%s' '{\"query\": \"query TodoItems(\$n: Int!) { x }\", \"variables\": {\"n\": 4}}' | \"$FAKE_GH\" api graphql --input -"
  assert_success
  assert_output '{"data": {}}'
  assert_equal "$(cat .fake-gh/calls)" 'api graphql TodoItems {"n":4}'
}

@test "合うパターンが無い呼び出しは、記録してから失敗する" {
  fake_gh 'issue list*' '[]'
  run_fake_gh pr create --title t
  assert_failure
  assert_output --partial "応答が用意されていない呼び出しです: gh pr create --title t"
  assert_equal "$(cat .fake-gh/calls)" "pr create --title t"
}

@test "下のディレクトリ（ワークツリーなど）から呼んでも、上の .fake-gh を使う" {
  fake_gh 'issue list*' '[]'
  mkdir -p .claude/worktrees/feat/1-x
  cd .claude/worktrees/feat/1-x
  run_fake_gh issue list
  assert_success
  assert_output '[]'
  assert_equal "$(cat "$REPO/.fake-gh/calls")" "issue list"
}

@test ".fake-gh/routes が見つからなければ失敗する" {
  rm -rf .fake-gh
  run_fake_gh issue list
  assert_failure
  assert_output --partial ".fake-gh/routes が見つかりません"
}

@test "読むだけの呼び出しは .fake-gh/writes に記録しない" {
  fake_gh '*' '{}'
  run_fake_gh repo view --json nameWithOwner
  run_fake_gh issue view 1 --json body
  run_fake_gh -R me/demo issue list --state open
  run_fake_gh pr list --head x
  run_fake_gh project item-list 4 --owner me
  run_fake_gh api user
  run_fake_gh api --paginate "repos/me/demo/issues/1/dependencies/blocked_by?per_page=100"
  run_fake_gh api -X GET repos/me/demo/issues/1
  run_fake_gh search issues login
  run_fake_gh auth status
  run_fake_gh --version
  assert_equal "$(cat .fake-gh/writes)" ""
  assert_equal "$(wc -l <.fake-gh/calls | tr -d ' ')" 11
}

@test "書き込む呼び出しは .fake-gh/writes に記録する（REST・サブコマンド・-R の後）" {
  fake_gh '*' '{}'
  run_fake_gh api -X POST repos/me/demo/issues --input -
  run_fake_gh api --method=patch repos/me/demo/labels/x
  run_fake_gh api -XDELETE repos/me/demo/git/refs/heads/x
  run_fake_gh api repos/me/demo/issues/1/comments -f body=x
  run_fake_gh issue create --title t
  run_fake_gh -R me/demo issue close 1
  run_fake_gh --repo me/demo pr merge 2
  run_fake_gh pr close 2
  run_fake_gh project item-edit --id x
  run_fake_gh label create x
  assert_equal "$(wc -l <.fake-gh/writes | tr -d ' ')" 10
  assert_equal "$(head -n 1 .fake-gh/writes)" "api -X POST repos/me/demo/issues --input -"
}

@test "gh api graphql は、mutation なら書き込み、query なら読むだけとして記録する" {
  fake_gh 'api graphql *' '{"data": {}}'
  run "${TEST_BASH:-bash}" -c "printf '%s' '{\"query\": \"query TodoItems { x }\"}' | \"$FAKE_GH\" api graphql --input -"
  assert_success
  assert_equal "$(cat .fake-gh/writes)" ""
  run "${TEST_BASH:-bash}" -c "printf '%s' '{\"query\": \"mutation SetField { x }\"}' | \"$FAKE_GH\" api graphql --input -"
  assert_success
  run_fake_gh api graphql -f 'query=mutation AddItem { x }'
  assert_success
  assert_equal "$(cat .fake-gh/writes)" "$(printf '%s\n' 'api graphql SetField {}' 'api graphql AddItem {}')"
}
