#!/usr/bin/env bash
# 実行環境と設定を確認し、結果を JSON で出力する。
# level が error の確認に1つでも失敗したら終了コード 1。
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

if ! command -v jq >/dev/null 2>&1; then
  printf '{"ok":false,"checks":[{"name":"jq","ok":false,"level":"error","detail":"jq が見つかりません"}]}\n'
  exit 1
fi

checks=""

# 使い方: check <名前> <true|false> <error|warn> <詳細>
check() {
  checks="$checks$(jq -nc --arg n "$1" --argjson ok "$2" --arg l "$3" --arg d "$4" \
    '{name: $n, ok: $ok, level: $l, detail: $d}')
"
}

has() { command -v "$1" >/dev/null 2>&1; }

# bash 3.2 以上
if [ "${BASH_VERSINFO[0]}" -gt 3 ] || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  check bash true error "$BASH_VERSION"
else
  check bash false error "bash 3.2 以上が必要です（現在 ${BASH_VERSION}）"
fi

check jq true error "$(jq --version)"

if has git; then check git true error "$(git --version)"; else check git false error "git が見つかりません"; fi

if has gh; then
  check gh true error "$(gh --version | head -n 1)"
  # 古いと使えない機能があるだけなので、止めずに更新を促す
  gh_version="$(dw_gh_version)"
  if [ -n "$gh_version" ] && dw_version_ge "$gh_version" "$DW_GH_MIN_VERSION"; then
    check gh-version true warn "$gh_version"
  else
    check gh-version false warn "gh ${DW_GH_MIN_VERSION} 以上を使ってください（今は ${gh_version:-不明}）。gh を更新してください（https://cli.github.com/）"
  fi
  if gh auth status -h github.com >/dev/null 2>&1; then
    check gh-auth true error "github.com にログイン済み"
    scopes="$(gh api -i user 2>/dev/null | tr -d '\r' | LC_ALL=C sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p')"
    if [ -z "$scopes" ]; then
      check gh-project-scope false warn "トークンのスコープを確認できません（fine-grained token など）"
    elif printf '%s\n' "$scopes" | tr ',' '\n' | sed 's/^ *//' | grep -qx project; then
      check gh-project-scope true error "$scopes"
    else
      check gh-project-scope false error "project スコープがありません。ターミナルで gh auth refresh -h github.com -s project を実行してください"
    fi
  else
    check gh-auth false error "ターミナルで gh auth login を実行してください"
  fi
else
  check gh false error "gh が見つかりません（https://cli.github.com/）"
fi

if config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" 2>&1)"; then
  check config true error "$(jq -r '.sources | join(", ")' <<<"$config")"
  if [ "$(jq -r '.project.number // empty' <<<"$config")" != "" ]; then
    check project true warn "$(jq -r '"\(.project.owner)/\(.project.number)"' <<<"$config")"
  else
    check project false warn "Project が未設定です（.claude/dev-workflow/config.json の project）"
  fi
else
  check config false error "$config"
fi

# 古い置き場所（.claude/dev-workflow/ にまとめる前）のファイルは使われないので、移すよう促す
moves=""
# 使い方: old_location <古いパス> <新しいパス>。古いパスがディレクトリなら、*.md があるときだけ数える
old_location() {
  if [ -d "$1" ]; then
    ls "$1"/*.md >/dev/null 2>&1 || return 0
  elif [ ! -f "$1" ]; then
    return 0
  fi
  moves="$moves${moves:+、}$1 → $2"
}
repo_root="$(dw_repo_root || true)"
if [ -n "$repo_root" ]; then
  old_location "$repo_root/.claude/workflow.json" "$repo_root/.claude/dev-workflow/config.json"
  old_location "$repo_root/.claude/workflow" "$repo_root/.claude/dev-workflow/"
  old_location "$repo_root/.claude/review" "$repo_root/.claude/dev-workflow/review/"
  old_location "$repo_root/.claude/labels.json" "$repo_root/.claude/dev-workflow/labels.json"
  # 個人の設定はメインのワークツリーに置く
  main_root="$(dw_main_root "$repo_root" || true)"
  old_location "${main_root:-$repo_root}/.claude/workflow.local.json" "${main_root:-$repo_root}/.claude/dev-workflow/config.local.json"
fi
user_parent="$(dirname "$(dw_user_dir)")"
old_location "$user_parent/workflow/workflow.json" "$(dw_user_dir)/config.json"
old_location "$user_parent/workflow" "$(dw_user_dir)/"
old_location "$user_parent/review" "$(dw_user_review_dir)/"
if [ -n "$moves" ]; then
  check old-locations false warn "古い置き場所のファイルは使われません。移してください: ${moves}"
else
  check old-locations true warn "古い置き場所のファイルはありません"
fi

result="$(printf '%s' "$checks" | jq -s '{ok: (map(select(.level == "error" and (.ok | not))) | length == 0), checks: .}')"
printf '%s\n' "$result"
[ "$(jq -r .ok <<<"$result")" = true ]
