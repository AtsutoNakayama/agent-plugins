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
  printf '%s\n' "${WORKFLOW_USER_DIR:-$HOME/.claude/dev-workflow}"
}

# ユーザーごとのレビューの観点の置き場所。
dw_user_review_dir() {
  printf '%s\n' "$(dw_user_dir)/review"
}

# gh の最低限のバージョン。issue-cancel.sh の gh issue close --duplicate-of が 2.88.0 から。source した側で使う
# shellcheck disable=SC2034
DW_GH_MIN_VERSION=2.88.0

# 今の gh のバージョン（例: 2.96.0）。分からなければ空
dw_gh_version() {
  gh --version 2>/dev/null | head -n 1 | LC_ALL=C sed -n 's/^gh version \([0-9][0-9.]*\).*/\1/p'
}

# バージョン <a> が <b> 以上なら成功する。数字を . で区切って、前から順に比べる
# 使い方: dw_version_ge <a> <b>
dw_version_ge() {
  local a="$1" b="$2" x y
  while [ -n "$a" ] || [ -n "$b" ]; do
    x="${a%%.*}" y="${b%%.*}"
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
    case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
    case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
  done
  return 0
}

# gh が <バージョン> より古ければ、更新を促して終了する。
# 使い方: dw_require_gh_version <バージョン> <要る理由>
dw_require_gh_version() {
  local now
  now="$(dw_gh_version)"
  [ -n "$now" ] && dw_version_ge "$now" "$1" && return 0
  dw_die "${2}には gh ${1} 以上が要ります（今は ${now:-不明}）。gh を更新してください（https://cli.github.com/）" 2
}

# 設定ファイルが JSON のオブジェクト1つだけでできているか確かめる。違えば終了する。
dw_check_json() {
  jq -se 'length == 1 and (.[0] | type) == "object"' "$1" >/dev/null 2>&1 \
    || dw_die "JSON のオブジェクトとして読めません: $1" 2
}

# ブランチ名を branch.pattern に当て、type と Issue の番号を「<type>|<番号>」で出力する（無いものは空）
# 区切りを空白にすると、read が先頭の空白を外して、type が空のときに番号を type と取り違える
# 使い方: dw_parse_branch <設定の JSON> <ブランチ名>
dw_parse_branch() {
  jq -r --arg b "$2" '
    .labels.types as $t
    | (.branch.pattern
      | gsub("\\{type\\}"; "(?<type>" + ($t | join("|")) + ")")
      | gsub("\\{issue_number\\}"; "(?<issue>[0-9]+)")
      | gsub("\\{slug\\}"; "[a-z0-9]+(?:-[a-z0-9]+)*")
      | "^" + . + "$") as $re
    | (try ($b | capture($re)) catch null) // {}
    | "\(.type // "")|\(.issue // "")"' <<<"$1"
}

# GitHub の GraphQL API を呼び、応答の JSON を出力する。GraphQL は、gh のサブコマンドにも REST にも手段が無いときだけ使う。
# 速さのためではなく、読みやすさ・保守のしやすさ・テストのしやすさと、node id を引き回さないため（設計書 §10）。
# テストの偽 gh が応答を切り替えられるよう、クエリには必ず操作名を付ける（query Foo(...)）。
# 使い方: dw_gql <クエリ> [変数の JSON]
dw_gql() {
  jq -n --arg q "$1" --argjson v "${2:-"{}"}" '{query: $q, variables: $v}' \
    | gh api graphql --input -
}

# gh のコマンド（関数でもよい）を実行して出力する。対象が無い（GraphQL の NOT_FOUND、REST の 404・410）ときは
# 失敗にせず null を出力する。呼ぶ側は「見つからない」を null で判断でき、
# スコープ不足・認証・通信など他の失敗は理由を伝えて止まる。
# 使い方: dw_gh_find <コマンド> [引数]...
dw_gh_find() {
  local out err
  err="$(mktemp)"
  if out="$("$@" 2>"$err")"; then
    rm -f "$err"
    printf '%s\n' "$out"
    return 0
  fi
  out="$(cat "$err")"
  rm -f "$err"
  case "$out" in
    *NOT_FOUND* | *"Could not resolve to"* | *"HTTP 404"* | *"HTTP 410"*) echo null ;;
    *) dw_die "GitHub の API に失敗しました: $out" ;;
  esac
}

