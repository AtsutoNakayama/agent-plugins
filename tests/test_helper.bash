# shellcheck shell=bash
# テスト共通の準備。一時ディレクトリに git リポジトリとユーザー設定の置き場所を作る。
# TEST_BASH でスクリプトを実行する bash を指定できる（例: macOS の /bin/bash 3.2）。

SCRIPTS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/scripts"

setup() {
  # macOS の /var は /private/var へのシンボリックリンクなので、git が返すパスと揃えるため実体にする
  TMP="$(cd "$(mktemp -d)" && pwd -P)"
  REPO="$TMP/repo"
  export WORKFLOW_USER_DIR="$TMP/user"
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
