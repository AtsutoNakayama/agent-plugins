#!/usr/bin/env bats
# メインのワークツリーのルートを出力するスクリプト（scripts/main-root.sh）。

load test_helper

@test "メインのワークツリーとワークツリーのどちらからでも、メインのワークツリーを出力する" {
  git worktree add -q "$TMP/wt" -b feat/1-x
  run_script main-root.sh
  assert_success
  assert_equal "$(jq -r .main_root <<<"$output")" "$REPO"
  cd "$TMP/wt"
  run_script main-root.sh
  assert_success
  assert_equal "$(jq -r .main_root <<<"$output")" "$REPO"
}

@test "サブモジュールのワークツリーからは、サブモジュールの作業ツリーを出力する（.git/modules の親ではない）" {
  git init -q -b main "$TMP/super"
  git -C "$TMP/super" commit -q --allow-empty -m init
  git -C "$TMP/super" -c protocol.file.allow=always submodule add -q "$REPO" sm
  git -C "$TMP/super/sm" worktree add -q "$TMP/smwt" -b feat/1-x
  cd "$TMP/smwt"
  run_script main-root.sh
  assert_success
  assert_equal "$(jq -r .main_root <<<"$output")" "$TMP/super/sm"
}

@test "リポジトリの外では終了コード 64、メインのワークツリーが分からなければ終了コード 2 で止まる" {
  cd "$TMP"
  run_script main-root.sh
  assert_failure 64
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  git -C "$TMP/sep" commit -q --allow-empty -m init
  git -C "$TMP/sep" worktree add -q "$TMP/sepwt" -b feat/1-x
  cd "$TMP/sepwt"
  run_script main-root.sh
  assert_failure 2
  assert_output --partial "メインのワークツリーが分かりません"
}
