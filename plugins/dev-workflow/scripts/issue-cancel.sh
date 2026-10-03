#!/usr/bin/env bash
# やらないことにした Issue を、理由のコメントを付けて not planned（重複なら duplicate）で閉じる。
#
# 使い方: issue-cancel.sh --issue N --reason TEXT [--duplicate-of M] [--branch NAME] [--dry-run]
#   --issue N           Issue の番号
#   --reason TEXT       閉じる理由（コメントとして残す。代わりに作業する Issue などの参照先も書く）。空白だけなら止まる
#   --duplicate-of M    重複の元の Issue の番号。付けると duplicate で閉じ、元の Issue に紐付ける（gh 2.88.0 以上）
#   --branch NAME       やめた作業のブランチ。そのブランチの開いている PR を同じ理由のコメントを付けて閉じ、
#                       リモート（origin）のブランチを削除する。手元のワークツリーとブランチは消さない（cleanup.sh --abandon）
#   --dry-run           変更せず、行う予定の操作だけを出力する
#
# Project からは外さず、Story Point も変えない（後からボードで経緯を参照できるように。設計書 §4）。
# Issue → PR → リモートのブランチの順に行う。何度実行しても同じ結果になるので、途中で失敗しても再実行で続きから進む。
# 最後のコメントが同じ理由ならコメントを付け直さず、同じ閉じ方で既に閉じていれば閉じる操作を飛ばす。
# 違う閉じ方や違う理由で既に閉じている Issue では、何もせずに止まる。
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

issue="" reason="" duplicate_of="" branch="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --reason | --duplicate-of | --branch)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --reason) reason="$2" ;;
        --duplicate-of) duplicate_of="${2#\#}" ;;
        --branch) branch="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
case "$issue" in
  *[!0-9]*) dw_die "--issue には数字を指定してください: $issue" 64 ;;
esac
case "$duplicate_of" in
  *[!0-9]*) dw_die "--duplicate-of には数字を指定してください: $duplicate_of" 64 ;;
esac
# 先頭の 0 を取り除いてから比べる（017 と 17 は同じ Issue）
if [ -n "$duplicate_of" ] && [ "$((10#$duplicate_of))" -eq "$((10#$issue))" ]; then
  dw_die "--duplicate-of に閉じる Issue 自身（#${issue}）は指定できません" 64
fi
# 理由の無いまま閉じると経緯が残らないので、空白だけの理由も受け付けない。
# tr はバイト単位で消すので、日本語の入力でよく入る全角スペース（U+3000）は先に取り除く
fullwidth_space="$(printf '\343\200\200')"
stripped="${reason//"$fullwidth_space"/}"
[ -n "$(printf '%s' "$stripped" | tr -d '[:space:]')" ] || dw_die "--reason に閉じる理由を書いてください" 64

if [ -n "$duplicate_of" ]; then
  state_reason=DUPLICATE
  dw_require_gh_version "$DW_GH_MIN_VERSION" "重複として閉じる（gh issue close --duplicate-of）"
else
  state_reason=NOT_PLANNED
fi

if [ -n "$branch" ]; then
  base="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" | jq -r '.base_branch // "main"')"
  [ "$branch" != "$base" ] || dw_die "${base} は削除できません。--branch で作業用のブランチを指定してください" 64
fi

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

