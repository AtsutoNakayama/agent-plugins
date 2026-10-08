#!/usr/bin/env bash
# task-auto が止まる条件に当たったときに、理由とそれまでの判断を Issue にコメントし、Issue を保留の列（status.hold）に移す。
# ワークツリー・ブランチ・コミットには触れない（人が続きから進められるように残す）。
# 何度実行しても同じ結果になる（Issue に同じ本文のコメントがあれば、最後のものでなくても付け直さず、既に保留の列なら移さない）ので、
# 途中で止まっても、もう一度実行すれば続きから進む。
#
# 使い方: auto-hold.sh --issue N --reason-file PATH [--dry-run]
#   --issue N           Issue の番号（#N でもよい）
#   --reason-file PATH  コメントの本文（止まった理由とそれまでの判断）のファイル。- なら標準入力。
#                       本文の先頭に、task-auto のコメントだと分かる印（<!-- dev-workflow:task-auto -->）を足して投稿する
#   --dry-run           コメントも列の移動もせず、行う予定の操作とコメントの本文を出力する
#
# 止まるとき: 保留の列（status.hold）が設定されていない・本文が空（終了コード 2）、PR の番号・無い番号（2）、
#             Issue を読めない・コメントできない・列を移せない（1）
#
# 出力: {issue, comment（投稿する本文）, commented（今回コメントしたか。dry-run ではする予定か）,
#        status（status-set.sh の出力。dry-run では null）, dry_run, actions}
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# task-auto のコメントだと分かる印。人が Issue を読んだときに、自動で書いたコメントと分かるようにする
MARK='<!-- dev-workflow:task-auto -->'

issue="" reason_file="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --reason-file)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --issue) issue="$2" ;;
        --reason-file) reason_file="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
# スキルの引数の #12 も受ける（dw_issue_number）
issue="$(dw_issue_number --issue "$issue")"
[ -n "$reason_file" ] || dw_die "--reason-file は必須です" 64
if [ "$reason_file" = - ]; then
  reason="$(cat)"
else
  [ -f "$reason_file" ] || dw_die "本文のファイルがありません: $reason_file" 64
  reason="$(cat "$reason_file")"
fi
[ -n "$(printf '%s' "$reason" | tr -d '[:space:]')" ] || dw_die "コメントの本文（止まった理由）が空です" 2

config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
hold="$(jq -r '.status.hold // empty' <<<"$config")"
[ -n "$hold" ] || dw_die "保留の列（status.hold）が設定されていません。repo-setup で保留の列を作ってください" 2
dw_check_hold_column "$config"

body="$(printf '%s\n\n%s' "$MARK" "$reason")"

# PR の番号なら止まる（dw_read_issue）
found="$(dw_read_issue "$issue" number,comments)"
commented=true
# 列の移動に失敗した後、誰かがコメントしてから実行し直しても二重に付けないよう、最後のコメントだけでなく全部と比べる
if jq -e --arg b "$body" 'any(.comments[]?; .body == $b)' <<<"$found" >/dev/null; then
  commented=false
fi

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

if $commented; then
  note "Issue #${issue} に、止まった理由とそれまでの判断をコメントする"
else
  note "Issue #${issue} には同じコメントがあるので、付け直さない"
fi
note "Issue #${issue} を保留の列「${hold}」に移す"

status=null
if ! $dry_run; then
  if $commented; then
    printf '%s' "$body" | gh issue comment "$issue" --body-file - >/dev/null \
      || dw_die "Issue #${issue} にコメントできませんでした"
  fi
  if $commented; then done_note="Issue #${issue} にコメントしましたが、"; else done_note="Issue #${issue} を"; fi
  status="$("$BASH" "$DW_SCRIPTS_DIR/status-set.sh" --issue "$issue" --to hold)" \
    || dw_die "${done_note}保留の列「${hold}」に移せませんでした（$($commented || echo '同じコメントは既にあります。')もう一度実行すれば、コメントは付け直さずに列だけを移します）"
fi

jq -n --argjson i "$issue" --arg c "$body" --argjson cm "$commented" --argjson s "$status" \
  --argjson d "$dry_run" --argjson a "$actions" \
  '{issue: $i, comment: $c, commented: $cm, status: $s, dry_run: $d, actions: $a}'
