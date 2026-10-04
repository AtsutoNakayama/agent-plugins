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

# ファイル名の展開（*・?）は要らないので止める。コマンドの文字列を空白で語に分けるときに、展開されないようにする
set -f

push=false commit=false create_branch=false created=false
# ブランチを作るコマンドの、作るブランチの名前（拾えなければ空）
created_name=""
has 'pr-create\.sh' && push=true
has 'commit\.sh' && commit=true
has 'task-start\.sh' && create_branch=true
{ has "(^|[^[:alnum:]_./-])gh( [^;&|]*)? (pr|issue) create([^[:alnum:]_-]|\$)" || has '(pr|issue)-create\.sh'; } && created=true

# <オプション>のどれかの次の語を name に入れる。使い方: name_after "<オプション（空白区切り）>" <語>...
name_after() {
  local opts=" $1 " prev="" w
  shift
  for w in "$@"; do
    case "$opts" in *" $prev "*) name="$w"; return 0 ;; esac
    prev="$w"
  done
  return 1
}

# コマンドの文字列の git の呼び出しごとに、オプション（-C <dir>・-c <k=v> など）を飛ばした最初の語をサブコマンドとして、
# push・commit・ブランチの作成を判定する。git stash push や git log --grep commit は、サブコマンドが違うので当たらない。
# guard-git.sh（check_command）のようには解析しない。cd や git -C で移った先は追わず、引用符や $( ) の中の git も区別せずに拾う。
# ブランチを作るコマンドは、-c・-C・-b・-B・--create・--force-create の次の語と、git branch <名前> の最初の語を、
# 作るブランチの名前にする。-cname のようにオプションと名前をくっつけた書き方は、作ることだけが分かり、名前は拾えない
# （guard-git.sh は警告するのに、ここは Issue のリンクを出さない、という食い違いが起きる。tests/pr-link.bats で押さえてある）
scan_git() {
  local line sub w name dry
  while IFS= read -r line; do
    line="${line#*git}"
    # shellcheck disable=SC2086 # 空白で語に分ける（set -f で展開を止めてある）
    set -- $line
    sub=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -C | -c | --git-dir | --work-tree | --namespace | --config-env)
          if [ $# -ge 2 ]; then shift 2; else shift $#; fi
          ;;
        -*) shift ;;
        *) sub="$1"; shift; break ;;
      esac
    done
    name=""
    case "$sub" in
      push)
        # git push -n（--dry-run）は push しない
        dry=false
        for w in "$@"; do
          case "$w" in -n | --dry-run) dry=true ;; esac
        done
        $dry || push=true
        ;;
      commit) commit=true ;;
      switch)
        name_after "-c -C --create --force-create" "$@" || true
        for w in "$@"; do
          case "$w" in --*) ;; -*[cC]*) create_branch=true ;; esac
        done
        [ -z "$name" ] || create_branch=true
        ;;
      checkout)
        name_after "-b -B" "$@" || true
        for w in "$@"; do
          case "$w" in --*) ;; -*[bB]*) create_branch=true ;; esac
        done
        ;;
      worktree)
        if [ "${1:-}" = add ]; then
          shift
          name_after "-b -B" "$@" || true
          for w in "$@"; do
            case "$w" in --*) ;; -*[bB]*) create_branch=true ;; esac
          done
          # -b が無くても、ワークツリーを作るので、ブランチも作る（名前は拾わない）
          create_branch=true
        fi
        ;;
      branch)
        # git branch <名前>（一覧・削除・名前の変更などのオプションが先にあるときは作らない）
        case "${1:-}" in '' | -*) ;; *) name="$1"; create_branch=true ;; esac
        ;;
    esac
    name="${name#[\"\']}"
    name="${name%[\"\']}"
    [ -z "$name" ] || [ -n "$created_name" ] || created_name="$name"
  done < <(printf '%s\n' "$cmd" | grep -Eo '(^|[^[:alnum:]_./-])git( [^;&|]*)?' || true)
}
scan_git
$push || $commit || $create_branch || $created || exit 0
# --dry-run のコマンドは、push も commit も PR・Issue の作成もしない（スクリプトの --dry-run を含む）ので、何も出さない
has '(^|[[:space:]])--dry-run([[:space:]=]|$)' && exit 0

cwd="$(jq -r '.cwd // empty' <<<"$input")"
dir="$( (cd "${cwd:-.}" && pwd -P) 2>/dev/null || true)"
[ -n "$dir" ] || exit 0

# コマンドの標準出力（標準エラーは見ない。警告などが混ざるので）
stdout="$(jq -r '.tool_response | if type == "object" then (.stdout // "") else (. // "" | tostring) end' <<<"$input" 2>/dev/null || true)"

links=()
add_link() {
  local l
  for l in ${links[@]+"${links[@]}"}; do
    [ "$l" != "$2: $1" ] || return 0
  done
  links+=("$2: $1")
}

# --- 作った PR・Issue（標準出力から拾う）-------------------------------------------
# スクリプトの出力の JSON は url に作ったものの URL を持つ（body などの別の URL は拾わない）。
# gh pr create・gh issue create は、URL だけの行を出す
if $created; then
  for u in $( { jq -r 'objects | .url // empty' <<<"$stdout" 2>/dev/null || true
    printf '%s\n' "$stdout" | grep -E '^https://[^[:space:]]+/(pull|issues)/[0-9]+[[:space:]]*$' || true; } | awk '!seen[$0]++'); do
    case "$u" in
      */pull/*) add_link "$u" "PR" ;;
      */issues/*) add_link "$u" "Issue" ;;
    esac
  done
fi

# --- ブランチから導くリンク ----------------------------------------------------------
root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
branch="$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null || true)"
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
cwd_issue=""
[ -z "$branch" ] || cwd_issue="$(issue_of "$branch")"

# 出す Issue のリンク。操作ごとに、対象の Issue が違う
#   - push・commit・PR や Issue を作る操作：今のブランチの Issue
#   - ブランチを作るコマンド：作るブランチの Issue（名前が拾えない・Issue の番号が無いときは出さない。間違った Issue より、何も出さないほうがよい）
#   - task-start.sh：標準出力の JSON の issue（別のワークツリーを作るので。標準エラーの警告（warn:）が混ざっても読める。取れなければ出さない）
issues=()
if $push || $commit || $created; then
  [ -z "$cwd_issue" ] || issues+=("$cwd_issue")
fi
if has 'task-start\.sh'; then
  n="$(jq -r 'objects | .issue // empty' <<<"$stdout" 2>/dev/null | head -n 1 || true)"
  case "$n" in '' | *[!0-9]*) ;; *) issues+=("$n") ;; esac
elif $create_branch && [ -n "$created_name" ]; then
  n="$(issue_of "$created_name")"
  [ -z "$n" ] || issues+=("$n")
fi

for n in ${issues[@]+"${issues[@]}"}; do
  url="$( (cd "$dir" && gh issue view "$n" --json url -q .url) 2>/dev/null || true)"
  [ -z "$url" ] || add_link "$url" "Issue #${n}"
done

# push の PR・CI は、今のブランチのもの（Issue が分からないブランチでは出さない）
if $push && [ -n "$cwd_issue" ] && [ -n "$branch" ]; then
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
