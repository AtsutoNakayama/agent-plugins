#!/usr/bin/env bash
# GitHub Project（v2）を作成または既存のものに接続し、ワークフローで使える状態に揃える。
# 何度実行しても同じ結果になる。設定（列名・Story Point の項目名）は今いるリポジトリから読む。
#
# 使い方: setup-project.sh [オプション]
#   --repo OWNER/NAME  対象のリポジトリ（既定: 今いるリポジトリ）
#   --owner LOGIN      Project の所有者（既定: 設定の project.owner、無ければリポジトリの所有者）
#   --number N         既存の Project に接続する（既定: 設定の project.number）
#   --title TITLE      Project の名前で探し、無ければその名前で作る（既定: リポジトリ名）
#   --write-config     .claude/workflow.json の project を書き換える（対象のリポジトリの中で実行すること）
#   --dry-run          変更せず、行う予定の操作だけを出力する
#
# 行うこと:
#   1. Project の特定（--number → 設定の project.number → 名前の完全一致）、無ければ作成
#   2. リポジトリとの紐付け
#   3. Status 列に設定の status の列名を揃える（既存の選択肢と値は残す）
#   4. Story Point（数値の項目）の追加
#   5. Project に入っていないオープンな Issue を追加し、Status が空なら todo の列にする
#   6. 組み込みの自動追加（Auto-add to project）が有効か確認する（API では有効にできない）
# GraphQL の変数（$login など）を bash に展開させないため、クエリはシングルクォートで書く
# shellcheck disable=SC2016
set -euo pipefail

# shellcheck source=../plugins/dev-workflow/scripts/lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../plugins/dev-workflow/scripts/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^# GraphQL の変数/{/^# GraphQL の変数/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

repo="" owner="" number="" title="" write_config=false dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo | --owner | --number | --title)
      need_value "$@"
      case "$1" in
        --repo) repo="$2" ;;
        --owner) owner="$2" ;;
        --number) number="$2" ;;
        --title) title="$2" ;;
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
# 設定に書かれた順のまま重複を除く
status_names="$(jq -c 'reduce (.status[] | select(. != null)) as $s ([]; if any(.[]; . == $s) then . else . + [$s] end)' <<<"$config")"
todo_name="$(jq -r '.status.todo // empty' <<<"$config")"
sp_name="$(jq -r '.story_point.field' <<<"$config")"

actions='[]'
# 行った（または dry-run で行う予定の）操作を記録する
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# 変更を伴う GraphQL。dry-run では呼ばずに null を返す
mutate() {
  if $dry_run; then
    echo null
  else
    dw_gql "$1" "$2"
  fi
}

msg_status() { printf 'Status 列に %s を追加する' "$(jq -r 'join(" / ")' <<<"$1")"; }
msg_sp="Story Point（数値）の項目「$sp_name」を追加する"

# --- リポジトリと所有者 ---------------------------------------------------------
repo_json="$(gh repo view ${repo:+"$repo"} --json id,name,nameWithOwner,owner)"
repo_id="$(jq -r .id <<<"$repo_json")"
repo_nwo="$(jq -r .nameWithOwner <<<"$repo_json")"

if $write_config && [ -n "$repo" ]; then
  here_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ "$here_nwo" = "$repo_nwo" ] \
    || dw_die "--write-config は対象のリポジトリ（$repo_nwo）の中で実行してください" 64
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

owner_json="$(dw_gql 'query Owner($login: String!) {
  repositoryOwner(login: $login) { __typename id }
}' "$(jq -nc --arg l "$owner" '{login: $l}')" | jq -c '.data.repositoryOwner')"
[ "$owner_json" != null ] || dw_die "所有者が見つかりません: $owner"
owner_id="$(jq -r .id <<<"$owner_json")"
case "$(jq -r .__typename <<<"$owner_json")" in
  Organization) owner_path="orgs/$owner" ;;
  *) owner_path="users/$owner" ;;
esac

# --- 1. Project を見つける・作る ------------------------------------------------
# 名前の完全一致で探す。検索は曖昧一致なので使わず、全件を順に見る
find_by_title() {
  local cursor="" page found
  while :; do
    page="$(dw_gql 'query Projects($login: String!, $after: String) {
      repositoryOwner(login: $login) { ... on ProjectV2Owner {
        projectsV2(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { id number title url closed } } } }
    }' "$(jq -nc --arg l "$owner" --arg a "$cursor" '{login: $l, after: (if $a == "" then null else $a end)}')" \
      | jq -c '.data.repositoryOwner.projectsV2')"
    found="$(jq -c --arg t "$title" '[.nodes[] | select(.title == $t and (.closed | not))][0] // null | if . then del(.closed) else . end' <<<"$page")"
    if [ "$found" != null ]; then
      printf '%s\n' "$found"
      return
    fi
    [ "$(jq -r .pageInfo.hasNextPage <<<"$page")" = true ] || break
    cursor="$(jq -r .pageInfo.endCursor <<<"$page")"
  done
  echo null
}