# リポジトリの既定のブランチ（<ブランチ> を指定すればそのブランチ）にあるファイルを取り出して <出力先> に書く。
# 無ければ（404）1 を返す。それ以外の失敗は、違う内容で進めないよう終了する。
# 使い方: dw_fetch_repo_file <OWNER/NAME> <パス> <出力先> [ブランチ]
dw_fetch_repo_file() {
  local err query=""
  if [ -n "${4:-}" ]; then
    query="?ref=$(jq -rn --arg b "$4" '$b | @uri')"
  fi
  if err="$(gh api -H 'Accept: application/vnd.github.raw' "repos/$1/contents/$2$query" 2>&1 >"$3")"; then
    return 0
  fi
  case "$err" in
    *"HTTP 404"*) return 1 ;;
    *) dw_die "${1} の ${2} を読めません: $err" ;;
  esac
}

# ルールセットで守るブランチ（チームの base_branch）を出力する。ルールセットはリポジトリ全体で共有するので、
# 個人の層（config.local.json・~/.claude/dev-workflow）は使わず、チームの設定とプラグインの既定だけで決める。
# チームの設定のファイルが無ければプラグインの既定を使い、JSON として読めなければ 1 を返す。
# 使い方: dw_team_base_branch <チームの設定のファイル（空なら無い）>
dw_team_base_branch() {
  local d
  d="$(jq -r '.base_branch' "$DW_PLUGIN_ROOT/defaults/workflow.json")"
  if [ -n "$1" ] && [ -f "$1" ]; then
    jq -r --arg d "$d" '.base_branch // $d' "$1" 2>/dev/null
  else
    printf '%s\n' "$d"
  fi
}

# Story Point に使える値（フィボナッチ数）。設定では変えられない。
# 21 と 34 は受け付けるが、見積もりの精度が低いので分割を勧める。34 より大きい作業は分割する。source した側で使う
# shellcheck disable=SC2034
DW_STORY_POINTS='[1, 2, 3, 5, 8, 13, 21, 34]'
# shellcheck disable=SC2034
DW_STORY_POINT_SPLIT=21

# 親子の Issue（サブ Issue）の目安の深さ。上限（設定の sub_issues.max_depth。既定 3）までは作れるが、
# これより深い Issue を作るときは警告する（一番上の Issue が 1 層目）。source した側で使う
# shellcheck disable=SC2034
DW_SUB_ISSUE_DEPTH_GUIDE=2

# 破壊的変更を表すラベル。type ラベルとは別に付け、PR のタイトルの type の後に ! を付ける（設計書 §5）。source した側で使う
# shellcheck disable=SC2034
DW_BREAKING_LABEL=breaking

# レビューのサブエージェントに指定できるモデル（設定の review.model。Agent ツールの model が受け付ける別名）。
# 設定が null ならサブエージェントはセッションと同じモデルで動く（設計書 §7）。source した側で使う
# shellcheck disable=SC2034
DW_REVIEW_MODELS='["opus", "sonnet", "haiku", "fable"]'

# review.model に書ける値（null か DW_REVIEW_MODELS のどれか）かを確かめる。値は JSON で渡す（例: "opus"・null）
# 使い方: dw_review_model_ok <値の JSON>
dw_review_model_ok() {
  jq -e --argjson v "$1" '$v == null or (($v | type) == "string" and index($v) != null)' <<<"$DW_REVIEW_MODELS" >/dev/null 2>&1
}

# 使えるモデルの一覧を「opus・sonnet・haiku・fable」の形で出力する（エラーのメッセージ用）
dw_review_model_names() {
  jq -r 'join("・")' <<<"$DW_REVIEW_MODELS"
}

# リポジトリの個人の上書き（config.local.json）のパスを出力する。今のワークツリーに無ければ、メインのワークツリーのもの。
# config.sh が読む場所と、setup-models.sh が書く場所を、ここで1つに決める
# 使い方: dw_local_config_file <リポジトリのルート>
dw_local_config_file() {
  local f="$1/.claude/dev-workflow/config.local.json" main
  if [ ! -f "$f" ]; then
    # ワークツリーで作業中なら、メインのワークツリーに置いた個人の設定を使う
    main="$(dw_main_root "$1" || true)"
    [ -n "$main" ] && f="$main/.claude/dev-workflow/config.local.json"
  fi
  printf '%s\n' "$f"
}

