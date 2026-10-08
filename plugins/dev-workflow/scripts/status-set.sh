#!/usr/bin/env bash
# Issue の Project の Status を移す。移す先は役割（todo / hold / start / pr_opened / done）か列名で指定する。
#
# 使い方: status-set.sh --issue N --to ROLE|COLUMN [--item-id ID] [--only-from ROLE|COLUMN] [--no-parents] [--dry-run]
#   --issue N      Issue の番号（#N でもよい）
#   --to ROLE      役割なら設定の status.<役割> の列、それ以外は列名として扱う
#   --item-id ID   この Project での Issue の項目の id（node id）。呼ぶ側が既に知っているとき（issue-create.sh）に渡す。
#                  項目と今の列を読まない（GraphQL を省く）ので、from は null になり、今の列にかかわらず設定する
#   --only-from X  今の列が X（役割か列名）のときだけ移す。違えば（Project に入っていない場合も）何も変えずに skipped: true を出力する。
#                  --item-id とは一緒に指定できない（今の列を読まないため）
#   --no-parents   親の Issue の列を移さない（既定では、start の列に移したとき、親も移す。下記）
#   --dry-run      変更せず、行う予定の操作だけを出力する
#
# Issue が Project に入っていなければ追加してから移す。既にその列なら何もしない（--item-id のときは確かめない）。
# start の列に移したときは、その Issue の親（とさらに上の親）のうち、開いていて todo の列にあるものも start の列に移す
# （親は作業の単位ではなく、子の進み具合に合わせて動かす。設計書 §4）。todo より先の列にある親・閉じた親・別のリポジトリの親・
# Project に入っていない親は動かさない。親を移せなくても、この Issue の移動は止めずに警告する（標準エラーと、出力の warnings の両方）。結果は parents に出し、actions にも足す。
# pr_opened の列に移したときは、親は動かさない（PR は子の作業に対して出すもので、親の作業は無い）。
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

issue="" to="" item_id="" only_from="" no_parents=false dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --to | --item-id | --only-from)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --to) to="$2" ;;
        --item-id) item_id="$2" ;;
        --only-from) only_from="$2" ;;
      esac
      shift 2
      ;;
    --no-parents) no_parents=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
[ -n "$to" ] || dw_die "--to は必須です" 64
# スキルの引数の #12 も受ける（dw_issue_number）
issue="$(dw_issue_number --issue "$issue")"
[ -z "$only_from" ] || [ -z "$item_id" ] || dw_die "--only-from と --item-id は一緒に指定できません" 64

config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"

# 役割なら設定の列名に置き換える。列が null の役割は、その場面では列を移さないという意味
# 使い方: column_of <役割か列名> → 列名（役割で、列が設定されていなければ空）
column_of() {
  case "$1" in
    todo | hold | start | pr_opened | done) jq -r --arg r "$1" '.status[$r] // empty' <<<"$config" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
column="$(column_of "$to")"
if [ -z "$column" ]; then
  jq -n --argjson i "$issue" --arg r "$to" '{issue: $i, skipped: true, reason: "status.\($r) が設定されていないので、列を移しません"}'
  exit 0
fi
only_column=""
if [ -n "$only_from" ]; then
  only_column="$(column_of "$only_from")"
  if [ -z "$only_column" ]; then
    jq -n --argjson i "$issue" --arg r "$only_from" '{issue: $i, skipped: true, reason: "status.\($r) が設定されていないので、列を移しません"}'
    exit 0
  fi
fi

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

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

