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

@test "--slug が無い、または英数字が無い（日本語や記号だけ）ときはエラーになり、Issue を読まない" {
  setup_fake_gh
  run_script branch-name.sh --issue 99
  assert_failure 64
  assert_output --partial "--slug は必須です"
  run_script branch-name.sh --issue 99 --slug "ログイン画面"
  assert_failure 64
  assert_output --partial "短い説明に英数字がありません"
  run_script branch-name.sh --issue 99 --slug " - ! "
  assert_failure 64
  assert_output --partial "短い説明に英数字がありません"
}

@test "type 以外のラベルは無視する" {
  setup_fake_gh
  fake_issue 17 '["fix", "priority: high"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_equal "$(jq -r .branch <<<"$output")" fix/17-x
}

@test "設定の branch.pattern に従う" {
  setup_fake_gh
  echo '{"branch": {"pattern": "{issue_number}/{type}-{slug}"}}' >.claude/dev-workflow/config.json
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

@test "--check は branch.pattern の形に合わなければ理由を出して終了コード 1" {
  for name in foo wip/17-x feat/x-y feat/17 feat/17-a--b feat/17-x/y; do
    run_script branch-name.sh --check "$name"
    assert_failure 1
    assert_equal "$(jq -r .reason <<<"$output")" "branch.pattern（{type}/{issue_number}-{slug}）の形になっていません"
  done
}

@test "--check は設定の branch.pattern と labels.types に従う" {
  echo '{"branch": {"pattern": "{type}-{issue_number}/{slug}"}, "labels": {"types": ["feat", "wip"]}}' >.claude/dev-workflow/config.json
  run_script branch-name.sh --check wip-17/add-login
  assert_success
  for name in feat/17-add-login fix-17/add-login wip-x/add-login; do
    run_script branch-name.sh --check "$name"
    assert_failure 1
  done
}

# --check の valid と、dw_parse_branch が取り出す「<type>|<番号>」が、同じ名前で一致することを確かめる
# 受け入れる名前は期待する「<type>|<番号>」を、拒否する名前は「|」を渡す
# 使い方: assert_check_matches_parse <ブランチ名> <期待する type|番号>
assert_check_matches_parse() {
  local config parsed valid=true
  [ "$2" = "|" ] && valid=false
  run_script branch-name.sh --check "$1"
  assert_equal "$(jq -r .valid <<<"$output")" "$valid"
  config="$("${TEST_BASH:-bash}" "$SCRIPTS/config.sh")"
  # shellcheck disable=SC2016 # $1〜$3 は bash -c の中で展開する
  parsed="$("${TEST_BASH:-bash}" -c '. "$1/common.sh"; dw_parse_branch "$2" "$3"' _ "$SCRIPTS/lib" "$config" "$1")"
  assert_equal "$parsed" "$2"
}

@test "--check と dw_parse_branch は、既定の branch.pattern で同じ名前を受け入れ・拒否する" {
  assert_check_matches_parse feat/17-add-login "feat|17"
  assert_check_matches_parse fix/3-a "fix|3"
  # 設定に無い type
  assert_check_matches_parse wip/17-add-login "|"
  # 番号が数字でない
  assert_check_matches_parse feat/x-add-login "|"
  # 末尾がハイフンの slug
  assert_check_matches_parse feat/17-add- "|"
  assert_check_matches_parse feat/17-add-login- "|"
}

@test "--check と dw_parse_branch は、独自の branch.pattern と labels.types でも同じ名前を受け入れ・拒否する" {
  echo '{"branch": {"pattern": "{type}-{issue_number}/{slug}"}, "labels": {"types": ["feat", "wip"]}}' >.claude/dev-workflow/config.json
  assert_check_matches_parse wip-17/add-login "wip|17"
  assert_check_matches_parse feat-3/a "feat|3"
  # 設定に無い type（既定の type でも、設定に無ければ拒否する）
  assert_check_matches_parse fix-17/add-login "|"
  # 番号が数字でない
  assert_check_matches_parse wip-x/add-login "|"
  # 末尾がハイフンの slug
  assert_check_matches_parse wip-17/add-login- "|"
  # 既定の pattern の形は拒否する
  assert_check_matches_parse feat/17-add-login "|"
}

@test "--check は設定を読めなければ終了コード 2" {
  echo '{' >.claude/dev-workflow/config.json
  run_script branch-name.sh --check feat/17-add-login
  assert_failure 2
}

@test "PR の番号は Issue として受け取らず、PR のラベルでブランチ名を作らない" {
  setup_fake_gh
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21, "labels": [{"name": "feat"}]}' >"$FIX/issue-21.json"
  run_script branch-name.sh --issue 21 --slug x
  assert_failure 2
  assert_output --partial "#21 は PR です。Issue の番号を指定してください"
}

@test "type ラベルは大文字と小文字を区別せずに照合し、設定の書き方の type にする（Fix と fix は1つと数える）" {
  setup_fake_gh
  fake_issue 17 '["Fix"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_success
  assert_equal "$(jq -r .branch <<<"$output")" fix/17-x
  fake_issue 17 '["fix", "FIX"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_success
  assert_equal "$(jq -r .type <<<"$output")" fix
}
