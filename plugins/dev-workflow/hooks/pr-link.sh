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
config=""
if [ -n "$root" ]; then
  config="$( (cd "$dir" && WORKFLOW_REPO_ROOT="$root" "$BASH" "$DW_SCRIPTS_DIR/config.sh") 2>/dev/null || true)"
fi
# ブランチ名を branch.pattern に当てて、Issue の番号を取り出す。使い方: issue_of <ブランチ名>
issue_of() {
  [ -n "$config" ] || return 0
  local parsed
  parsed="$(dw_parse_branch "$config" "$1" 2>/dev/null || true)"
  printf '%s\n' "${parsed#*|}"
}
[ -z "$branch" ] || issue="$(issue_of "$branch")"

# ブランチを作るコマンドは、今のブランチではなく、作るブランチの Issue を出す。
# ブランチの名前はコマンドの文字列から拾う。guard-git.sh（check_create）のようには解析せず、
# -c・-C・-b・-B・--create・--force-create の次の語と、git branch <名前> の最初の語だけを見る。
# そのため、-cname のようにオプションと名前をくっつけた書き方や、git branch --set-upstream-to <上流> <名前> のように
# 値を取るオプションを挟む書き方は、名前を取り違えるか拾えず、Issue のリンクを出さない
# （guard-git.sh は警告するのに、ここは出さない、という食い違いが起きる。tests/pr-link.bats で押さえてある）。
# 間違った Issue のリンクを出すより、何も出さないほうがよいので、拾えないときは今のブランチの Issue を使わない
created_branch() {
  local seg w prev="" name="" in_branch=false
  seg="$(printf '%s\n' "$cmd" | grep -Eo "git([^;&|]* )?(switch|checkout|worktree add|branch)[^;&|]*" | head -n 1 || true)"
  # shellcheck disable=SC2086 # 空白で語に分ける
  set -f
  for w in $seg; do
    w="${w#[\"\']}"
    w="${w%[\"\']}"
    case "$prev" in
      -c | -C | -b | -B | --create | --force-create)
        name="$w"
        break
        ;;
    esac
    if $in_branch; then
      case "$w" in -*) ;; *) name="$w"; break ;; esac
    fi
    [ "$w" != branch ] || in_branch=true
    prev="$w"
  done
  set +f
  printf '%s\n' "$name"
}
if $create_branch && ! has 'task-start\.sh'; then
  name="$(created_branch)"
  issue=""
  [ -z "$name" ] || issue="$(issue_of "$name")"
fi
# task-start.sh は別のワークツリーを作るので、今のブランチではなく、出力の Issue の番号を使う。
# 出力の JSON は標準出力にだけ出るので、標準エラーの警告（warn:）が混ざっても読める。取れなければ Issue は出さない
if has 'task-start\.sh'; then
  stdout="$(jq -r '.tool_response | if type == "object" then (.stdout // "") else (. // "" | tostring) end' <<<"$input" 2>/dev/null || true)"
  n="$(jq -r 'objects | .issue // empty' <<<"$stdout" 2>/dev/null | head -n 1 || true)"
  case "$n" in '' | *[!0-9]*) issue="" ;; *) issue="$n" ;; esac
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
