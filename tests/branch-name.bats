#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

@test "type ラベルと短い説明からブランチ名を作る" {
  setup_fake_gh
  run_script branch-name.sh --issue 17 --slug "Add Login Page"
  assert_success
  assert_equal "$(jq -c . <<<"$output")" '{"branch":"feat/17-add-login-page","type":"feat","issue":17,"slug":"add-login-page"}'
}

@test "短い説明は英数字以外を - にまとめ、40 文字までにする" {
  setup_fake_gh
  run_script branch-name.sh --issue 17 --type fix --slug "  Fix: CI!! --- flaky テスト $(printf 'a%.0s' {1..50})"
  assert_success
  slug="$(jq -r .slug <<<"$output")"
  assert_regex "$slug" '^fix-ci-flaky-a+$'
  [ "${#slug}" -le 40 ]
}

@test "短い説明が作れない（日本語だけ・空）ときは issue-<番号> にする" {
  setup_fake_gh
  run_script branch-name.sh --issue 17 --slug "ログイン画面"
  assert_equal "$(jq -r .branch <<<"$output")" issue-17
  run_script branch-name.sh --issue 17
  assert_equal "$(jq -r .branch <<<"$output")" issue-17
}

@test "type 以外のラベルは無視する" {
  setup_fake_gh
  fake_issue 17 '["fix", "priority: high"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_equal "$(jq -r .branch <<<"$output")" fix/17-x
}

@test "設定の branch.pattern に従う" {
  setup_fake_gh
  echo '{"branch": {"pattern": "{issue}/{type}-{slug}"}}' >.claude/workflow.json
  run_script branch-name.sh --issue 17 --slug x
  assert_equal "$(jq -r .branch <<<"$output")" 17/feat-x
}

@test "type ラベルが無い、または複数あればエラーになる" {
  setup_fake_gh
  fake_issue 17 '["priority: high"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_failure 2
  assert_output --partial "Issue #17 に type ラベルがありません"
  fake_issue 17 '["feat", "fix"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_failure 2
  assert_output --partial "type ラベルが複数あります（feat, fix）"
}

@test "--type を指定すれば Issue を読まない" {
  setup_fake_gh
  run_script branch-name.sh --issue 99 --type docs --slug readme
  assert_success
  assert_equal "$(jq -r .branch <<<"$output")" docs/99-readme
}

@test "--check は規約に合えば valid: true で終了コード 0" {
  run_script branch-name.sh --check feat/17-add-login
  assert_success
  assert_equal "$(jq -c '[.valid, .reason]' <<<"$output")" '[true,null]'
}

@test "--check は規約に合わなければ理由を出して終了コード 1" {
  for name in Feat/17-x feat/ログイン feat//17 feat/17- -feat/17 feat/17-x.lock "feat/17 x"; do
    run_script branch-name.sh --check "$name"
    assert_failure 1
    assert_equal "$(jq -r .valid <<<"$output")" false
  done
}
