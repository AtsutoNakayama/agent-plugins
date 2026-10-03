# shellcheck shell=bash
# テスト共通の準備。一時ディレクトリに git リポジトリとユーザー設定の置き場所を作る。
# TEST_BASH でスクリプトを実行する bash を指定できる（例: macOS の /bin/bash 3.2）。

SCRIPTS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/scripts"
# 偽の gh から読み込む、GitHub Project の部分（fake_gh_project.bash を参照）
export FAKE_GH_PROJECT="$BATS_TEST_DIRNAME/fake_gh_project.bash"

# assert_success・assert_equal などを使う（git submodule で同梱。git submodule update --init で取得する）
load lib/bats-support/load
load lib/bats-assert/load

setup() {
  # macOS の /var は /private/var へのシンボリックリンクなので、git が返すパスと揃えるため実体にする
  TMP="$(cd "$(mktemp -d)" && pwd -P)"
  REPO="$TMP/repo"
  export WORKFLOW_USER_DIR="$TMP/user"
  export WORKFLOW_USER_REVIEW_DIR="$TMP/user-review"
  # CI やコンテナには git の名前とメールアドレスが無いので、テストでコミットできるよう決めておく
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  mkdir -p "$REPO/.claude" "$WORKFLOW_USER_DIR"
  git -C "$REPO" init -q -b main
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  cd "$REPO" || return 1
}

teardown() {
  rm -rf "$TMP"
}

run_script() {
  local name="$1"
  shift
  run "${TEST_BASH:-bash}" "$SCRIPTS/$name" "$@"
}
