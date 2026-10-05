#!/usr/bin/env bats
# スクリプトの共通処理（lib/common.sh）の関数を、直接呼んで確かめる。

load test_helper

# common.sh を読み込んで、関数を1つ呼ぶ。使い方: run_common <関数> [引数]...
run_common() {
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  run "${TEST_BASH:-bash}" -c '. "$1"; shift; "$@"' _ "$SCRIPTS/lib/common.sh" "$@"
}

@test "dw_remote_has_branch は、origin にあれば 0、無ければ 1 を返し、読めなければ止まる" {
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  run_common dw_remote_has_branch "$REPO" main
  assert_success
  run_common dw_remote_has_branch "$REPO" feat/17-x
  assert_failure 1
  assert_output ""
  git remote set-url origin "$TMP/no-such.git"
  run_common dw_remote_has_branch "$REPO" main
  assert_failure 1
  assert_output "error: origin のブランチを読めませんでした（通信や認証を確かめてください）"
}

@test "dw_issue_number は #・先頭の 0 をそろえ、# だけ・## で始まる値・数字でない値・0 を拒否する" {
  for v in 17 '#17' 017 '#0017'; do
    run_common dw_issue_number --issue "$v"
    assert_success
    assert_output 17
  done
  for v in '#' '##17' abc 0 000 ''; do
    run_common dw_issue_number --issue "$v"
    assert_failure 64
    assert_output "error: --issue には Issue の番号を指定してください: ${v}"
  done
  # 算術式にすると桁があふれる長さでも、文字列のまま 0 を外す
  run_common dw_issue_number --issue 00018446744073709551616
  assert_success
  assert_output 18446744073709551616
}

@test "dw_worktree_of は、ブランチを使っているワークツリーの場所を返す（無ければ空）" {
  git worktree add -q -b feat/17-x "$TMP/wt"
  run_common dw_worktree_of "$REPO" feat/17-x
  assert_success
  assert_output "$TMP/wt"
  run_common dw_worktree_of "$REPO" feat/1-x
  assert_success
  assert_output ""
}
