#!/usr/bin/env bash
# やらないことにした Issue を、理由のコメントを付けて not planned で閉じる。
#
# 使い方: issue-close.sh --issue N --reason TEXT [--dry-run]
#   --issue N       Issue の番号
#   --reason TEXT   閉じる理由（コメントとして残す。代わりに作業する Issue などの参照先も書く）。空白だけなら止まる
#   --dry-run       変更せず、行う予定の操作だけを出力する
#
# Project からは外さず、Story Point も変えない（後からボードで経緯を参照できるように。設計書 §4）。
# 既に閉じている Issue では、コメントも付けずに止まる。最後のコメントが同じ理由なら（閉じるのに失敗した後の
# 再実行）、コメントを付け直さずに閉じる。
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

issue="" reason="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --reason)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --reason) reason="$2" ;;
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
# 理由の無いまま閉じると経緯が残らないので、空白だけの理由も受け付けない。
# tr はバイト単位で消すので、日本語の入力でよく入る全角スペース（U+3000）は先に取り除く
fullwidth_space="$(printf '\343\200\200')"
stripped="${reason//"$fullwidth_space"/}"
[ -n "$(printf '%s' "$stripped" | tr -d '[:space:]')" ] || dw_die "--reason に閉じる理由を書いてください" 64

issue_json="$(gh issue view "$issue" --json number,title,state,comments)" || dw_die "Issue #${issue} を読めません"
[ "$(jq -r .state <<<"$issue_json")" = OPEN ] || dw_die "Issue #${issue} は既に閉じています" 2

# コメントした後に閉じるのに失敗して再実行したときは、同じ理由を二重にコメントしない
commented=true
if jq -e --arg r "$reason" '(.comments // [] | last | .body) == $r' <<<"$issue_json" >/dev/null; then
  commented=false
fi

if ! $dry_run; then
  if $commented; then
    gh issue comment "$issue" --body "$reason" >/dev/null || dw_die "Issue #${issue} にコメントできませんでした"
  fi
  gh issue close "$issue" --reason "not planned" >/dev/null \
    || dw_die "Issue #${issue} にコメントしましたが、閉じられませんでした（もう一度実行すると、コメントを付け直さずに閉じます）"
fi

jq -n --argjson dry "$dry_run" --arg reason "$reason" --argjson commented "$commented" --argjson issue "$issue_json" '{
  issue: $issue.number,
  title: $issue.title,
  dry_run: $dry,
  state_reason: "NOT_PLANNED",
  comment: $reason,
  commented: $commented,
  actions: [
    (if $commented then "Issue #\($issue.number) に閉じる理由をコメントする"
     else "Issue #\($issue.number) の最後のコメントが同じ理由なので、コメントは付け直さない" end),
    "Issue #\($issue.number) を not planned で閉じる（Project と Story Point はそのまま残す）"
  ]
}'