# 個人の上書き（dw_local_config_file のファイル）がコミットされてしまわないかを、次のどれかで出力する。
#   ignored      git に無視されていて、コミットもされていない
#   not_ignored  git に無視されていない（.gitignore に足す必要がある）
#   tracked      既にコミットしてある（.gitignore に書いても追跡は外れないので、git rm --cached で外す必要がある）
# 「.gitignore に当たるか」だけでは、コミット済みのファイルを見分けられないので、追跡しているかを先に確かめる
# 使い方: dw_local_config_state <リポジトリのルート>
dw_local_config_state() {
  local f wt
  f="$(dw_local_config_file "$1")"
  wt="${f%/.claude/dev-workflow/config.local.json}"
  if git -C "$wt" ls-files --error-unmatch -- .claude/dev-workflow/config.local.json >/dev/null 2>&1; then
    echo tracked
  elif git -C "$wt" check-ignore -q .claude/dev-workflow/config.local.json 2>/dev/null; then
    echo ignored
  else
    echo not_ignored
  fi
}

# dw_local_config_state の not_ignored・tracked のときに、利用者にする案内を出力する（ignored なら何も出さない）
# 使い方: dw_local_config_hint <状態>
dw_local_config_hint() {
  case "$1" in
    not_ignored) echo "個人の設定（.claude/dev-workflow/config.local.json）が git に無視されていません。.gitignore に足してください" ;;
    tracked) echo "個人の設定（.claude/dev-workflow/config.local.json）がコミットされています。git rm --cached .claude/dev-workflow/config.local.json で追跡を外し、.gitignore に足してください" ;;
  esac
}

# 設定ファイルが review.model を決めていれば（null も「使わないと決めた」として）、その値の JSON を出力する。
# 決めていなければ（ファイルもキーも無い）何も出さずに 1 を返す。JSON のオブジェクトとして読めなければ止まる
# 使い方: dw_review_model_of <設定ファイル>
dw_review_model_of() {
  [ -f "$1" ] || return 1
  dw_check_json "$1"
  jq -e '(.review | type) == "object" and (.review | has("model"))' "$1" >/dev/null || return 1
  jq -c .review.model "$1"
}

# review.model を決めている、このリポジトリの層（team・local）を、優先度の低い順に1行ずつ「<層>\t<ファイル>\t<値の JSON>」で出力する。
# 導入したリポジトリだけに効かせるため、ユーザーの層（~/.claude/dev-workflow/config.json）は読まない（設計書 §7）。
# どちらかの層のファイルが JSON のオブジェクトとして読めなければ、書く層でなくても止まる。
# 使い方: dw_review_model_layers <リポジトリのルート>
dw_review_model_layers() {
  local pair name f v
  for pair in "team:$1/.claude/dev-workflow/config.json" "local:$(dw_local_config_file "$1")"; do
    name="${pair%%:*}" f="${pair#*:}"
    [ -f "$f" ] || continue
    # 壊れたファイルで止めるため、$(...) の外で確かめる（中で止めても、そのサブシェルが終わるだけになる）
    dw_check_json "$f"
    v="$(dw_review_model_of "$f")" || continue
    printf '%s\t%s\t%s\n' "$name" "$f" "$v"
  done
}

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
# gh project と REST で操作する。REST の Project の API は所有者の種類（users / orgs）でパスが分かれる。

# 所有者の種類（User / Organization）から、REST と URL に使う所有者のパス（users/<所有者> か orgs/<所有者>）を出力する。
# 使い方: dw_owner_path <所有者の種類> <所有者>
dw_owner_path() {
  case "$1" in
    Organization) printf 'orgs/%s\n' "$2" ;;
    *) printf 'users/%s\n' "$2" ;;
  esac
}

