#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

@test "役割 start は設定の列（In Progress）に移す" {
  setup_fake_gh
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(args SetField | jq -c '[."project-id", .id, ."field-id", ."single-select-option-id"]')" '["P4","IT1","F1","O2"]'
  assert_equal "$(jq -c '[.from, .to, .changed]' <<<"$output")" '["Todo","In Progress",true]'
}

@test "列名でも指定できる" {
  setup_fake_gh
  run_script status-set.sh --issue 17 --to Done
  assert_success
  assert_equal "$(args SetField | jq -r '."single-select-option-id"')" O3
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
  assert_equal "$(args AddItem)" '{"_":["4"],"owner":"me","url":"https://github.com/me/demo/issues/17","format":"json"}'
  assert_equal "$(args SetField | jq -r .id)" IT9
}

@test "役割の列が null（既定の pr_opened）なら何もしない" {
  setup_fake_gh
  run_script status-set.sh --issue 17 --to pr_opened
  assert_success
  assert_equal "$(jq -r .skipped <<<"$output")" true
  assert_equal "$(called ProjectView)" 0
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
  echo '{}' >.claude/dev-workflow/config.json
  run_script status-set.sh --issue 17 --to start
  assert_failure 2
  assert_output --partial "project.number が未設定です"
}

@test "Project が無ければ（gh は Could not resolve のエラーを返す）、案内して止まる" {
  setup_fake_gh
  FAKE_FAIL=ProjectView FAKE_FAIL_MSG="GraphQL: Could not resolve to a ProjectV2 with the number 4. (user.projectV2)" \
    run_script status-set.sh --issue 17 --to start
  assert_failure 1
  assert_output --partial "Project が見つかりません: me/4"
}

@test "Project を読めない（スコープ不足など）ときは、GitHub の理由を伝える" {
  setup_fake_gh
  FAKE_FAIL=ProjectView FAKE_FAIL_MSG="your token has not been granted the required scopes" \
    run_script status-set.sh --issue 17 --to start
  assert_failure 1
  assert_output --partial "GitHub の API に失敗しました: your token has not been granted the required scopes"
}

@test "組織の Project は、REST の orgs の項目の一覧を読む" {
  setup_fake_gh
  echo '{"id": "P4", "number": 4, "url": "u", "owner": {"login": "me", "type": "Organization"}}' >"$FIX/ProjectView.json"
  run_script status-set.sh --issue 17 --to start
  assert_success
  assert_equal "$(args ProjectFields | jq -r .path)" "orgs/me/projectsV2/4/fields?per_page=100"
}

@test "Issue が無ければエラーになる" {
  setup_fake_gh
  FAKE_FAIL=IssueItem FAKE_FAIL_MSG="GraphQL: Could not resolve to an Issue with the number of 17. (repository.issue)" \
    run_script status-set.sh --issue 17 --to start
  assert_failure 2
  assert_output --partial "Issue #17 が me/demo にありません"
}

@test "--item-id を渡すと、項目と今の列を読まずに（GraphQL なしで）その項目を移す" {
  setup_fake_gh
  run_script status-set.sh --issue 17 --to todo --item-id IT5
  assert_success
  assert_equal "$(called IssueItem)" 0
  assert_equal "$(called AddItem)" 0
  assert_equal "$(args SetField | jq -c '[."project-id", .id, ."field-id", ."single-select-option-id"]')" '["P4","IT5","F1","O1"]'
  assert_equal "$(jq -c '[.item_id, .from, .to, .changed, .actions]' <<<"$output")" \
    '["IT5",null,"Todo",true,["Issue #17 を「Todo」に移す"]]'
}

@test "--item-id の値が無ければ使い方の誤りになる" {
  setup_fake_gh
  run_script status-set.sh --issue 17 --to todo --item-id
  assert_failure 64
  assert_output --partial "--item-id に値がありません"
}
