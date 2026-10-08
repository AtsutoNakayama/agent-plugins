#!/usr/bin/env bats
# main-root.sh（メインのワークツリーの場所を出力する）を確かめる。cleanup までの通しは tests/cleanup.bats。

load test_helper

@test "普通のリポジトリとそのワークツリーで、メインのワークツリーを出力する（サブディレクトリからでも）" {
  git worktree add -q "$TMP/wt" -b feat/1-x
  mkdir "$TMP/wt/sub"
  for d in "$REPO" "$TMP/wt" "$TMP/wt/sub"; do
    cd "$d"
    run_script main-root.sh
    assert_success
    assert_equal "$(jq -c . <<<"$output")" "{\"main_root\":\"$REPO\"}"
  done
}

@test "サブモジュールとそのワークツリーで、.git/modules ではなく、サブモジュールの作業ツリーを出力する（#233）" {
  make_submodule
  git -C "$TMP/super/sm" worktree add -q "$TMP/smwt" -b feat/1-x
  for d in "$TMP/super/sm" "$TMP/smwt"; do
    cd "$d"
    run_script main-root.sh
    assert_success
    assert_equal "$(jq -r .main_root <<<"$output")" "$TMP/super/sm"
  done
}

@test "bare リポジトリ＋ワークツリーの配置では、どのワークツリーからも、.git ファイルを置いたルートを出力し、ルートからも同じ（#233）" {
  git clone -q --bare "$REPO" "$TMP/proj/.bare"
  echo 'gitdir: ./.bare' >"$TMP/proj/.git"
  git -C "$TMP/proj" worktree add -q "$TMP/proj/main" main
  git -C "$TMP/proj" worktree add -q "$TMP/proj/feat" -b feat/1-x
  for d in "$TMP/proj" "$TMP/proj/main" "$TMP/proj/feat"; do
    cd "$d"
    run_script main-root.sh
    assert_success
    assert_equal "$(jq -r .main_root <<<"$output")" "$TMP/proj"
  done
}

@test "求められないとき（--separate-git-dir のワークツリー・リポジトリの外）は、何も出力せずに失敗する（移らずに止まる）" {
  git init -q -b main --separate-git-dir "$TMP/sep.git" "$TMP/sep"
  git -C "$TMP/sep" commit -q --allow-empty -m init
  git -C "$TMP/sep" worktree add -q "$TMP/sepwt" -b feat/1-x
  cd "$TMP/sepwt"
  run_script main-root.sh
  assert_failure
  assert_output --partial "メインのワークツリーが分かりません"
  mkdir "$TMP/outside"
  cd "$TMP/outside"
  run_script main-root.sh
  assert_failure
  refute_output --partial main_root
}

@test "不明な引数は使い方の誤りで止まる" {
  run_script main-root.sh --bogus
  assert_failure 64
}
