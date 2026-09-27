#!/usr/bin/env bash
# Issue を起票し、type ラベルを付け、Project に追加して todo の列にする。Story Point と依存する Issue も設定できる。
#
# 使い方: issue-create.sh --title TITLE --type TYPE [オプション]
#   --title TITLE        Issue のタイトル（必須）
#   --type TYPE          type ラベル。設定の labels.types のどれか（必須）
#   --body-file PATH     本文のファイル。- なら標準入力（既定: 本文なし）
#   --story-point N      Story Point。1, 2, 3, 5, 8, 13, 21, 34 のどれか（既定: 空欄）。
#                        21 と 34 は設定できるが、分割を勧める警告を出す
#   --blocked-by N       依存する（先に終わらせる）同じリポジトリの Issue の番号。複数回指定できる
#
# 行うこと:
#   1. 設定と Project（project.owner / project.number）、Status 列・todo の列・Story Point の項目、
#      依存する Issue があるかを確かめる（問題があれば Issue を作る前に止める）
#   2. Issue を作る（type ラベル付き）
#   3. Project に追加し（既に入っていれば既存の項目を使う）、Status を todo の列に、Story Point を設定する
#   4. 依存する Issue を、GitHub の依存関係（blocked by）に登録する
# project.number が未設定なら、Issue だけ作って警告する。
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

title="" type="" body_file="" sp=""
# 依存する Issue の番号（空白区切り。重複は除く）
blocked_by=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title | --type | --body-file | --story-point)
      need_value "$@"
      case "$1" in
        --title) title="$2" ;;
        --type) type="$2" ;;
        --body-file) body_file="$2" ;;
        --story-point) sp="$2" ;;
      esac
      shift 2
      ;;
    --blocked-by)
      need_value "$@"
      # 本文に書くときと同じ #12 の形も受け付ける
      n="${2#\#}"
      case "$n" in
        '' | *[!0-9]*) dw_die "--blocked-by には Issue の番号を指定してください: $2" 64 ;;
      esac
      n="$((10#$n))"
      [ "$n" -gt 0 ] || dw_die "--blocked-by には Issue の番号を指定してください: $2" 64
      case " $blocked_by " in
        *" $n "*) ;;
        *) blocked_by="${blocked_by:+$blocked_by }$n" ;;
      esac
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$title" ] || dw_die "--title は必須です" 64
[ -n "$type" ] || dw_die "--type は必須です" 64

body=""
if [ -n "$body_file" ]; then
  if [ "$body_file" = - ]; then
    body="$(cat)"
  else
    [ -f "$body_file" ] || dw_die "本文のファイルがありません: $body_file" 64
    body="$(cat "$body_file")"
  fi
fi

# --- 1. 設定の確認 --------------------------------------------------------------
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
jq -e --arg t "$type" '.labels.types | index($t)' <<<"$config" >/dev/null \
  || dw_die "type は labels.types のどれかにしてください（$(jq -r '.labels.types | join(" / ")' <<<"$config")）: $type" 64
if [ -n "$sp" ]; then
  # 05 のような先頭の 0 は JSON の数値に揃える
  case "$sp" in
    *[!0-9]*) dw_die "--story-point には整数を指定してください: $sp" 64 ;;
  esac
  sp="$((10#$sp))"
  jq -e --argjson n "$sp" 'index($n)' <<<"$DW_STORY_POINTS" >/dev/null \
    || dw_die "Story Point は $(jq -r 'map(tostring) | join(" / ")' <<<"$DW_STORY_POINTS") のどれかにしてください: $sp" 64
  if [ "$sp" -ge "$DW_STORY_POINT_SPLIT" ]; then
    dw_warn "Story Point ${sp} は大きいので、Issue を分割できないか検討してください"
  fi
fi

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
owner="$(jq -r '.project.owner // empty' <<<"$config")"
number="$(jq -r '.project.number // empty' <<<"$config")"
[ -n "$owner" ] || owner="${repo_nwo%%/*}"
todo_name="$(jq -r '.status.todo // empty' <<<"$config")"
sp_name="$(jq -r '.story_point.field' <<<"$config")"

