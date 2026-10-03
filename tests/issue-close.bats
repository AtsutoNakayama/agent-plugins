#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

@test "理由をコメントして not planned で閉じる" {
  setup_fake_gh
  run_script issue-close.sh --issue 17 --reason "#20 で作業するため閉じます"
  assert_success
  assert_equal "$(grep '^close ' "$CALLS")" "close 17 --reason not planned"
  assert_equal "$(cat "$TMP/close-comment")" "#20 で作業するため閉じます"
  assert_equal "$(jq -c '[.issue, .title, .dry_run, .state_reason, .comment]' <<<"$output")" \
    '[17,"作業 17",false,"NOT_PLANNED","#20 で作業するため閉じます"]'
}

@test "複数行の理由もそのままコメントする" {
  setup_fake_gh
  run_script issue-close.sh --issue 17 --reason "$(printf '誤って起票しました。\n\n代わりに #20 で作業します。')"
  assert_success
  assert_equal "$(cat "$TMP/close-comment")" "$(printf '誤って起票しました。\n\n代わりに #20 で作業します。')"
}

@test "Project と Story Point には触れない" {
  setup_fake_gh
  run_script issue-close.sh --issue 17 --reason "やらないことにしました"
  assert_success
  # GraphQL（Project の操作）も issue edit（ラベルなどの変更）も呼ばない
  assert_equal "$(grep -vc '^close ' "$CALLS")" 0
}

@test "理由が無い・空白だけなら閉じずに止まる" {
  setup_fake_gh
  run_script issue-close.sh --issue 17
  assert_failure 64
  assert_output --partial "--reason に閉じる理由を書いてください"
  run_script issue-close.sh --issue 17 --reason ""
  assert_failure 64
  run_script issue-close.sh --issue 17 --reason "$(printf ' \n\t ')"
  assert_failure 64
  assert_output --partial "--reason に閉じる理由を書いてください"
  assert_equal "$(called close)" 0
}

@test "既に閉じている Issue では、コメントもせずに止まる" {
  setup_fake_gh
  fake_issue 17 '["feat"]' CLOSED
  run_script issue-close.sh --issue 17 --reason "やらないことにしました"
  assert_failure 2
  assert_output --partial "Issue #17 は既に閉じています"
  assert_equal "$(called close)" 0
}

@test "無い Issue ならエラーになる" {
  setup_fake_gh
  run_script issue-close.sh --issue 99 --reason "やらないことにしました"
  assert_failure
  assert_output --partial "Issue #99 を読めません"
  assert_equal "$(called close)" 0
}

@test "dry-run では閉じず、予定だけを出力する" {
  setup_fake_gh
  run_script issue-close.sh --issue 17 --reason "やらないことにしました" --dry-run
  assert_success
  assert_equal "$(called close)" 0
  assert_equal "$(jq -r .dry_run <<<"$output")" true
  assert_equal "$(jq -c .actions <<<"$output")" \
    '["Issue #17 に閉じる理由をコメントする","Issue #17 を not planned で閉じる（Project と Story Point はそのまま残す）"]'
}

@test "閉じるのに失敗したらエラーになる" {
  setup_fake_gh
  FAKE_FAIL=close run_script issue-close.sh --issue 17 --reason "やらないことにしました"
  assert_failure
  assert_output --partial "Issue #17 を閉じられませんでした"
}

@test "--issue が数字でなければエラーになる" {
  setup_fake_gh
  run_script issue-close.sh --issue abc --reason "やらないことにしました"
  assert_failure 64
  assert_output --partial "--issue には数字を指定してください: abc"
}
