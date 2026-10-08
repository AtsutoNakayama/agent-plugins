#!/usr/bin/env bash
# task-auto が始める前に、設定と Issue から、進めるか・止まるかを決める。何も変えない。
#
# 使い方: auto-check.sh --issue N
#   --issue N   Issue の番号（#N でもよい）
#
# action（上から順に、当てはまった最初のもの）:
#   disabled       auto.enabled が true でない。何もせずに止まる（Issue も読まない）
#   no_hold        保留の列（status.hold）が設定されていない。止まったときに移す列が無いので、始めずに止まり、
#                  repo-setup で作るよう案内する（Issue も読まない）
#   not_startable  Issue が閉じている、または親の Issue（サブ Issue を持つ）。着手するものが無いので、何も変えずに止まる
#   hold           止まる条件に当たる（reasons）。理由を Issue にコメントして保留の列に移し（auto-hold.sh）、止まる
#   proceed        進める
#
# 止まる条件のうち、スクリプトが決めるもの（hold）:
#   - breaking ラベルがある（移行のしかたを含め、人が決めることなので）
#   - type ラベル（labels.types）が1つではない
#   - 「やること」の節（見出しが やること・Tasks・To do）に項目が無い
#   - 「完了条件」の節（見出しが 完了条件・Acceptance criteria・Definition of done）に項目が無い
#   本文は、ほかのスクリプトと同じく md_scan（lib/common.sh）の決まりで読む（コードブロックと複数行の HTML のコメントの中は見ない）。
#   節は、見出しから、同じかより上の段の次の見出しの前まで（節の中の小見出しの下も含む）。見出しの # の数は問わず、
#   英語は大文字と小文字を区別しない。節の中身は、見出しでない空でない行（リストの印・チェックボックスだけの行と、
#   1行の HTML のコメントだけの行は空とみなす）
# 解釈が分かれるかや、差分に ADR にすべき判断があるかは、AI が判断する（このスクリプトでは決めない）
#
# 止まるとき（有効なときだけ。無効なら設定の値は検査しない）: auto.max_fix_attempts が1以上の整数でない・auto.max_new_issues が0以上の整数でない・
#             保留の列がほかの役割と同じ名前（終了コード 2）、PR の番号・無い番号（2）、Issue を読めない（1）
#
# 出力:
#   issue      {number, title, url, state, body, type（type ラベルが1つなら、その名前。ほかは null）, breaking}。
#              disabled・no_hold では null。task-auto は、この body で Issue があいまいかを判断する（読み直さない）
#   action     上の値
#   reasons    action の理由（文の配列。proceed では空）
#   settings   {max_fix_attempts, max_new_issues, hold（保留の列の名前か null）}。disabled では null
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      issue="$2"
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
# スキルの引数の #12 も受ける（dw_issue_number）
issue="$(dw_issue_number --issue "$issue")"

config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"

# 使い方: out <action> <Issue の JSON か null> <理由の配列>
settings=null
out() {
  jq -n --arg a "$1" --argjson i "$2" --argjson r "$3" --argjson s "$settings" \
    '{issue: $i, action: $a, reasons: $r, settings: $s}'
}

# 無効なら、ほかの設定を検査せずに止まる（無効のリポジトリで、使わない設定の誤りで止まらないように）
if [ "$(jq -r '.auto.enabled == true' <<<"$config")" != true ]; then
  out disabled null '["auto.enabled が true ではありません（task-auto を使うリポジトリでは、設定で有効にします）"]'
  exit 0
fi

# 使い方: count_setting <キー> <最小値> → 設定 auto.<キー> の値（整数でなければ止まる）
count_setting() {
  local v
  v="$(jq -c --arg k "$1" '.auto[$k]' <<<"$config")"
  case "$v" in
    "" | null | 0[0-9]* | *[!0-9]*) dw_die "auto.${1} は${2}以上の整数にしてください: ${v}" 2 ;;
  esac
  [ "$v" -ge "$2" ] || dw_die "auto.${1} は${2}以上の整数にしてください: ${v}" 2
  printf '%s\n' "$v"
}
max_fix="$(count_setting max_fix_attempts 1)"
max_new="$(count_setting max_new_issues 0)"
hold="$(jq -r '.status.hold // empty' <<<"$config")"
settings="$(jq -nc --argjson f "$max_fix" --argjson n "$max_new" --arg h "$hold" \
  '{max_fix_attempts: $f, max_new_issues: $n, hold: (if $h == "" then null else $h end)}')"

