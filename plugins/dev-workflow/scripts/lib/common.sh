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

# リポジトリの既定のブランチにあるファイルを取り出して <出力先> に書く。
# 無ければ（404）1 を返す。それ以外の失敗は、違う内容で進めないよう終了する。
# 使い方: dw_fetch_repo_file <OWNER/NAME> <パス> <出力先>
dw_fetch_repo_file() {
  local err
  if err="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$1/contents/$2" 2>&1 >"$3")"; then
    return 0
  fi
  case "$err" in
    *"HTTP 404"*) return 1 ;;
    *) dw_die "${1} の ${2} を読めません: $err" ;;
  esac
}

# <ルート> からの相対パスの候補を、大文字小文字を区別せずに順に探し、見つかった実際のパスを出力する
# （GitHub のテンプレートの探し方に合わせる）。末尾が / の候補はディレクトリだけに当てはまる。
# 使い方: dw_find_nocase <ルート> <候補>...
dw_find_nocase() {
  local root="$1" f dir base want entry name
  shift
  for f in "$@"; do
    dir="$(dirname "$f")"
    base="$(basename "$f")"
    want="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    [ -d "$root/$dir" ] || continue
    for entry in "$root/$dir"/* "$root/$dir"/.[!.]*; do
      [ -e "$entry" ] || continue
      case "$f" in */) [ -d "$entry" ] || continue ;; esac
      name="$(basename "$entry")"
      if [ "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" = "$want" ]; then
        if [ "$dir" = . ]; then printf '%s\n' "$name"; else printf '%s\n' "$dir/$name"; fi
        return 0
      fi
    done
  done
  return 1
}
