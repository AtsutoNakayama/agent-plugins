#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

@test "役割 start は設定の列（In Progress）に移す" {
  setup_fake_gh
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(args SetField | jq -c '[.i, .f, .v]')" '["IT1","F1",{"singleSelectOptionId":"O2"}]'
  assert_equal "$(jq -c '[.from, .to, .changed]' <<<"$output")" '["Todo","In Progress",true]'
}

@test "列名でも指定できる" {
  setup_fake_gh
  run_script status-set.sh --issue 17 --to Done
  assert_success
  assert_equal "$(args SetField | jq -r .v.singleSelectOptionId)" O3
}

@test "既にその列なら何もしない" {
  setup_fake_gh
  issue_item "In Progress"
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(called SetField)" 0
  assert_equal "$(jq -r .changed <<<"$output")" false
}

@test "Project に入っていなければ追加してから移す" {
  setup_fake_gh
  issue_item absent
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(args AddItem)" '{"p":"P4","c":"I17"}'
  assert_equal "$(args SetField | jq -r .i)" IT9
}

@test "役割の列が null（既定の pr_opened）なら何もしない" {
  setup_fake_gh
  run_script status-set.sh --issue 17 --to pr_opened
  assert_success
  assert_equal "$(jq -r .skipped <<<"$output")" true
  assert_equal "$(called ProjectFields)" 0
}

@test "無い列を指定したらエラーになる" {
  setup_fake_gh
  run_script status-set.sh --issue 17 --to Blocked
  assert_failure 2
  assert_output --partial "Status 列に「Blocked」がありません（Todo / In Progress / Done）"
}

@test "dry-run では変更せず、予定だけを出力する" {
  setup_fake_gh
  issue_item absent
  run_script status-set.sh --issue 17 --to start --dry-run
  assert_success
  assert_equal "$(called AddItem)" 0
  assert_equal "$(called SetField)" 0
  assert_equal "$(jq -c .actions <<<"$output")" '["Issue #17 を Project に追加する","Issue #17 を「（なし）」から「In Progress」に移す"]'
}

@test "project.number が未設定ならエラーになる" {
  setup_fake_gh
  echo '{}' >.claude/workflow.json
  run_script status-set.sh --issue 17 --to start
  assert_failure 2
  assert_output --partial "project.number が未設定です"
}
