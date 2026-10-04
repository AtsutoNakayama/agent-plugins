#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031
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

# 12 と #12 で、終了コードも出力も同じになる（別の理由で失敗しても、同じ理由で失敗する）
same_as_plain() {
  local script="$1"
  shift
  run_script "$script" --issue 17 "$@"
  local status_plain="$status" output_plain="$output"
  run_script "$script" --issue '#17' "$@"
  assert_equal "$status" "$status_plain"
  assert_equal "$output" "$output_plain"
}

@test "--issue '#17' は 17 と同じ結果になる（番号以外の理由で失敗するものも、同じ理由で失敗する）" {
  setup_fake_gh
  same_as_plain task-start.sh --slug x
  same_as_plain status-set.sh --to start
  same_as_plain issue-cancel.sh --reason x
  same_as_plain pr-create.sh --body-file /nonexistent
  same_as_plain review-perspectives.sh --base HEAD --target HEAD
}

@test "--issue '#17' が、数字以外のエラーにならない" {
  setup_fake_gh
  for args in "task-start.sh --slug x" "status-set.sh --to start" "issue-cancel.sh --reason x" "pr-create.sh --body-file /nonexistent" "review-perspectives.sh --base HEAD --target HEAD"; do
    # shellcheck disable=SC2086 # 単語に分けて渡すのが目的
    run_script ${args%% *} --issue '#17' ${args#* }
    refute_output --partial "数字を指定してください"
    refute_output --partial "Issue の番号にしてください"
  done
}

@test "# だけの --issue は、番号がないものとして拒否する" {
  setup_fake_gh
  for args in "branch-name.sh --slug x" "task-start.sh --slug x" "status-set.sh --to start" "issue-cancel.sh --reason x" "pr-create.sh --body-file /nonexistent"; do
    # shellcheck disable=SC2086 # 単語に分けて渡すのが目的
    run_script ${args%% *} --issue '#' ${args#* }
    assert_failure 64
    assert_output --partial "--issue には数字を指定してください: #"
  done
  run_script review-perspectives.sh --base HEAD --target HEAD --issue '#'
  assert_failure 64
  assert_output --partial "Issue の番号にしてください: #"
}

@test "issue-cancel.sh の --duplicate-of も、# だけや ## で始まる値は拒否し、#5 は 5 と同じに扱う" {
  setup_fake_gh
  run_script issue-cancel.sh --issue 17 --reason x --duplicate-of '##5'
  assert_failure 64
  assert_output --partial "--duplicate-of には数字を指定してください"
  run_script issue-cancel.sh --issue 17 --reason x --duplicate-of '#'
  assert_failure 64
  same_as_plain issue-cancel.sh --reason x --duplicate-of 5
}

@test "Issue の番号でない値は、これまでどおりエラーになる" {
  setup_fake_gh
  run_script branch-name.sh --issue '#abc' --slug x
  assert_failure 64
  assert_output --partial "--issue には数字を指定してください"
  run_script branch-name.sh --issue '##17' --slug x
  assert_failure 64
}
