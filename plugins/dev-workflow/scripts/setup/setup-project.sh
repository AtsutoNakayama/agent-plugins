#!/usr/bin/env bash
# GitHub Project（v2）を作成または既存のものに接続し、ワークフローで使える状態に揃える。
# 何度実行しても同じ結果になる。設定（列名・Story Point の項目名）は今いるリポジトリから読む。
#
# 使い方: setup-project.sh [オプション]
#   --repo OWNER/NAME  対象のリポジトリ（既定: 今いるリポジトリ）
#   --owner LOGIN      Project の所有者（既定: 設定の project.owner、無ければリポジトリの所有者）
#   --number N         既存の Project に接続する（既定: 設定の project.number）
#   --title TITLE      Project の名前で探し、無ければその名前で作る（既定: リポジトリ名）
#   --hold-column NAME 保留の列（status.hold）の名前。Status 列に足し、--write-config なら設定にも書く
#                      （--write-config で今の保留の列から変えるとき、今の列にこのリポジトリの開いている Issue が
#                      残っていれば、何も変えずに止まる）
#   --write-config     .claude/dev-workflow/config.json の project（と --hold-column の status.hold）を書き換える
#                      （対象のリポジトリの中で実行すること）
#   --dry-run          変更せず、行う予定の操作だけを出力する
#
# 行うこと:
#   1. Project の特定（--number → 設定の project.number → 名前の完全一致）、無ければ作成
#   2. リポジトリとの紐付け
#   3. Status 列に設定の status の列名を揃える（既存の選択肢と値は残す。足す列は、設定の順で前にある列の後ろに入れる）
#   4. Story Point（数値の項目）の追加
#   5. Project に入っていないオープンな Issue を追加し、Status が空なら todo の列にする
#   6. 組み込みの自動追加（Auto-add to project）が有効か確認する（API では有効にできない）
# GitHub の操作は gh project と REST で行う。GraphQL は、gh にも REST にも手段が無い操作（Issue から Project の項目を引く・
# Project の詳細・Status の選択肢を足す）だけに使う（設計書 §10）。
# GraphQL の変数（$login など）を bash に展開させないため、クエリはシングルクォートで書く
# shellcheck disable=SC2016
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^# GitHub の操作は/{/^# GitHub の操作は/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

repo="" owner="" number="" title="" hold="" write_config=false dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo | --owner | --number | --title | --hold-column)
      need_value "$@"
      case "$1" in
        --repo) repo="$2" ;;
        --owner) owner="$2" ;;
        --number) number="$2" ;;
        --title) title="$2" ;;
        --hold-column) hold="$2" ;;
      esac
      shift 2
      ;;
    --write-config) write_config=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
case "$number" in
  *[!0-9]*) dw_die "--number には数字を指定してください: $number" 64 ;;
esac

config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
# 今の保留の列。--hold-column で別の列に変えるとき、今の列に Issue が残っていないかを確かめるのに使う
old_hold="$(jq -r '.status.hold // empty' <<<"$config")"
# --hold-column は、設定に書く前でも Status 列に足せるよう、読んだ設定に重ねる
[ -z "$hold" ] || config="$(jq -c --arg h "$hold" '.status.hold = $h' <<<"$config")"
dw_check_hold_column "$config"
# 設定に書かれた順のまま重複を除く。null と空文字は、その役割の列を使わないという意味なので外す
status_names="$(jq -c 'reduce (.status[] | select(. != null and . != "")) as $s ([]; if any(.[]; . == $s) then . else . + [$s] end)' <<<"$config")"
todo_name="$(jq -r '.status.todo // empty' <<<"$config")"
sp_name="$(jq -r '.story_point.field' <<<"$config")"

actions='[]'
# 行った（または dry-run で行う予定の）操作を記録する
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# 変更を伴う操作（gh のコマンドか関数）。dry-run では呼ばずに null を返す
mutate() {
  if $dry_run; then
    echo null
  else
    "$@"
  fi
}

