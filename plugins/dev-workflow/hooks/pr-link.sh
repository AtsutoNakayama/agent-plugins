#!/usr/bin/env bash
# Claude Code のフック（PostToolUse の Bash）。git の操作のあとに、関連する PR・Issue・CI のリンクを出す。
# リンクは、Claude が返答に書いたときにしか見えないので、操作のたびに使用者の画面へ出して、すぐ開けるようにする。
#
#   - git push（pr-create.sh を含む）            開いた PR の URL（無ければ PR を作る URL）、紐付く Issue、PR の CI（checks）
#   - git commit（commit.sh を含む）             紐付く Issue
#   - ブランチ・ワークツリーの作成
#     （git switch -c など、task-start.sh を含む）  紐付く Issue
#   - gh pr create・gh issue create
#     （pr-create.sh・issue-create.sh を含む）      作った PR・Issue（コマンドの出力から拾う）
#
# 決まり（設計書 §9）:
#   - 同じリンクも、連続で毎回出す（常に見えるようにするため）
#   - Issue の番号が分からないブランチ（main など）では、ブランチから導くリンクは出さない（作った PR・Issue は出す）
#   - gh が無い・失敗する・解析できないときは、何も出さずに通す。フックは作業を止めない（いつも終了コード 0）
#
# 出力は、使用者に見せる systemMessage と、Claude に渡す additionalContext（返答でも触れてもらう）の JSON。
# コマンドの文字列を簡易に判定するだけなので、sh -c や別名を通すと見逃し、引用符の中の文字にも反応する。
# 標準入力でフックの入力（JSON）を受け取る。
set -Eeuo pipefail
# どこで失敗しても、作業は止めない。エラーの表示も出さない
trap 'exit 0' ERR
exec 2>/dev/null

# 日本語をバイト列として扱う
export LC_ALL=C

command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=../scripts/lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../scripts/lib/common.sh"

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
# 関係のないコマンドは解析しない（Bash を使うたびに呼ばれるので速く抜ける）
case "$cmd" in
  *git* | *"gh "* | *commit.sh* | *task-start.sh* | *pr-create.sh* | *issue-create.sh*) ;;
  *) exit 0 ;;
esac

# コマンドの文字列が <正規表現> に当たるか
has() { printf '%s' "$cmd" | grep -Eq -- "$1"; }

# 区切り（; & |）を越えない範囲で、git の <サブコマンド> を探す
git_sub() { has "(^|[^[:alnum:]_./-])git([^;&|]* )?$1([^[:alnum:]_-]|\$)"; }

push=false commit=false create_branch=false created=false
{ git_sub push || has 'pr-create\.sh'; } && push=true
{ git_sub commit || has 'commit\.sh'; } && commit=true
{
  has "(^|[^[:alnum:]_./-])git([^;&|]* )?switch([^;&|]* )?(-[a-zA-Z]*[cC][a-zA-Z]*|--create|--force-create)( |\$)" \
    || has "(^|[^[:alnum:]_./-])git([^;&|]* )?checkout([^;&|]* )?-[a-zA-Z]*[bB][a-zA-Z]*( |\$)" \
    || git_sub 'worktree add' \
    || has "(^|[^[:alnum:]_./-])git([^;&|]* )?branch [^-;&| ]" \
    || has 'task-start\.sh'
} && create_branch=true
{
  has "(^|[^[:alnum:]_./-])gh([^;&|]* )? (pr|issue) create([^[:alnum:]_-]|\$)" \
    || has '(pr|issue)-create\.sh'
} && created=true
$push || $commit || $create_branch || $created || exit 0

cwd="$(jq -r '.cwd // empty' <<<"$input")"
dir="$( (cd "${cwd:-.}" && pwd -P) 2>/dev/null || true)"
[ -n "$dir" ] || exit 0

# コマンドの出力（標準出力と標準エラー）
output="$(jq -r '.tool_response | if type == "object" then ((.stdout // "") + "\n" + (.stderr // "")) else (. // "" | tostring) end' <<<"$input" 2>/dev/null || true)"

links=()
add_link() {
  local l
  for l in ${links[@]+"${links[@]}"}; do
    [ "$l" != "$2: $1" ] || return 0
  done
  links+=("$2: $1")
}

# --- 作った PR・Issue（出力から拾う）-------------------------------------------------
if $created; then
  for u in $(printf '%s\n' "$output" | grep -Eo 'https://[^"[:space:]\\]+/(pull|issues)/[0-9]+' | awk '!seen[$0]++' || true); do
    case "$u" in
      */pull/*) add_link "$u" "PR" ;;
      *) add_link "$u" "Issue" ;;
    esac
  done
fi

# --- ブランチから導くリンク ----------------------------------------------------------
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || true)"
issue=""
if [ -n "$root" ] && [ -n "$branch" ]; then
  config="$( (cd "$dir" && WORKFLOW_REPO_ROOT="$root" bash "$DW_SCRIPTS_DIR/config.sh") 2>/dev/null || true)"
  if [ -n "$config" ]; then
    # ブランチ名を branch.pattern に当てて、Issue の番号を取り出す
    issue="$(jq -r --arg b "$branch" '
      .labels.types as $t
      | (.branch.pattern
        | gsub("\\{type\\}"; "(?<type>" + ($t | join("|")) + ")")
        | gsub("\\{issue_number\\}"; "(?<issue>[0-9]+)")
        | gsub("\\{slug\\}"; "[a-z0-9]+(?:-[a-z0-9]+)*")
        | "^" + . + "$") as $re
      | (try ($b | capture($re)) catch null) // {}
      | .issue // empty' <<<"$config" 2>/dev/null || true)"
  fi
fi
# task-start.sh は別のワークツリーを作るので、今のブランチではなく、出力の Issue の番号を使う
if has 'task-start\.sh'; then
  n="$(printf '%s\n' "$output" | jq -rs 'map(select(type == "object") | .issue // empty) | .[0] // empty' 2>/dev/null || true)"
  case "$n" in '' | *[!0-9]*) ;; *) issue="$n" ;; esac
fi

if [ -n "$issue" ]; then
  url="$( (cd "$dir" && gh issue view "$issue" --json url -q .url) 2>/dev/null || true)"
  [ -z "$url" ] || add_link "$url" "Issue #${issue}"
fi

if $push && [ -n "$issue" ] && [ -n "$branch" ]; then
  pr="$( (cd "$dir" && gh pr list --head "$branch" --state open --json url,isCrossRepository \
    -q 'map(select(.isCrossRepository | not)) | .[0].url // empty') 2>/dev/null || true)"
  if [ -n "$pr" ]; then
    add_link "$pr" "PR"
    add_link "$pr/checks" "CI"
  else
    repo="$( (cd "$dir" && gh repo view --json url -q .url) 2>/dev/null || true)"
    if [ -n "$repo" ]; then
      add_link "$repo/pull/new/$branch" "PR を作る"
      add_link "$repo/actions?query=branch%3A$(printf '%s' "$branch" | sed 's|/|%2F|g')" "CI"
    fi
  fi
fi

[ "${#links[@]}" -gt 0 ] || exit 0

msg="関連するリンク:"
for l in "${links[@]}"; do
  msg="${msg}
- ${l}"
done
ctx="${msg}
返答でも、これらのリンクに触れてください。"
jq -n --arg m "$msg" --arg c "$ctx" \
  '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