if [ -z "$hold" ]; then
  out no_hold null '["保留の列（status.hold）が設定されていません。止まったときに移す列が無いので、repo-setup で保留の列を作ってください"]'
  exit 0
fi
dw_check_hold_column "$config"

# PR の番号なら止まる（dw_read_issue）
issue_json="$(dw_read_issue "$issue" number,title,state,labels,body,subIssuesSummary)"
labels="$(jq -c '[.labels[].name]' <<<"$issue_json")"
types="$(jq -c --argjson t "$(jq -c '.labels.types' <<<"$config")" "$DW_JQ_ISSUE_TYPES"' issue_types($t)' <<<"$labels")"
# GitHub と同じく、ラベルの名前は大文字と小文字を区別せずに照合する
breaking="$(jq --arg b "$DW_BREAKING_LABEL" 'any(.[]; ascii_downcase == $b)' <<<"$labels")"
summary="$(jq -c --argjson t "$types" --argjson b "$breaking" \
  '{number, title, url, state, body: (.body // ""), type: (if ($t | length) == 1 then $t[0] else null end), breaking: $b}' <<<"$issue_json")"

reasons='[]'
add_reason() { reasons="$(jq -c --arg r "$1" '. + [$r]' <<<"$reasons")"; }

if [ "$(jq -r .state <<<"$issue_json")" != OPEN ]; then
  add_reason "Issue #${issue} は閉じています"
fi
subs="$(jq -r '.subIssuesSummary.total // 0' <<<"$issue_json")"
if [ "$subs" -gt 0 ]; then
  add_reason "Issue #${issue} は親の Issue（サブ Issue が ${subs} 件）です。作業は子の Issue で進めます"
fi
if [ "$(jq length <<<"$reasons")" -gt 0 ]; then
  out not_startable "$summary" "$reasons"
  exit 0
fi

if [ "$breaking" = true ]; then
  add_reason "breaking ラベルが付いています（破壊的変更と移行のしかたは、人が決めます）"
fi
case "$(jq length <<<"$types")" in
  1) ;;
  0) add_reason "type ラベルがありません（$(jq -r '.labels.types | join(", ")' <<<"$config") のどれか1つを付けてください）" ;;
  *) add_reason "type ラベルが1つではありません（今は $(jq -r 'join(", ")' <<<"$types")）" ;;
esac

# 本文の「やること」（tasks）と「完了条件」（criteria）の節のうち、中身のあるものの名前を1行ずつ出す（上の説明の決まり）
filled="$(jq -r "$DW_JQ_MD_SCAN"'
  (.body // "") as $b | ($b | md_scan) as $m
  | ($b | split("\n") | map(sub("\r$"; ""))) as $l
  | [$m.headings[] as $i | ($l[$i] | capture("^ {0,3}(?<h>#{1,6})\\s*(?<t>.*)$")) as $c
      | {line: $i, level: ($c.h | length),
         kind: ($c.t | sub("\\s+#+\\s*$"; "") | sub("\\s+$"; "") | ascii_downcase
           | if IN("やること", "tasks", "to do", "todo") then "tasks"
             elif IN("完了条件", "acceptance criteria", "definition of done") then "criteria"
             else null end)}] as $hs
  | [range(0; $hs | length) as $k | $hs[$k] | select(.kind != null) | . as $h
      | ([$hs[$k + 1:][] | select(.level <= $h.level) | .line] | first // ($l | length)) as $end
      | select(any($m.lines[]; .line > $h.line and .line < $end
          and (.line as $x | $hs | any(.line == $x) | not)
          and (.text | sub("^\\s*<!--.*-->\\s*$"; "") | sub("^\\s*(?:[-*+]|[0-9]+[.)])(?:\\s+|$)"; "")
               | sub("^\\[[ xX]\\]"; "") | test("\\S"))))
      | .kind] | unique[]' <<<"$issue_json")"
grep -qx tasks <<<"$filled" || add_reason "本文の「やること」に項目がありません（何をするかが決まっていません）"
grep -qx criteria <<<"$filled" || add_reason "本文の「完了条件」に項目がありません（どこまでやれば終わりかが決まっていません）"

if [ "$(jq length <<<"$reasons")" -gt 0 ]; then
  out hold "$summary" "$reasons"
else
  out proceed "$summary" '[]'
fi
