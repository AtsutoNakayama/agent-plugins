#!/usr/bin/env bash
# Issue の親（とさらに上の親）の状態を調べて、JSON で出力する。何も変えない。
# 子がすべて閉じた親を閉じるかの確認（task-finish・task-cancel）の材料にする。確認と文章は呼ぶ側（スキル）が担当する。
#
# 使い方: parent-state.sh --issue N [--assume-closed M]...
#   --issue N          Issue の番号（#N でもよい）。この Issue の親を、近い順にたどる
#   --assume-closed M  Issue M を、閉じたものとして数える（複数指定できる）。PR のマージで GitHub が閉じる Issue は、
#                      マージの直後は少し遅れて閉じるので、task-finish が片付けている Issue を渡す
#
# 出力: {issue, parents: [近い順の親]}。親の要素は
#   number, title, state（open か closed）, state_reason, column（Project の Status の列。Project が未設定・項目が無ければ null）,
#   children: {total, closed, open, list: [{number, title, state, state_reason}]},
#   all_closed: 子が1つ以上あり、すべて閉じている,
#   suggest: 親が開いていて all_closed のとき、閉じ方の案（completed か not_planned）。それ以外は null
#             子がすべて取りやめ（not_planned・duplicate）なら not_planned、それ以外は completed
# 別のリポジトリの親は含めない（そこで打ち切る。設計書 §4）。親が無ければ parents は [] 。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

issue="" assumed='[]'
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --assume-closed)
      if [ $# -lt 2 ] || [ -z "$2" ]; then dw_die "$1 に値がありません" 64; fi
      n="$(dw_issue_number "$1" "$2")"
      if [ "$1" = --issue ]; then issue="$n"; else assumed="$(jq -c --argjson n "$n" '. + [$n]' <<<"$assumed")"; fi
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
project_id=""
number="$(jq -r '.project.number // empty' <<<"$config")"
if [ -n "$number" ]; then
  owner="$(jq -r '.project.owner // empty' <<<"$config")"
  [ -n "$owner" ] || owner="${repo_nwo%%/*}"
  project_id="$(dw_gh_find gh project view "$number" --owner "$owner" --format json | jq -r '.id // empty')"
  [ -n "$project_id" ] || dw_die "Project が見つかりません: ${owner}/${number}（setup-project.sh で設定してください）"
fi

chain="$(dw_issue_parents "$repo_nwo" "$issue")"
out='[]'
for p in $(jq -r '.[].number' <<<"$chain"); do
  parent="$(jq -c --argjson p "$p" '.[] | select(.number == $p)' <<<"$chain")"
  children="$(gh api --paginate "repos/$repo_nwo/issues/$p/sub_issues?per_page=100" | jq -sc 'add // []')" \
    || dw_die "#${p} のサブ Issue を読めませんでした"
  column=""
  if [ -n "$project_id" ]; then
    items="$(dw_issue_items "$repo_nwo" "$p")"
    column="$(jq -r --arg p "$project_id" '[.projectItems.nodes[]? | select(.project.id == $p)][0].fieldValueByName.name // empty' <<<"$items")"
  fi
  out="$(jq -c --argjson parent "$parent" --argjson kids "$children" --argjson assumed "$assumed" --arg column "$column" '
    ($kids | map(. as $k | {number, title,
      state: (if ($assumed | index($k.number)) != null then "closed" else $k.state end),
      state_reason: (if ($assumed | index($k.number)) != null and $k.state != "closed" then "completed" else ($k.state_reason // null) end)})) as $list
    | ($list | map(select(.state == "closed")) | length) as $closed
    | ($list | length > 0 and $closed == ($list | length)) as $all
    | . + [$parent + {
        column: (if $column == "" then null else $column end),
        children: {total: ($list | length), closed: $closed, open: (($list | length) - $closed), list: $list},
        all_closed: $all,
        suggest: (if $parent.state == "open" and $all
          then (if ($list | all(.state_reason == "not_planned" or .state_reason == "duplicate")) then "not_planned" else "completed" end)
          else null end)}]' <<<"$out")"
done

jq -n --argjson i "$issue" --argjson parents "$out" '{issue: $i, parents: $parents}'