# Project の id（node id）・番号・URL・REST のパス（restPath。users/<所有者>/projectsV2/<番号> など）と
# 項目（Status の選択肢を含む）を出力する。無ければ案内して止まる。
# 項目は {id（node id）, databaseId（REST の数値の id）, name, dataType（REST の data_type。number・single_select など）,
# options: [{id, name}]} の配列。
# gh project field-list は数値の項目と文字列の項目を区別しないので、項目は REST で読む。
# 使い方: dw_project_fields <所有者> <番号>
dw_project_fields() {
  local project path fields
  project="$(dw_gh_find gh project view "$2" --owner "$1" --format json)" || return 1
  # 無い Project は gh がエラー（Could not resolve to a ProjectV2）を返すので、dw_gh_find で null に揃えてから案内する
  [ "$project" != null ] || dw_die "Project が見つかりません: ${1}/${2}（setup-project.sh で設定してください）"
  path="$(dw_owner_path "$(jq -r .owner.type <<<"$project")" "$1")"
  fields="$(gh api --paginate "$path/projectsV2/$2/fields?per_page=100" | jq -sc 'add // []')" || return 1
  jq -c --argjson f "$fields" --arg p "$path/projectsV2/$2" '{id, number, url, restPath: $p,
    fields: ($f | map({id: .node_id, databaseId: .id, name, dataType: .data_type,
      options: ((.options // []) | map({id, name: (.name.raw // .name)}))}))}' <<<"$project"
}

# Issue などを Project に追加し、項目の id（node id）を出力する。既に入っていれば既存の項目が返る。
# Project の自動追加と同時に走ると、片方が「Content already exists」で失敗する。再試行すれば既存の項目が返るので、
# その失敗のときだけ、待って最大3回まで試す（待つ秒数は DW_RETRY_SLEEP、既定 1）。
# それでも「Content already exists」で失敗したときは、項目が既にあるので、項目の一覧（REST）から探して、その id を使う。
# 見つからないとき、ほかのエラーのときは、エラーを出して止まる。
# 使い方: dw_project_add_item <所有者> <番号> <Issue の URL>
dw_project_add_item() {
  local out errfile tries=0 existing
  errfile="$(mktemp)"
  while :; do
    if out="$(gh project item-add "$2" --owner "$1" --url "$3" --format json 2>"$errfile")"; then
      rm -f "$errfile"
      jq -er '.id' <<<"$out"
      return
    fi
    tries=$((tries + 1))
    if grep -q 'Content already exists' "$errfile"; then
      if [ "$tries" -lt 3 ]; then
        sleep "${DW_RETRY_SLEEP:-1}"
        continue
      fi
      if existing="$(dw_project_find_item "$1" "$2" "$3")" && [ -n "$existing" ]; then
        rm -f "$errfile"
        printf '%s\n' "$existing"
        return
      fi
    fi
    cat "$errfile" >&2
    rm -f "$errfile"
    return 1
  done
}

# Project の項目のうち、リポジトリの Issue <番号> の項目（REST の項目。node_id が gh project で使う id）を出力する。無ければ null。
# Issue から項目を引く REST は無いので、項目の一覧をリポジトリで絞り、ページを辿って、リポジトリと番号で探す
# （番号で絞る検索は無く、文字列での検索は本文などにも当たるため）。値を読む項目の databaseId を渡すと、その値も fields に入る。
# 使い方: dw_project_item <Project の REST のパス（restPath）> <所有者/名前> <Issue の番号> [<値を読む項目の databaseId>]
dw_project_item() {
  local args
  args=(-f q="repo:$2 is:issue" -f per_page=100)
  [ -z "${4:-}" ] || args+=(-f fields="$4")
  gh api --paginate "$1/items" -X GET "${args[@]}" \
    | jq -sc --arg r "$2" --argjson n "$3" '
        [add // [] | .[] | select(.content.number == $n and (.content.repository_url | endswith("/repos/" + $r)))][0]'
}

# Project の項目から、<Issue の URL> の項目の id（node id）を探して出力する。無ければ何も出さずに失敗する。
# 使い方: dw_project_find_item <所有者> <番号> <Issue の URL>
dw_project_find_item() {
  local project path repo n id
  # URL は https://<ホスト>/<所有者>/<名前>/issues/<番号>
  repo="$(sed -nE 's#^https://[^/]+/([^/]+/[^/]+)/issues/[0-9]+$#\1#p' <<<"$3")"
  n="${3##*/}"
  [ -n "$repo" ] || return 1
  project="$(gh project view "$2" --owner "$1" --format json 2>/dev/null)" || return 1
  path="$(dw_owner_path "$(jq -r .owner.type <<<"$project")" "$1")/projectsV2/$2"
  id="$(dw_project_item "$path" "$repo" "$n" 2>/dev/null | jq -r '.node_id // empty')" || return 1
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

# 項目の値を設定する。値は gh project item-edit のオプションで渡す（--single-select-option-id <id> や --number <数>。
# 空欄にするなら --clear だけ）。
# 使い方: dw_project_set_field <Project の id> <項目の id> <フィールドの id> <オプション> [値]
dw_project_set_field() {
  gh project item-edit --project-id "$1" --id "$2" --field-id "$3" "${@:4}" >/dev/null
}
