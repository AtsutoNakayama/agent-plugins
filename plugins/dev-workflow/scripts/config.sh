#!/usr/bin/env bash
# 5つの層の設定を項目ごとに合わせて JSON で出力する。
#
# 使い方: config.sh [jq フィルター]
#   例: config.sh .status.start   → In Progress
#
# 層（下ほど優先。上位の層が決めていない項目には下位の値が効く）:
#   5. プラグインの既定             defaults/workflow.json
#   4. ユーザーの好み               ~/.claude/workflow/workflow.json
#   3. 既にある規約                 PR テンプレートなどを自動で検出
#   2. チームの規約                 <repo>/.claude/workflow.json
#   1. 個人がそのリポジトリで上書き  <repo>/.claude/workflow.local.json
#
# 文章のガイド（*.md）は guides.<名前> にパスの配列として入る（優先度の低い順）。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
dw_require jq

filter="${1:-.}"
repo_root="$(dw_repo_root || true)"
user_dir="$(dw_user_dir)"

layers=()
sources=()

add_layer() {
  [ -f "$1" ] || return 0
  dw_check_json "$1"
  layers+=("$(cat "$1")")
  sources+=("$1")
}

first_existing() {
  local f
  for f in "$@"; do
    if [ -e "$repo_root/$f" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# 層3: リポジトリに既にある規約を見つける
detect_existing() {
  local pr_tpl pr_tpls commitlint contributing issue_tpl
  # 候補は空白区切りの一覧なので、わざと分割して渡す
  # shellcheck disable=SC2086
  pr_tpl="$(dw_find_nocase "$repo_root" $DW_PR_TEMPLATE_FILES || true)"
  # shellcheck disable=SC2086
  pr_tpls="$(dw_find_nocase "$repo_root" $DW_PR_TEMPLATE_DIRS || true)"
  commitlint="$(first_existing commitlint.config.js commitlint.config.cjs commitlint.config.mjs \
    commitlint.config.ts .commitlintrc .commitlintrc.json .commitlintrc.yaml .commitlintrc.yml \
    .commitlintrc.js .commitlintrc.cjs || true)"
  contributing="$(first_existing CONTRIBUTING.md .github/CONTRIBUTING.md docs/CONTRIBUTING.md || true)"
  # Issue テンプレートのディレクトリか、古い形式の1ファイル
  # shellcheck disable=SC2086
  issue_tpl="$(dw_find_nocase "$repo_root" $DW_ISSUE_TEMPLATES || true)"
  jq -n --arg pr "$pr_tpl" --arg prs "$pr_tpls" --arg cl "$commitlint" --arg co "$contributing" --arg it "$issue_tpl" '
    def opt: if . == "" then null else . end;
    (if $pr != "" then {pr: {template: $pr}} else {} end)
    + {detected: {commitlint: ($cl | opt), contributing: ($co | opt), pr_templates: ($prs | opt),
        issue_templates: ($it | opt)}}'
}

add_layer "$DW_PLUGIN_ROOT/defaults/workflow.json"
add_layer "$user_dir/workflow.json"
if [ -n "$repo_root" ]; then
  layers+=("$(detect_existing)")
  add_layer "$repo_root/.claude/workflow.json"
  local_file="$repo_root/.claude/workflow.local.json"
  if [ ! -f "$local_file" ]; then
    # ワークツリーで作業中なら、メインのワークツリーに置いた個人の設定を使う
    main_root="$(dw_main_root "$repo_root" || true)"
    [ -n "$main_root" ] && local_file="$main_root/.claude/workflow.local.json"
  fi
  add_layer "$local_file"
fi

# 文章のガイド（優先度の低い順: ユーザー → リポジトリ）
guides='{}'
for dir in "$user_dir" "${repo_root:+$repo_root/.claude/workflow}"; do
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    continue
  fi
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    guides="$(jq -c --arg k "$(basename "$f" .md)" --arg p "$f" '.[$k] += [$p]' <<<"$guides")"
  done
done

sources_json="$(printf '%s\n' ${sources[@]+"${sources[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')"

printf '%s\n' "${layers[@]}" \
  | jq -s --argjson guides "$guides" --argjson sources "$sources_json" \
      'reduce .[] as $l ({}; . * $l) + {guides: $guides, sources: $sources}' \
  | jq -r "$filter"