project=null
if [ -n "$number" ]; then
  project="$(dw_project_fields "$owner" "$number")"
  status_field="$(jq -c '[.fields.nodes[] | select(.name == "Status")][0] // null' <<<"$project")"
  [ "$status_field" != null ] || dw_die "Project に Status 列がありません"
  todo_id="$(jq -r --arg n "$todo_name" '[.options[] | select(.name == $n)][0].id // empty' <<<"$status_field")"
  [ -n "$todo_id" ] || dw_die "todo の列「${todo_name:-（未設定）}」が Status 列にありません"
  sp_field_id=""
  if [ -n "$sp" ]; then
    sp_field="$(jq -c --arg n "$sp_name" '[.fields.nodes[] | select(.name == $n)][0] // null' <<<"$project")"
    [ "$sp_field" != null ] || dw_die "Project に Story Point の項目「${sp_name}」がありません（setup-project.sh で追加してください）"
    [ "$(jq -r .dataType <<<"$sp_field")" = NUMBER ] || dw_die "項目「${sp_name}」が数値ではありません"
    sp_field_id="$(jq -r .id <<<"$sp_field")"
  fi
else
  dw_warn "project.number が未設定なので、Project には追加しません（setup-project.sh --write-config で設定できます）"
fi

# 依存する Issue の「番号:node id」（空白区切り）
blocking=""
for n in $blocked_by; do
  # shellcheck disable=SC2016
  id="$(dw_gql_find 'query BlockingIssue($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) { issue(number: $number) { id number } }
  }' "$(jq -nc --arg o "${repo_nwo%%/*}" --arg r "${repo_nwo#*/}" --argjson n "$n" '{owner: $o, name: $r, number: $n}')" \
    | jq -r '.data.repository.issue.id // empty')"
  [ -n "$id" ] || dw_die "依存する Issue #${n} がありません（${repo_nwo}）"
  blocking="${blocking:+$blocking }$n:$id"
done

# --- 2. Issue を作る ------------------------------------------------------------
issue="$(jq -n --arg t "$title" --arg b "$body" --arg l "$type" '{title: $t, body: $b, labels: [$l]}' \
  | gh api -X POST "repos/$repo_nwo/issues" --input -)" || dw_die "Issue を作れませんでした"
issue_number="$(jq -r .number <<<"$issue")"
issue_url="$(jq -r .html_url <<<"$issue")"

# ここから先で失敗しても Issue は残るので、番号を伝えて止める
fail_after_create() { dw_die "Issue #${issue_number}（${issue_url}）は作りましたが、$1"; }

# 書き込み権限が無いと、GitHub はラベルを黙って無視するので、付いたかを応答で確かめる
jq -e --arg t "$type" 'any(.labels[]?; .name == $t)' <<<"$issue" >/dev/null \
  || fail_after_create "type ラベル「${type}」を付けられませんでした（リポジトリへの書き込み権限が必要です）"

# --- 3. Project に追加し、Status と Story Point を設定する ------------------------
item_id=""
if [ "$project" != null ]; then
  project_id="$(jq -r .id <<<"$project")"
  # 自動追加が有効でも、既に入っていれば既存の項目が返るだけなので重複しない
  item_id="$(dw_project_add_item "$project_id" "$(jq -r .node_id <<<"$issue")")" \
    || fail_after_create "Project に追加できませんでした"

  set_field() { dw_project_set_field "$project_id" "$item_id" "$@"; }
  set_field "$(jq -r .id <<<"$status_field")" "$(jq -nc --arg o "$todo_id" '{singleSelectOptionId: $o}')" \
    || fail_after_create "Status を「${todo_name}」にできませんでした"
  if [ -n "$sp" ]; then
    set_field "$sp_field_id" "$(jq -nc --argjson n "$sp" '{number: $n}')" \
      || fail_after_create "Story Point を設定できませんでした"
  fi
fi

# --- 4. 依存関係（blocked by）を登録する -----------------------------------------
issue_id="$(jq -r .node_id <<<"$issue")"
for pair in $blocking; do
  # shellcheck disable=SC2016
  dw_gql 'mutation AddBlockedBy($i: ID!, $b: ID!) {
    addBlockedBy(input: {issueId: $i, blockingIssueId: $b}) { issue { id } }
  }' "$(jq -nc --arg i "$issue_id" --arg b "${pair#*:}" '{i: $i, b: $b}')" >/dev/null \
    || fail_after_create "#${pair%%:*} への依存（blocked by）を登録できませんでした"
done

jq -n --argjson n "$issue_number" --arg url "$issue_url" --arg type "$type" --arg item "$item_id" \
  --argjson project "$project" --arg status "$todo_name" --arg sp "$sp" \
  --arg blocked "$blocked_by" '{
    number: $n,
    url: $url,
    type: $type,
    blocked_by: ($blocked | split(" ") | map(select(. != "") | tonumber)),
    project: (if $project then {number: $project.number, item_id: $item, status: $status,
      story_point: (if $sp == "" then null else ($sp | tonumber) end)} else null end)
  }'
