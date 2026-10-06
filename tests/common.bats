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

@test "dw_read_issue は、Issue なら JSON を出し、PR の番号・無い番号なら終了コード 2 で止まる" {
  load fake_gh
  setup_fake_gh
  run_common dw_read_issue 17 title
  assert_success
  assert_equal "$(jq -r .title <<<"$output")" "作業 17"
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21}' >"$FIX/issue-21.json"
  run_common dw_read_issue 21 number
  assert_failure 2
  assert_output "error: #21 は PR です。Issue の番号を指定してください"
  run_common dw_read_issue 99 number "重複の元の Issue"
  assert_failure 2
  assert_output "error: 重複の元の Issue #99 が me/demo にありません"
  FAKE_FAIL=issue-view FAKE_FAIL_MSG="HTTP 401: Bad credentials" run_common dw_read_issue 17 number
  assert_failure 1
  assert_output "error: Issue #17 を読めません: HTTP 401: Bad credentials"
}

@test "dw_read_issue は、PR の番号で止まるとき、見つからないときと同じく、どの値かを名前で示す" {
  load fake_gh
  setup_fake_gh
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21}' >"$FIX/issue-21.json"
  run_common dw_read_issue 21 number "重複の元の Issue"
  assert_failure 2
  assert_output "error: 重複の元の Issue #21 は PR です。Issue の番号を指定してください"
}

@test "dw_try_read_issue は止まらずに、Issue なら JSON を出して 0、PR なら 2、無ければ 3、読めなければ 1 を返す" {
  load fake_gh
  setup_fake_gh
  run_common dw_try_read_issue 17 title
  assert_success
  assert_equal "$(jq -r .title <<<"$output")" "作業 17"
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21}' >"$FIX/issue-21.json"
  run_common dw_try_read_issue 21 number
  assert_failure 2
  assert_output ""
  run_common dw_try_read_issue 99 number
  assert_failure 3
  FAKE_FAIL=issue-view FAKE_FAIL_MSG="HTTP 401: Bad credentials" run_common dw_try_read_issue 17 number
  assert_failure 1
  assert_output "HTTP 401: Bad credentials"
}