created=false
if [ -n "$number" ]; then
  project="$(dw_gql 'query ProjectByNumber($login: String!, $number: Int!) {
    repositoryOwner(login: $login) { ... on ProjectV2Owner { projectV2(number: $number) { id number title url } } }
  }' "$(jq -nc --arg l "$owner" --argjson n "$number" '{login: $l, number: $n}')" \
    | jq -c '.data.repositoryOwner.projectV2')"
  [ "$project" != null ] || dw_die "Project が見つかりません: $owner/$number"
else
  project="$(find_by_title)"
  if [ "$project" = null ]; then
    note "Project「$title」を作成し、リポジトリ $repo_nwo と紐付ける"
    created=true
    project="$(mutate 'mutation CreateProject($owner: ID!, $title: String!, $repo: ID!) {
      createProjectV2(input: {ownerId: $owner, title: $title, repositoryId: $repo}) { projectV2 { id number title url } }
    }' "$(jq -nc --arg o "$owner_id" --arg t "$title" --arg r "$repo_id" '{owner: $o, title: $t, repo: $r}')" \
      | jq -c '.data.createProjectV2.projectV2 // null')"
    if ! $dry_run && [ "$project" = null ]; then
      dw_die "Project を作成できませんでした（API の応答に projectV2 がありません）"
    fi
  fi
fi

project_id="$(jq -r '.id // empty' <<<"$project")"
project_number="$(jq -r '.number // empty' <<<"$project")"

