#!/usr/bin/env bash
# やらないことにした Issue を、理由のコメントを付けて not planned（重複なら duplicate）で閉じる。
#
# 使い方: issue-cancel.sh --issue N --reason TEXT [--duplicate-of M] [--dry-run]
#   --issue N           Issue の番号
#   --reason TEXT       閉じる理由（コメントとして残す。代わりに作業する Issue などの参照先も書く）。空白だけなら止まる
#   --duplicate-of M    重複の元の Issue の番号。付けると duplicate で閉じ、元の Issue に紐付ける
#   --dry-run           変更せず、行う予定の操作だけを出力する
#
# Project からは外さず、Story Point も変えない（後からボードで経緯を参照できるように。設計書 §4）。
# 何度実行しても同じ結果になる。最後のコメントが同じ理由ならコメントを付け直さず、同じ閉じ方で既に閉じていれば
# 閉じる操作を飛ばす。違う閉じ方や違う理由で既に閉じている Issue では、何もせずに止まる。
# GraphQL の変数（$owner など）を bash に展開させないため、クエリはシングルクォートで書く
# shellcheck disable=SC2016
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^# GraphQL の変数/{/^# GraphQL の変数/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

issue="" reason="" duplicate_of="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --reason | --duplicate-of)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --reason) reason="$2" ;;
        --duplicate-of) duplicate_of="${2#\#}" ;;
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

if [ -n "$duplicate_of" ]; then state_reason=DUPLICATE; else state_reason=NOT_PLANNED; fi

repo_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
vars() { jq -nc --arg r "$repo_nwo" --argjson n "$1" '{owner: ($r | split("/")[0]), name: ($r | split("/")[1]), number: $n}'; }

# PR の番号では repository.issue が見つからないので、PR を閉じることはない
found="$(dw_gql_find 'query CancelIssue($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { issue(number: $number) {
    id number title state stateReason comments(last: 1) { nodes { body } } } }
}' "$(vars "$issue")" | jq -c '.data.repository.issue // null')"
[ "$found" != null ] || dw_die "Issue #${issue} が ${repo_nwo} にありません" 2

dup_id=""
if [ -n "$duplicate_of" ]; then
  dup="$(dw_gql_find 'query CancelDuplicate($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) { issue(number: $number) { id number } }
  }' "$(vars "$duplicate_of")" | jq -c '.data.repository.issue // null')"
  [ "$dup" != null ] || dw_die "重複の元の Issue #${duplicate_of} が ${repo_nwo} にありません" 2
  dup_id="$(jq -r .id <<<"$dup")"
fi

issue_id="$(jq -r .id <<<"$found")"
# コメントした後に閉じるのに失敗して再実行したときは、同じ理由を二重にコメントしない
commented=true
if jq -e --arg r "$reason" '.comments.nodes[-1].body == $r' <<<"$found" >/dev/null; then
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

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

if $commented; then
  note "Issue #${issue} に閉じる理由をコメントする"
  if ! $dry_run; then
    dw_gql 'mutation AddComment($id: ID!, $body: String!) {
      addComment(input: {subjectId: $id, body: $body}) { commentEdge { node { id } } }
    }' "$(jq -nc --arg id "$issue_id" --arg b "$reason" '{id: $id, body: $b}')" >/dev/null \
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
    dw_gql 'mutation CloseIssue($id: ID!, $reason: IssueClosedStateReason!, $dup: ID) {
      closeIssue(input: {issueId: $id, stateReason: $reason, duplicateIssueId: $dup}) { issue { state } }
    }' "$(jq -nc --arg id "$issue_id" --arg r "$state_reason" --arg d "$dup_id" \
      '{id: $id, reason: $r, dup: (if $d == "" then null else $d end)}')" >/dev/null \
      || dw_die "Issue #${issue} にコメントしましたが、閉じられませんでした（もう一度実行すると、コメントを付け直さずに閉じます）"
  fi
fi

jq -n --argjson found "$found" --argjson dry "$dry_run" --arg reason "$reason" --arg sr "$state_reason" \
  --arg dup "$duplicate_of" --argjson commented "$commented" --argjson closed "$closed" --argjson actions "$actions" '{
    issue: $found.number,
    title: $found.title,
    dry_run: $dry,
    state_reason: $sr,
    duplicate_of: (if $dup == "" then null else ($dup | tonumber) end),
    comment: $reason,
    commented: $commented,
    closed: $closed,
    actions: $actions
  }'
