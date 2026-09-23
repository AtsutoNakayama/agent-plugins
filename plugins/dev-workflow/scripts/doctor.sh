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
    check project false warn "Project が未設定です（.claude/workflow.json の project）"
  fi
else
  check config false error "$config"
fi

result="$(printf '%s' "$checks" | jq -s '{ok: (map(select(.level == "error" and (.ok | not))) | length == 0), checks: .}')"
printf '%s\n' "$result"
[ "$(jq -r .ok <<<"$result")" = true ]