# オープンな Issue と、それぞれがこの Project に入っているか（Issue 側から調べる）
open_issues() {
  local cursor="" page
  while :; do
    page="$(dw_gql 'query OpenIssues($owner: String!, $name: String!, $after: String) {
      repository(owner: $owner, name: $name) {
        issues(states: OPEN, first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes { id number projectItems(first: 50) { nodes { id project { id }
            fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } }
    }' "$(jq -nc --arg r "$repo_nwo" --arg a "$cursor" \
      '{owner: ($r | split("/")[0]), name: ($r | split("/")[1]), after: (if $a == "" then null else $a end)}')" \
      | jq -c '.data.repository.issues')"
    jq -c --arg p "$project_id" '.nodes[] | {id, number,
      item: ([.projectItems.nodes[] | select(.project.id == $p)][0] // null
        | if . then {id, status: (.fieldValueByName.name // null)} else null end)}' <<<"$page"
    [ "$(jq -r .pageInfo.hasNextPage <<<"$page")" = true ] || break
    cursor="$(jq -r .pageInfo.endCursor <<<"$page")"
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
  note "オープンな Issue $(gh issue list -R "$repo_nwo" --state open --limit 1000 --json number -q length) 件を追加し、「$todo_name」にする"
else
  workflows_url="https://github.com/$owner_path/projects/$project_number/workflows"

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

  # --- 2. リポジトリとの紐付け --------------------------------------------------
  if ! jq -e --arg r "$repo_id" 'any(.repositories.nodes[]; .id == $r)' <<<"$project_detail" >/dev/null; then
    note "リポジトリ $repo_nwo と紐付ける"
    mutate 'mutation LinkRepo($p: ID!, $r: ID!) {
      linkProjectV2ToRepository(input: {projectId: $p, repositoryId: $r}) { repository { id } }
    }' "$(jq -nc --arg p "$project_id" --arg r "$repo_id" '{p: $p, r: $r}')" >/dev/null
  fi

  # --- 3. Status 列 -------------------------------------------------------------
  status_field="$(jq -c '[.fields.nodes[] | select(.name == "Status")][0] // null' <<<"$project_detail")"
  [ "$status_field" != null ] || dw_die "Project に Status 列がありません"
  missing="$(jq -c --argjson want "$status_names" '[.options[].name] as $have | $want - $have' <<<"$status_field")"
  if [ "$missing" != "[]" ]; then
    note "$(msg_status "$missing")"
    # 既存の選択肢は id を付けて渡し、Issue に付いている値を残す
    mutate 'mutation UpdateStatus($f: ID!, $opts: [ProjectV2SingleSelectFieldOptionInput!]!) {
      updateProjectV2Field(input: {fieldId: $f, singleSelectOptions: $opts}) { projectV2Field { ... on ProjectV2FieldCommon { id } } }
    }' "$(jq -c --argjson m "$missing" '{f: .id, opts: (.options + ($m | map({name: ., color: "GRAY", description: ""})))}' <<<"$status_field")" >/dev/null
    if ! $dry_run; then
      project_detail="$(detail)"
      status_field="$(jq -c '[.fields.nodes[] | select(.name == "Status")][0]' <<<"$project_detail")"
    fi
  fi

  # --- 4. Story Point -----------------------------------------------------------
  sp_type="$(jq -r --arg n "$sp_name" '[.fields.nodes[] | select(.name == $n)][0].dataType // empty' <<<"$project_detail")"
  if [ -z "$sp_type" ]; then
    note "$msg_sp"
    mutate 'mutation CreateNumberField($p: ID!, $n: String!) {
      createProjectV2Field(input: {projectId: $p, dataType: NUMBER, name: $n}) { projectV2Field { ... on ProjectV2FieldCommon { id } } }
    }' "$(jq -nc --arg p "$project_id" --arg n "$sp_name" '{p: $p, n: $n}')" >/dev/null
  elif [ "$sp_type" != NUMBER ]; then
    dw_warn "項目「$sp_name」が数値ではありません（$sp_type）。合計を表示できないので数値の項目にしてください"
  fi

  # --- 5. 入っていない Issue だけ追加し、Status が空なら todo にする --------------
  status_field_id="$(jq -r .id <<<"$status_field")"
  todo_id="$(jq -r --arg n "$todo_name" '[.options[] | select(.name == $n)][0].id // empty' <<<"$status_field")"
  if [ -z "$todo_id" ]; then
    dw_warn "todo の列「${todo_name:-（未設定）}」が Status 列に無いので、Issue の Status は設定しません"
  fi

  # $(...) を直接ループに渡すと API の失敗で止まらないので、先に変数に受ける
  issues="$(open_issues)"
  while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    item_id="$(jq -r '.item.id // empty' <<<"$issue")"
    if [ -z "$item_id" ]; then
      items_added=$((items_added + 1))
      if ! $dry_run; then
        item_id="$(dw_gql 'mutation AddItem($p: ID!, $c: ID!) {
          addProjectV2ItemById(input: {projectId: $p, contentId: $c}) { item { id } }
        }' "$(jq -nc --arg p "$project_id" --argjson i "$issue" '{p: $p, c: $i.id}')" \
          | jq -r '.data.addProjectV2ItemById.item.id')"
      fi
    fi
    if [ "$(jq -r '.item.status // empty' <<<"$issue")" = "" ] && [ -n "$todo_id" ]; then
      items_todo=$((items_todo + 1))
      if ! $dry_run; then
        dw_gql 'mutation SetStatus($p: ID!, $i: ID!, $f: ID!, $o: String!) {
          updateProjectV2ItemFieldValue(input: {projectId: $p, itemId: $i, fieldId: $f, value: {singleSelectOptionId: $o}}) { projectV2Item { id } }
        }' "$(jq -nc --arg p "$project_id" --arg i "$item_id" --arg f "$status_field_id" --arg o "$todo_id" \
          '{p: $p, i: $i, f: $f, o: $o}')" >/dev/null
      fi
    fi
  done <<<"$issues"
  [ "$items_added" -eq 0 ] || note "オープンな Issue $items_added 件を Project に追加する"
  [ "$items_todo" -eq 0 ] || note "Status が空の Issue $items_todo 件を「$todo_name」にする"

  # --- 6. 組み込みの自動化の確認 ------------------------------------------------
  auto_add="$(jq 'any(.workflows.nodes[]; .name == "Auto-add to project" and .enabled)' <<<"$project_detail")"
  item_closed="$(jq 'any(.workflows.nodes[]; .name == "Item closed" and .enabled)' <<<"$project_detail")"
  if [ "$auto_add" != true ]; then
    dw_warn "自動追加（Auto-add to project）が無効です。API では有効にできないので、次の画面で有効にしてください:"
    dw_warn "  $workflows_url"
    dw_warn "  「Auto-add to project」→ リポジトリに $repo_nwo、フィルターに is:issue を指定 → Save and turn on workflow"
  fi
  if [ "$item_closed" != true ]; then
    dw_warn "「Item closed」（Issue が閉じたら Done に移す）が無効です。同じ画面で有効にしてください"
  fi
fi

# --- 設定ファイルへの書き込み ---------------------------------------------------
if $write_config; then
  repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください"
  config_file="$repo_root/.claude/workflow.json"
  note "$config_file の project を $owner/${project_number:-（作成後の番号）} にする"
  if ! $dry_run; then
    mkdir -p "$repo_root/.claude"
    current='{}'
    if [ -f "$config_file" ]; then
      dw_check_json "$config_file"
      current="$(cat "$config_file")"
    fi
    jq --arg o "$owner" --argjson n "$project_number" '.project = {owner: $o, number: $n}' <<<"$current" >"$config_file.tmp"
    mv "$config_file.tmp" "$config_file"
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
