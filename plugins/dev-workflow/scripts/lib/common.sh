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

# dw_gql と同じだが、対象が無い（NOT_FOUND）ときは失敗にせず {"data": null} を出力する。
# 呼ぶ側は「見つからない」を null で判断でき、スコープ不足・認証・通信など他の失敗は理由を伝えて止まる。
# 使い方: dw_gql_find <クエリ> [変数の JSON]
dw_gql_find() {
  local out err
  err="$(mktemp)"
  if out="$(dw_gql "$@" 2>"$err")"; then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  out="$(cat "$err")"
  rm -f "$err"
  case "$out" in
    *NOT_FOUND* | *"Could not resolve to"*) echo '{"data": null}' ;;
    *) dw_die "GitHub の API に失敗しました: $out" ;;
  esac
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

# Story Point に使える値（フィボナッチ数）。設定では変えられない。
# 21 と 34 は受け付けるが、見積もりの精度が低いので分割を勧める。34 より大きい作業は分割する。source した側で使う
# shellcheck disable=SC2034
DW_STORY_POINTS='[1, 2, 3, 5, 8, 13, 21, 34]'
# shellcheck disable=SC2034
DW_STORY_POINT_SPLIT=21

# GitHub がテンプレートを探す場所。source した側で使う。
# 大文字小文字は区別せず、拡張子は .md・.txt・なしを認める。書き方は dw_find_nocase を参照
# PR テンプレート（1ファイル）と、複数の PR テンプレートを置くディレクトリ（?template= で選ぶ形式）
# shellcheck disable=SC2034
DW_PR_TEMPLATE_FILES=".github/pull_request_template docs/pull_request_template pull_request_template"
# shellcheck disable=SC2034
DW_PR_TEMPLATE_DIRS=".github/pull_request_template/ docs/pull_request_template/ pull_request_template/"
# Issue テンプレートのディレクトリと、古い形式の1ファイル
# shellcheck disable=SC2034
DW_ISSUE_TEMPLATES=".github/issue_template/ .github/issue_template docs/issue_template issue_template"

# <ルート> からの相対パスの候補を、大文字小文字を区別せずに順に探し、見つかった実際のパスを出力する
# （GitHub のテンプレートの探し方に合わせる）。候補の書き方:
#   末尾が /         そのディレクトリだけに当てはまる（例: .github/issue_template/）
#   拡張子が無い     同じ名前で、拡張子が .md・.txt・なしのファイルに当てはまる（例: docs/pull_request_template →
#                    docs/PULL_REQUEST_TEMPLATE.md、docs/pull_request_template.txt）
#   拡張子がある     その名前のファイルだけに当てはまる
# 候補を空白区切りの一覧から分割して渡せるよう、* などのワイルドカードは使わない。
# 使い方: dw_find_nocase <ルート> <候補>...
dw_find_nocase() {
  local root="$1" f dir base want entry name lower
  shift
  for f in "$@"; do
    dir="$(dirname "$f")"
    base="$(basename "$f")"
    want="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    [ -d "$root/$dir" ] || continue
    for entry in "$root/$dir"/* "$root/$dir"/.[!.]*; do
      [ -e "$entry" ] || continue
      # ディレクトリの候補はディレクトリだけ、ファイルの候補はファイルだけに当てはめる
      case "$f" in
        */) [ -d "$entry" ] || continue ;;
        *) [ ! -d "$entry" ] || continue ;;
      esac
      name="$(basename "$entry")"
      lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
      # 拡張子の有無は、ディレクトリ部分（.github など）ではなく候補の名前で見る
      case "$f" in
        */) [ "$lower" = "$want" ] || continue ;;
        *)
          case "$base" in
            *.*) [ "$lower" = "$want" ] || continue ;;
            # GitHub が例に挙げる .md・.txt と、拡張子なしだけを認める（.md~ などのバックアップは除く）
            *) [ "$lower" = "$want" ] || [ "$lower" = "$want.md" ] || [ "$lower" = "$want.txt" ] || continue ;;
          esac
          ;;
      esac
      if [ "$dir" = . ]; then printf '%s\n' "$name"; else printf '%s\n' "$dir/$name"; fi
      return 0
    done
  done
  return 1
}

# --- GitHub Project（v2） -------------------------------------------------------
# GraphQL の変数（$login など）を bash に展開させないため、クエリはシングルクォートで書く（SC2016 は意図どおり）

# Project の id・番号・URL と項目（Status の選択肢を含む）を出力する。無ければ案内して止まる。
# 使い方: dw_project_fields <所有者> <番号>
# shellcheck disable=SC2016
dw_project_fields() {
  local project
  project="$(dw_gql_find 'query ProjectFields($login: String!, $number: Int!) {
    repositoryOwner(login: $login) { ... on ProjectV2Owner { projectV2(number: $number) {
      id number url
      fields(first: 50) { nodes {
        ... on ProjectV2FieldCommon { id name dataType }
        ... on ProjectV2SingleSelectField { options { id name } } } } } } }
  }' "$(jq -nc --arg l "$1" --argjson n "$2" '{login: $l, number: $n}')" \
    | jq -c '.data.repositoryOwner.projectV2 // null')" || return 1
  # 無い Project は API がエラー（NOT_FOUND）で返すので、dw_gql_find で null に揃えてから案内する
  [ "$project" != null ] || dw_die "Project が見つかりません: ${1}/${2}（setup-project.sh で設定してください）"
  printf '%s\n' "$project"
}

# Issue などを Project に追加し、項目の id を出力する。既に入っていれば既存の項目が返る。
# 使い方: dw_project_add_item <Project の id> <Issue などの node id>
# shellcheck disable=SC2016
dw_project_add_item() {
  dw_gql 'mutation AddItem($p: ID!, $c: ID!) {
    addProjectV2ItemById(input: {projectId: $p, contentId: $c}) { item { id } }
  }' "$(jq -nc --arg p "$1" --arg c "$2" '{p: $p, c: $c}')" \
    | jq -er '.data.addProjectV2ItemById.item.id'
}

# 項目の値を設定する。値は {"singleSelectOptionId": ...} や {"number": ...} の JSON。
# 使い方: dw_project_set_field <Project の id> <項目の id> <フィールドの id> <値の JSON>
# shellcheck disable=SC2016
dw_project_set_field() {
  dw_gql 'mutation SetField($p: ID!, $i: ID!, $f: ID!, $v: ProjectV2FieldValue!) {
    updateProjectV2ItemFieldValue(input: {projectId: $p, itemId: $i, fieldId: $f, value: $v}) { projectV2Item { id } }
  }' "$(jq -nc --arg p "$1" --arg i "$2" --arg f "$3" --argjson v "$4" '{p: $p, i: $i, f: $f, v: $v}')" \
    | jq -e '.data.updateProjectV2ItemFieldValue.projectV2Item.id' >/dev/null
}
