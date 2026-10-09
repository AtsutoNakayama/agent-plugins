#!/usr/bin/env bats

load test_helper

@test "プラグイン（plugins/dev-workflow/）の中に、特定のレビューの bot の名前（CodeRabbit）が無い" {
  cd "$BATS_TEST_DIRNAME/.."
  run grep -rniI coderabbit plugins/dev-workflow
  assert_failure
  assert_output ""
}
