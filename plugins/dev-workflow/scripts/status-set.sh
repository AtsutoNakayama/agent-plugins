#!/usr/bin/env bash
# Issue の Project の Status を移す。移す先は役割（todo / start / pr_opened / done）か列名で指定する。
#
# 使い方: status-set.sh --issue N --to ROLE|COLUMN [--dry-run]
#   --issue N      Issue の番号
#   --to ROLE      役割なら設定の status.<役割> の列、それ以外は列名として扱う
#   --dry-run      変更せず、行う予定の操作だけを出力する
#
# Issue が Project に入っていなければ追加してから移す。既にその列なら何もしない。
# 役割の列が設定で null（例: 既定の pr_opened）なら、何もせずに skipped: true を出力する。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

issue="" to="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --to)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --to) to="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
[ -n "$to" ] || dw_die "--to は必須です" 64
case "$issue" in
  *[!0-9]*) dw_die "--issue には数字を指定してください: $issue" 64 ;;
esac

config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"

# 役割なら設定の列名に置き換える。列が null の役割は、その場面では列を移さないという意味
column="$to"
case "$to" in
  todo | start | pr_opened | done)
    column="$(jq -r --arg r "$to" '.status[$r] // empty' <<<"$config")"
    if [ -z "$column" ]; then
      jq -n --argjson i "$issue" --arg r "$to" '{issue: $i, skipped: true, reason: "status.\($r) が設定されていないので、列を移しません"}'
      exit 0
    fi
    ;;
esac

owner="$(jq -r '.project.owner // empty' <<<"$config")"
number="$(jq -r '.project.number // empty' <<<"$config")"
[ -n "$number" ] || dw_die "project.number が未設定です（setup-project.sh --write-config で設定できます）" 2
repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
[ -n "$owner" ] || owner="${repo_nwo%%/*}"

project="$(dw_project_fields "$owner" "$number")"
project_id="$(jq -r .id <<<"$project")"
status_field="$(jq -c '[.fields[] | select(.name == "Status")][0] // null' <<<"$project")"
[ "$status_field" != null ] || dw_die "Project に Status 列がありません"
option_id="$(jq -r --arg n "$column" '[.options[] | select(.name == $n)][0].id // empty' <<<"$status_field")"
[ -n "$option_id" ] \
  || dw_die "Status 列に「${column}」がありません（$(jq -r '[.options[].name] | join(" / ")' <<<"$status_field")）" 2

# Issue と、この Project での項目・今の列。gh にも REST にも、Issue から Project の項目を引く手段が無いので GraphQL で読む
# （gh issue view --json projectItems は Project の名前と列しか返さない。設計書 §10）
# GraphQL の変数（$owner など）を bash に展開させないため、クエリはシングルクォートで書く
# shellcheck disable=SC2016
found="$(dw_gh_find dw_gql 'query IssueItem($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { issue(number: $number) { url
    projectItems(first: 50) { nodes { id project { id }
      fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } }
}' "$(jq -nc --arg r "$repo_nwo" --argjson n "$issue" '{owner: ($r | split("/")[0]), name: ($r | split("/")[1]), number: $n}')" \
  | jq -c '.data.repository.issue // null')"
[ "$found" != null ] || dw_die "Issue #${issue} が ${repo_nwo} にありません" 2
item="$(jq -c --arg p "$project_id" '[.projectItems.nodes[] | select(.project.id == $p)][0] // null' <<<"$found")"
from="$(jq -r '.fieldValueByName.name // empty' <<<"$item" 2>/dev/null || true)"

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

item_id="$(jq -r '.id // empty' <<<"$item")"
if [ -z "$item_id" ]; then
  note "Issue #${issue} を Project に追加する"
  if ! $dry_run; then
    item_id="$(dw_project_add_item "$owner" "$number" "$(jq -r .url <<<"$found")")" \
      || dw_die "Issue #${issue} を Project に追加できませんでした"
  fi
fi
changed=false
if [ "$from" != "$column" ]; then
  changed=true
  note "Issue #${issue} を「${from:-（なし）}」から「${column}」に移す"
  if ! $dry_run; then
    dw_project_set_field "$project_id" "$item_id" "$(jq -r .id <<<"$status_field")" \
      --single-select-option-id "$option_id" \
      || dw_die "Issue #${issue} の Status を「${column}」にできませんでした"
  fi
fi

jq -n --argjson i "$issue" --arg item "$item_id" --arg from "$from" --arg to "$column" \
  --argjson changed "$changed" --argjson dry "$dry_run" --argjson actions "$actions" '{
    issue: $i,
    dry_run: $dry,
    item_id: (if $item == "" then null else $item end),
    from: (if $from == "" then null else $from end),
    to: $to,
    changed: $changed,
    actions: $actions
  }'