msg_status() { printf 'Status 列に %s を追加する' "$(jq -r 'join(" / ")' <<<"$1")"; }
msg_sp="Story Point（数値）の項目「${sp_name}」を追加する"

# --- リポジトリと所有者 ---------------------------------------------------------
repo_json="$(gh repo view ${repo:+"$repo"} --json id,name,nameWithOwner,owner)"
repo_id="$(jq -r .id <<<"$repo_json")"
repo_nwo="$(jq -r .nameWithOwner <<<"$repo_json")"

if $write_config && [ -n "$repo" ]; then
  here_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ "$here_nwo" = "$repo_nwo" ] \
    || dw_die "--write-config は対象のリポジトリ（${repo_nwo}）の中で実行してください" 64
fi

# --number も --title も無ければ、設定済みの Project を使う
cfg_owner="$(jq -r '.project.owner // empty' <<<"$config")"
cfg_number="$(jq -r '.project.number // empty' <<<"$config")"
if [ -z "$number" ] && [ -z "$title" ] && [ -n "$cfg_number" ] \
  && { [ -z "$owner" ] || [ "$owner" = "$cfg_owner" ]; }; then
  owner="${cfg_owner:-$owner}"
  number="$cfg_number"
fi
[ -n "$owner" ] || owner="$(jq -r .owner.login <<<"$repo_json")"
[ -n "$title" ] || title="$(jq -r .name <<<"$repo_json")"

# 所有者の種類（User / Organization）。REST の users/<login> は組織にも答える
owner_type="$(dw_gh_find gh api "users/$owner" | jq -r '.type // empty')"
[ -n "$owner_type" ] || dw_die "所有者が見つかりません: $owner"
owner_path="$(dw_owner_path "$owner_type" "$owner")"

# --- 1. Project を見つける・作る ------------------------------------------------
# 名前の完全一致で探す。検索は曖昧一致なので使わず、全件を見る。
# gh project list は閉じた Project を含めず、--limit の件数までページを送って読む（上限は実際には届かない大きさにする）
find_by_title() {
  gh project list --owner "$owner" --limit 10000 --format json \
    | jq -c --arg t "$title" '[.projects[] | select(.title == $t and (.closed | not))][0] // null
      | if . then {id, number, title, url} else . end'
}

# Project を作成し、リポジトリと紐付ける。作成した Project を出力する
create_project() {
  local p
  p="$(gh project create --owner "$owner" --title "$title" --format json | jq -c '{id, number, title, url}')" || return 1
  [ "$(jq -r '.id // empty' <<<"$p")" != "" ] || { echo null; return 0; }
  # 作成と紐付けは別の呼び出しなので、紐付けだけ失敗したら Project ができていることを伝える
  gh project link "$(jq -r .number <<<"$p")" --owner "$owner" --repo "$repo_nwo" >/dev/null \
    || dw_die "Project「${title}」（#$(jq -r .number <<<"$p")）は作りましたが、リポジトリ ${repo_nwo} と紐付けられませんでした（もう一度実行すると紐付けます）"
  printf '%s\n' "$p"
}

created=false
if [ -n "$number" ]; then
  project="$(dw_gh_find gh project view "$number" --owner "$owner" --format json | jq -c 'if . then {id, number, title, url} else . end')"
  # 無い Project は gh がエラー（Could not resolve to a ProjectV2）を返すので、dw_gh_find で null に揃えてから案内する
  [ "$project" != null ] || dw_die "Project が見つかりません: $owner/$number"
else
  project="$(find_by_title)"
  if [ "$project" = null ]; then
    note "Project「${title}」を作成し、リポジトリ $repo_nwo と紐付ける"
    created=true
    project="$(mutate create_project)"
    if ! $dry_run && [ "$project" = null ]; then
      dw_die "Project を作成できませんでした（gh project create の応答に id がありません）"
    fi
  fi
