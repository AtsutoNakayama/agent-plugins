#!/usr/bin/env bats
# 共通の関数（scripts/lib/common.sh）のうち、リポジトリの配置で結果が変わるもの。
# 使うスクリプトのテストでは配置を網羅しにくいので、関数を直接呼んで確かめる。

load test_helper

# common.sh を読み込んで関数を呼ぶ。使い方: run_fn <関数> <引数>...
run_fn() {
  # 引数は bash -c の位置引数で渡す（$1 は展開させない）
  # shellcheck disable=SC2016
  run "${TEST_BASH:-bash}" -c '. "$1"; shift; "$@"' _ "$SCRIPTS/lib/common.sh" "$@"
}

# サブモジュール（$TMP/super/sm。中身は REPO）を作る
make_submodule() {
  git init -q -b main "$TMP/super"
  git -C "$TMP/super" commit -q --allow-empty -m init
  git -C "$TMP/super" -c protocol.file.allow=always submodule add -q "$REPO" sm
}

@test "dw_main_root は、普通のリポジトリとそのワークツリーで、メインのワークツリーを返す" {
  git worktree add -q "$TMP/wt" -b feat/1-x
  run_fn dw_main_root "$REPO"
  assert_success
  assert_output "$REPO"
  run_fn dw_main_root "$TMP/wt"
  assert_success
  assert_output "$REPO"
}

@test "dw_main_root は、サブモジュールとそのワークツリーで、サブモジュールの作業ツリーを返す（.git/modules を返さない）" {
  make_submodule
  git -C "$TMP/super/sm" worktree add -q "$TMP/smwt" -b feat/1-x
  run_fn dw_main_root "$TMP/super/sm"
  assert_success
  assert_output "$TMP/super/sm"
  run_fn dw_main_root "$TMP/smwt"
  assert_success
  assert_output "$TMP/super/sm"
}

@test "dw_main_root は、--separate-git-dir のリポジトリでは、メインのワークツリーそのものなら返し、ワークツリーからは分からないので失敗する" {
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  git -C "$TMP/sep" commit -q --allow-empty -m init
  git -C "$TMP/sep" worktree add -q "$TMP/sepwt" -b feat/1-x
  run_fn dw_main_root "$TMP/sep"
  assert_success
  assert_output "$TMP/sep"
  # リポジトリの親（$TMP）を返さない
  run_fn dw_main_root "$TMP/sepwt"
  assert_failure
  assert_output ""
}

@test "dw_repo_main_root は、リポジトリから、確かめたメインのワークツリーを返す（bare リポジトリは分からない）" {
  run_fn dw_repo_main_root "$REPO/.git"
  assert_success
  assert_output "$REPO"
  make_submodule
  run_fn dw_repo_main_root "$TMP/super/.git/modules/sm"
  assert_success
  assert_output "$TMP/super/sm"
  git clone -q --mirror "$REPO" "$TMP/mirror.git"
  run_fn dw_repo_main_root "$TMP/mirror.git"
  assert_failure
}

@test "dw_is_set_up は、サブモジュールのワークツリーでは、サブモジュールのメインのワークツリーのチームの設定を見る" {
  make_submodule
  git -C "$TMP/super/sm" worktree add -q "$TMP/smwt" -b feat/1-x
  run_fn dw_is_set_up "$TMP/smwt"
  assert_failure
  mark_set_up "$TMP/super/sm"
  run_fn dw_is_set_up "$TMP/smwt"
  assert_success
  # 上のリポジトリ（super）は導入していない
  run_fn dw_is_set_up "$TMP/super"
  assert_failure
}
