#!/usr/bin/env bats
# --issue には、12 でも #12 でも Issue の番号を渡せる（スキルの引数をそのまま渡しても動くように）

load test_helper
load fake_gh

@test "branch-name.sh は --issue '#17' を 17 と同じに扱う" {
  setup_fake_gh
  run_script branch-name.sh --issue 17 --slug "Add Login Page"
  assert_success
  expected="$output"
  run_script branch-name.sh --issue '#17' --slug "Add Login Page"
  assert_success
  assert_equal "$output" "$expected"
}

@test "--issue '#17' を番号として受け取る（数字以外のエラーにならない）" {
  setup_fake_gh
  for args in \
    "task-start.sh --slug x" \
    "status-set.sh --to start" \
    "issue-cancel.sh --reason x" \
    "pr-create.sh --body-file /nonexistent"; do
    # shellcheck disable=SC2086 # 単語に分けて渡すのが目的
    run_script ${args%% *} --issue '#17' ${args#* }
    refute_output --partial "数字を指定してください"
  done
}

@test "review-perspectives.sh は --issue '#17' を番号として受け取る" {
  setup_fake_gh
  run_script review-perspectives.sh --base HEAD --target HEAD --issue '#17'
  refute_output --partial "Issue の番号にしてください"
}

@test "Issue の番号でない値は、これまでどおりエラーになる" {
  setup_fake_gh
  run_script branch-name.sh --issue '#abc' --slug x
  assert_failure 64
  assert_output --partial "--issue には数字を指定してください"
  run_script branch-name.sh --issue '##17' --slug x
  assert_failure 64
}