# Issue を読む。gh issue view は PR の番号でも成功するので、URL で PR を見分ける
# 使い方: read_issue <番号> <JSON の項目> <見つからないときの名前>
read_issue() {
  local json err
  err="$(mktemp)"
  if ! json="$(gh issue view "$1" --json "url,$2" 2>"$err")"; then
    json="$(cat "$err")"
    rm -f "$err"
    case "$json" in
      *"Could not resolve to"* | *NOT_FOUND*) dw_die "${3} #${1} が ${repo_nwo} にありません" 2 ;;
      *) dw_die "${3} #${1} を読めません: $json" ;;
    esac
  fi
  rm -f "$err"
  case "$(jq -r .url <<<"$json")" in
    */pull/*) dw_die "#${1} は PR です。Issue の番号を指定してください" 2 ;;
  esac
  printf '%s\n' "$json"
}

found="$(read_issue "$issue" number,title,state,stateReason,comments Issue)"
[ -z "$duplicate_of" ] || read_issue "$duplicate_of" number "重複の元の Issue" >/dev/null

# コメントした後に閉じるのに失敗して再実行したときは、同じ理由を二重にコメントしない
commented=true
if jq -e --arg r "$reason" '.comments[-1].body == $r' <<<"$found" >/dev/null; then
  commented=false
fi
closed=true
if [ "$(jq -r .state <<<"$found")" != OPEN ]; then
  # 同じ閉じ方・同じ理由で閉じていれば、前回の実行の続きとして閉じる操作を飛ばす
  if [ "$(jq -r .stateReason <<<"$found")" = "$state_reason" ] && ! $commented; then
    closed=false
  else
    dw_die "Issue #${issue} は既に閉じています" 2
  fi
fi

# やめた作業のリモートのブランチ（無ければ空）と、それを head とする開いている PR
remote="" prs='[]'
if [ -n "$branch" ]; then
  if err="$(gh api "repos/$repo_nwo/git/ref/heads/$branch" 2>&1 >/dev/null)"; then
    remote="$branch"
  else
    case "$err" in
      *"HTTP 404"*) ;;
      *) dw_die "リモートのブランチ ${branch} を確かめられませんでした: $err" ;;
    esac
  fi
  prs="$(gh pr list --head "$branch" --state open --json number,title,url,comments)" \
    || dw_die "${branch} の PR を取得できませんでした"
  prs="$(jq -c --arg r "$reason" 'map({number, title, url, commented: (.comments[-1].body != $r)})' <<<"$prs")"
fi

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

if $commented; then
  note "Issue #${issue} に閉じる理由をコメントする"
  if ! $dry_run; then
    printf '%s' "$reason" | gh issue comment "$issue" --body-file - >/dev/null \
      || dw_die "Issue #${issue} にコメントできませんでした"
  fi
fi
if $closed; then
  if [ -n "$duplicate_of" ]; then
    note "Issue #${issue} を #${duplicate_of} の重複（duplicate）として閉じる（Project と Story Point はそのまま残す）"
  else
    note "Issue #${issue} を not planned で閉じる（Project と Story Point はそのまま残す）"
  fi
  if ! $dry_run; then
    if [ -n "$duplicate_of" ]; then
      gh issue close "$issue" --duplicate-of "$duplicate_of" >/dev/null 2>&1
    else
      gh issue close "$issue" --reason "not planned" >/dev/null 2>&1
    fi || dw_die "Issue #${issue} にコメントしましたが、閉じられませんでした（もう一度実行すると、コメントを付け直さずに閉じます）"
  fi
fi

for pr_number in $(jq -r '.[].number' <<<"$prs"); do
  if [ "$(jq -r --argjson n "$pr_number" '.[] | select(.number == $n) | .commented' <<<"$prs")" = true ]; then
    note "PR #${pr_number} に閉じる理由をコメントする"
    if ! $dry_run; then
      printf '%s' "$reason" | gh pr comment "$pr_number" --body-file - >/dev/null \
        || dw_die "Issue #${issue} は閉じましたが、PR #${pr_number} にコメントできませんでした（もう一度実行すると続きから進みます）"
    fi
  fi
  note "PR #${pr_number} をマージせずに閉じる"
  # --delete-branch は手元のブランチも消し、ワークツリーで使っていると失敗するので、リモートのブランチは下で消す
  $dry_run || gh pr close "$pr_number" >/dev/null 2>&1 \
    || dw_die "Issue #${issue} は閉じましたが、PR #${pr_number} を閉じられませんでした（もう一度実行すると続きから進みます）"
done
if [ -n "$remote" ]; then
  note "リモートのブランチ ${branch} を削除する"
  $dry_run || gh api -X DELETE "repos/$repo_nwo/git/refs/heads/$branch" >/dev/null 2>&1 \
    || dw_die "Issue #${issue} は閉じましたが、リモートのブランチ ${branch} を削除できませんでした（もう一度実行すると続きから進みます）"
fi

jq -n --argjson found "$found" --argjson dry "$dry_run" --arg reason "$reason" --arg sr "$state_reason" \
  --arg dup "$duplicate_of" --argjson commented "$commented" --argjson closed "$closed" --argjson actions "$actions" \
  --arg branch "$branch" --arg remote "$remote" --argjson prs "$prs" '{
    issue: $found.number,
    title: $found.title,
    dry_run: $dry,
    state_reason: $sr,
    duplicate_of: (if $dup == "" then null else ($dup | tonumber) end),
    comment: $reason,
    commented: $commented,
    closed: $closed,
    branch: (if $branch == "" then null else $branch end),
    pull_requests: $prs,
    remote_branch_deleted: ($remote != ""),
    actions: $actions
  }'