from="" changed=true
if [ -z "$item_id" ]; then
  # Issue と、この Project での項目・今の列（dw_issue_items）
  found="$(dw_issue_items "$repo_nwo" "$issue")"
  [ "$found" != null ] || dw_die "Issue #${issue} が ${repo_nwo} にありません" 2
  item="$(jq -c --arg p "$project_id" '[.projectItems.nodes[] | select(.project.id == $p)][0] // null' <<<"$found")"
  from="$(jq -r '.fieldValueByName.name // empty' <<<"$item" 2>/dev/null || true)"
  if [ -n "$only_column" ] && [ "$from" != "$only_column" ]; then
    jq -n --argjson i "$issue" --arg f "$from" --arg o "$only_column" \
      '{issue: $i, skipped: true, reason: "今の列が「\($o)」ではない（「\($f)」）ので、列を移しません"}'
    exit 0
  fi

  item_id="$(jq -r '.id // empty' <<<"$item")"
  if [ -z "$item_id" ]; then
    note "Issue #${issue} を Project に追加する"
    if ! $dry_run; then
      item_id="$(dw_project_add_item "$owner" "$number" "$(jq -r .url <<<"$found")")" \
        || dw_die "Issue #${issue} を Project に追加できませんでした"
    fi
  fi
  [ "$from" != "$column" ] || changed=false
  from_label="「${from:-（なし）}」から"
else
  # 今の列は読んでいないので、どこから移すかは書かない
  from_label=""
fi
if $changed; then
  note "Issue #${issue} を${from_label}「${column}」に移す"
  if ! $dry_run; then
    dw_project_set_field "$project_id" "$item_id" "$(jq -r .id <<<"$status_field")" \
      --single-select-option-id "$option_id" \
      || dw_die "Issue #${issue} の Status を「${column}」にできませんでした"
  fi
fi

# --- 親の Issue ----------------------------------------------------------------------
# start の列に移したときだけ、親（とさらに上の親）のうち todo の列にあるものを start の列に移す。
# 親の列を移せなくても、この Issue の移動は済んでいるので止めずに警告する
parents='[]' warnings='[]'
warn() { dw_warn "$1"; warnings="$(jq -c --arg w "$1" '. + [$w]' <<<"$warnings")"; }
# 親を動かすのは、start の役割の列に移したときだけ。pr_opened の列が start と同じ列でも、pr_opened への移動では動かさない。
# --to が役割の名前ならその役割で、列名なら、その列が pr_opened の列かどうかで決める（列名で渡しても pr_opened の列なら動かさない）
move_parents=false
case "$to" in
  start) move_parents=true ;;
  todo | hold | pr_opened | done) ;;
  *)
    pr_opened_column="$(jq -r '.status.pr_opened // empty' <<<"$config")"
    [ -n "$pr_opened_column" ] && [ "$column" = "$pr_opened_column" ] || move_parents=true
    ;;
esac
if ! $no_parents && $move_parents && [ "$column" = "$(jq -r '.status.start // empty' <<<"$config")" ]; then
  if chain="$(dw_issue_parents "$repo_nwo" "$issue" 2>/dev/null)"; then
    for p in $(jq -r '.[] | select(.state == "open") | .number' <<<"$chain"); do
      args=(--issue "$p" --to start --only-from todo --no-parents)
      $dry_run && args+=(--dry-run)
      if res="$("$BASH" "$DW_SCRIPTS_DIR/status-set.sh" "${args[@]}")"; then
        [ "$(jq -r '.changed // false' <<<"$res")" = true ] || continue
        parents="$(jq -c --argjson r "$res" '. + [$r | {issue, from, to, changed, dry_run}]' <<<"$parents")"
        while IFS= read -r a; do
          [ -n "$a" ] && note "親の ${a}"
        done <<<"$(jq -r '.actions[]?' <<<"$res")"
      else
        warn "親の Issue #${p} の列を start に移せませんでした（Issue #${issue} の移動は済んでいます）"
      fi
    done
  else
    warn "Issue #${issue} の親を読めなかったので、親の列は移しません"
  fi
fi

jq -n --argjson i "$issue" --arg item "$item_id" --arg from "$from" --arg to "$column" \
  --argjson changed "$changed" --argjson dry "$dry_run" --argjson actions "$actions" --argjson parents "$parents" --argjson warnings "$warnings" '{
    issue: $i,
    dry_run: $dry,
    item_id: (if $item == "" then null else $item end),
    from: (if $from == "" then null else $from end),
    to: $to,
    changed: $changed,
    parents: $parents,
    warnings: $warnings,
    actions: $actions
  }'
