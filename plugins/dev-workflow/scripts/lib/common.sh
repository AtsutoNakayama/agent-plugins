# shellcheck shell=bash
# 各スクリプトから source する共通処理。
# macOS 標準の bash 3.2 でも動くよう、連想配列・mapfile・${var,,} などは使わない。

DW_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DW_PLUGIN_ROOT="$(cd "$DW_SCRIPTS_DIR/.." && pwd)"
export DW_SCRIPTS_DIR DW_PLUGIN_ROOT

# エラーを1行で標準エラーに出して終了する。
# 使い方: dw_die <メッセージ> [終了コード]
dw_die() {
  printf 'error: %s\n' "$1" >&2
  exit "${2:-1}"
}

dw_warn() {
  printf 'warn: %s\n' "$1" >&2
}

# 必要なコマンドが無ければ終了する。
dw_require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || dw_die "$cmd が見つかりません" 127
  done
}

# 作業中のリポジトリ（ワークツリー）のルート。
dw_repo_root() {
  if [ -n "${WORKFLOW_REPO_ROOT:-}" ]; then
    printf '%s\n' "$WORKFLOW_REPO_ROOT"
  else
    git rev-parse --show-toplevel 2>/dev/null
  fi
}

# メインのワークツリーのルート。コミットしないファイル（*.local.json）の置き場所。
# 使い方: dw_main_root <リポジトリのルート>
# --path-format=absolute は git 2.31 以降にしか無いので、相対パスは自前で絶対パスにする。
dw_main_root() {
  local root="$1" common
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) ;;
    *) common="$root/$common" ;;
  esac
  (cd "$(dirname "$common")" && pwd -P)
}

# ユーザーごとの設定の置き場所。
dw_user_dir() {
  printf '%s\n' "${WORKFLOW_USER_DIR:-$HOME/.claude/workflow}"
}

# 設定ファイルが JSON のオブジェクト1つだけでできているか確かめる。違えば終了する。
dw_check_json() {
  jq -se 'length == 1 and (.[0] | type) == "object"' "$1" >/dev/null 2>&1 \
    || dw_die "JSON のオブジェクトとして読めません: $1" 2
}

# GitHub の GraphQL API を呼び、応答の JSON を出力する。
# テストの偽 gh が応答を切り替えられるよう、クエリには必ず操作名を付ける（query Foo(...)）。
# 使い方: dw_gql <クエリ> [変数の JSON]
dw_gql() {
  jq -n --arg q "$1" --argjson v "${2:-"{}"}" '{query: $q, variables: $v}' \
    | gh api graphql --input -
}