fi

project_id="$(jq -r '.id // empty' <<<"$project")"
project_number="$(jq -r '.number // empty' <<<"$project")"

# オープンな Issue と、それぞれがこの Project に入っているか（Issue 側から調べる）。
# gh にも REST にも、Issue から Project の項目を引く手段が無いので GraphQL で読む（設計書 §10）
open_issues() {
  local cursor="" next page
  while :; do
    page="$(dw_gql 'query OpenIssues($owner: String!, $name: String!, $after: String) {
      repository(owner: $owner, name: $name) {
        issues(states: OPEN, first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { url number projectItems(first: 50) { nodes { id project { id }
            fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } }
    }' "$(jq -nc --arg r "$repo_nwo" --arg a "$cursor" \
      '{owner: ($r | split("/")[0]), name: ($r | split("/")[1]), after: (if $a == "" then null else $a end)}')" \
      | jq -c '.data.repository.issues')"
    jq -c --arg p "$project_id" '.nodes[] | {url, number,
      item: ([.projectItems.nodes[] | select(.project.id == $p)][0] // null
        | if . then {id, status: (.fieldValueByName.name // null)} else null end)}' <<<"$page"
    [ "$(jq -r .pageInfo.hasNextPage <<<"$page")" = true ] || break
    # カーソルが空か前回と同じなら、同じページを読み続けてしまう（無限ループ）ので止める
    next="$(jq -r '.pageInfo.endCursor // empty' <<<"$page")"
    { [ -n "$next" ] && [ "$next" != "$cursor" ]; } \
      || dw_die "オープンな Issue のページ送りが進みません: ${repo_nwo}"
    cursor="$next"
  done
}

workflows_url=""
auto_add=null
item_closed=null
items_added=0
items_todo=0
if [ -z "$project_id" ]; then
  # dry-run で Project を新しく作る場合。以降は作成後にしか確かめられないので、予定だけを記録する
  note "Status 列に不足する列（$(jq -r 'join(" / ")' <<<"$status_names") のうち無いもの）があれば追加する"
  note "$msg_sp"
  note "オープンな Issue $(gh issue list -R "$repo_nwo" --state open --limit 1000 --json number -q length) 件を追加し、「${todo_name}」にする"
else
  workflows_url="https://github.com/$owner_path/projects/$project_number/workflows"

  # 紐付け済みのリポジトリと組み込みの自動化（workflows）は gh にも REST にも無いので GraphQL で読む。
  # Status の選択肢を足す操作（GraphQL）に要る項目の一覧も、同じクエリでまとめて取る（設計書 §10）
  detail() {
    dw_gql 'query ProjectDetail($id: ID!) {
      node(id: $id) { ... on ProjectV2 {
        repositories(first: 100) { nodes { id } }
        fields(first: 50) { nodes {
          ... on ProjectV2FieldCommon { id name dataType }
          ... on ProjectV2SingleSelectField { options { id name color description } } } }
        workflows(first: 20) { nodes { name enabled } } } }
    }' "$(jq -nc --arg id "$project_id" '{id: $id}')" | jq -c '.data.node'
  }
  project_detail="$(detail)"

  # オープンな Issue と、それぞれのこの Project での列。手順5で使い、その前に保留の列の確認にも使う。
  # $(...) を直接ループに渡すと API の失敗で止まらないので、先に変数に受ける
  issues="$(open_issues)"

  # 設定の保留の列を別の列に変えるとき、今の列に Issue が残ったまま設定だけを変えると、その Issue は Todo でも
  # 保留でもなくなり、task-next のどこにも出なくなる。Project も設定も変える前に止める
  if $write_config && [ -n "$hold" ] && [ -n "$old_hold" ] && [ "$hold" != "$old_hold" ]; then
    left="$(jq -rs --arg h "$old_hold" '[.[] | select(.item.status == $h) | "#\(.number)"] | join("・")' <<<"$issues")"
    [ -z "$left" ] \
      || dw_die "保留の列「${old_hold}」に Issue が残っています（${left}）。task-status で新しい列「${hold}」へ移してから、もう一度実行してください（列の名前を変えるだけなら、Project の画面で列の名前を変え、設定の status.hold も同じ名前にしてください）" 2
  fi

  # --- 2. リポジトリとの紐付け --------------------------------------------------
  if ! jq -e --arg r "$repo_id" 'any(.repositories.nodes[]; .id == $r)' <<<"$project_detail" >/dev/null; then
    note "リポジトリ $repo_nwo と紐付ける"
    mutate gh project link "$project_number" --owner "$owner" --repo "$repo_nwo" >/dev/null
  fi

  # --- 3. Status 列 -------------------------------------------------------------
  status_field="$(jq -c '[.fields.nodes[] | select(.name == "Status")][0] // null' <<<"$project_detail")"
  [ "$status_field" != null ] || dw_die "Project に Status 列がありません"
  missing="$(jq -c --argjson want "$status_names" '[.options[].name] as $have | $want - $have' <<<"$status_field")"
  if [ "$missing" != "[]" ]; then
    note "$(msg_status "$missing")"
    # 既存の選択肢は id を付けて渡し、Issue に付いている値を残す。
    # 足す列は、設定の順（todo・hold・start・pr_opened・done）でそれより前にある列のうち最後のものの後ろに入れる
    # （無ければ、後ろにある列のうち最初のものの前。どちらも無ければ末尾）。
    # 末尾に足すと、pr_opened の列が done の列より後ろに並んでしまう。利用者が足した列の位置は変えない
    # gh にも REST にも既存の項目を変える操作が無いので GraphQL を使う（設計書 §10）
    opts="$(jq -c --argjson m "$missing" --argjson want "$status_names" '
      reduce $m[] as $n (.options;
        ($want | index($n)) as $i | $want[:$i] as $pre | $want[$i + 1:] as $post
        | ([to_entries[] | select(.value.name | IN($pre[])) | .key] | last) as $after
        | ([to_entries[] | select(.value.name | IN($post[])) | .key] | first) as $before
        | (if $after != null then $after + 1 elif $before != null then $before else length end) as $at
        | .[:$at] + [{name: $n, color: "GRAY", description: ""}] + .[$at:])' <<<"$status_field")"
    mutate dw_gql 'mutation UpdateStatus($f: ID!, $opts: [ProjectV2SingleSelectFieldOptionInput!]!) {
      updateProjectV2Field(input: {fieldId: $f, singleSelectOptions: $opts}) { projectV2Field { ... on ProjectV2FieldCommon { id } } }
    }' "$(jq -c --argjson o "$opts" '{f: .id, opts: $o}' <<<"$status_field")" >/dev/null
    if ! $dry_run; then
      project_detail="$(detail)"
      status_field="$(jq -c '[.fields.nodes[] | select(.name == "Status")][0]' <<<"$project_detail")"
    fi
  fi

  # --- 4. Story Point -----------------------------------------------------------
  sp_type="$(jq -r --arg n "$sp_name" '[.fields.nodes[] | select(.name == $n)][0].dataType // empty' <<<"$project_detail")"
  if [ -z "$sp_type" ]; then
    note "$msg_sp"
    mutate gh project field-create "$project_number" --owner "$owner" --name "$sp_name" --data-type NUMBER >/dev/null
  elif [ "$sp_type" != NUMBER ]; then
    dw_warn "項目「${sp_name}」が数値ではありません（${sp_type}）。合計を表示できないので数値の項目にしてください"
  fi

  # --- 5. 入っていない Issue だけ追加し、Status が空なら todo にする --------------
  status_field_id="$(jq -r .id <<<"$status_field")"
  todo_id="$(jq -r --arg n "$todo_name" '[.options[] | select(.name == $n)][0].id // empty' <<<"$status_field")"
  if [ -z "$todo_id" ]; then
    dw_warn "todo の列「${todo_name:-（未設定）}」が Status 列に無いので、Issue の Status は設定しません"
  fi

  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    item_id="$(jq -r '.item.id // empty' <<<"$issue")"
    if [ -z "$item_id" ]; then
      items_added=$((items_added + 1))
      if ! $dry_run; then
        item_id="$(dw_project_add_item "$owner" "$project_number" "$(jq -r .url <<<"$issue")")"
      fi
    fi
    if [ "$(jq -r '.item.status // empty' <<<"$issue")" = "" ] && [ -n "$todo_id" ]; then
      items_todo=$((items_todo + 1))
      if ! $dry_run; then
        dw_project_set_field "$project_id" "$item_id" "$status_field_id" --single-select-option-id "$todo_id"
      fi
    fi
  done <<<"$issues"
  [ "$items_added" -eq 0 ] || note "オープンな Issue $items_added 件を Project に追加する"
  [ "$items_todo" -eq 0 ] || note "Status が空の Issue $items_todo 件を「${todo_name}」にする"

  # --- 6. 組み込みの自動化の確認 ------------------------------------------------
  auto_add="$(jq 'any(.workflows.nodes[]; .name == "Auto-add to project" and .enabled)' <<<"$project_detail")"
  item_closed="$(jq 'any(.workflows.nodes[]; .name == "Item closed" and .enabled)' <<<"$project_detail")"
  if [ "$auto_add" != true ]; then
    dw_warn "自動追加（Auto-add to project）が無効です。API では有効にできないので、次の画面で有効にしてください:"
    dw_warn "  $workflows_url"
    dw_warn "  「Auto-add to project」→ リポジトリに ${repo_nwo}、フィルターに is:issue を指定 → Save and turn on workflow"
  fi
  if [ "$item_closed" != true ]; then
    dw_warn "「Item closed」（Issue が閉じたら Done に移す）が無効です。同じ画面で有効にしてください"
  fi
fi

# --- 設定ファイルへの書き込み ---------------------------------------------------
if $write_config; then
  repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください"
  config_file="$repo_root/.claude/dev-workflow/config.json"
  # 既に同じ project なら書き直さない（書式の違いで空白だけの差分を作らない）
  write=true
  if [ -n "$project_number" ] && [ -f "$config_file" ] \
    && jq -e --arg o "$owner" --argjson n "$project_number" '.project.owner == $o and .project.number == $n' \
      "$config_file" >/dev/null 2>&1; then
    write=false
  fi
  $write && note "$config_file の project を $owner/${project_number:-（作成後の番号）} にする"
  if $write && ! $dry_run; then
    dw_write_config "$config_file" --arg o "$owner" --argjson n "$project_number" '.project = {owner: $o, number: $n}'
  fi
  # 保留の列も、既に同じ名前なら書き直さない
  if [ -n "$hold" ] && ! { [ -f "$config_file" ] \
    && jq -e --arg h "$hold" '.status.hold == $h' "$config_file" >/dev/null 2>&1; }; then
    note "$config_file の status.hold を「${hold}」にする"
    $dry_run || dw_write_config "$config_file" --arg h "$hold" '.status.hold = $h'
  fi
fi

jq -n --argjson p "$project" --arg owner "$owner" --argjson created "$created" \
  --argjson added "$items_added" --argjson todo "$items_todo" \
  --argjson auto "$auto_add" --argjson closed "$item_closed" --arg url "$workflows_url" \
  --argjson dry "$dry_run" --argjson actions "$actions" '{
    dry_run: $dry,
    project: (($p // {}) + {owner: $owner, created: $created}),
    items: {added: $added, set_todo: $todo},
    workflows: {auto_add: $auto, item_closed: $closed, url: (if $url == "" then null else $url end)},
    actions: $actions
  }'
