#!/usr/bin/env bash
# ブランチ名を作る、または検証する。ブランチ名は [a-z0-9-/] だけにする（日本語は含めない）。
#
# 使い方:
#   branch-name.sh --issue N --slug TEXT [--type TYPE]   ブランチ名を作る
#   branch-name.sh --check NAME                          ブランチ名が規約（文字と branch.pattern の形）に合うか確かめる
#
#   --issue N      Issue の番号（#N でもよい）
#   --slug TEXT    短い説明（英語）。小文字にし、英数字以外は - にして 40 文字までに整える
#   --type TYPE    type（既定: Issue の type ラベル。labels.types のどれか1つが付いている必要がある）
#
# 形は設定の branch.pattern（既定: {type}/{issue_number}-{slug}）。
# branch.pattern のプレースホルダ: {type} は type ラベル、{issue_number} は Issue の番号、{slug} は英語の短い説明。
# --check は規約に合わなければ終了コード 1 で、理由を出力する。設定を読めなければ終了コード 2。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require git jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

issue="" slug="" type="" check=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --slug | --type | --check)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --slug) slug="$2" ;;
        --type) type="$2" ;;
        --check) check="$2" ;;
      esac
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

# 規約に合わない理由を出力する。合っていれば何も出力しない
# 文字の判定は LC_ALL=C で行う（macOS の bash 3.2 は UTF-8 のロケールで [a-z] に大文字も含めてしまう）
problem() {
  if printf '%s' "$1" | LC_ALL=C grep -q '[^a-z0-9/-]'; then
    echo "小文字の英数字と - / 以外の文字があります"
    return
  fi
  case "$1" in
    /* | */ | -* | *- | *//* | */-* | *-/*) echo "/ や - で始まる・終わる、または続いています" ;;
    *)
      git check-ref-format --branch "$1" >/dev/null 2>&1 || echo "git のブランチ名として使えません"
      ;;
  esac
}

if [ -n "$check" ]; then
  reason="$(problem "$check")"
  if [ -z "$reason" ]; then
    # 設定を読めないときは、規約に合わない（1）と区別できるよう 2 で終わる
    config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")" || dw_die "設定を読めません" 2
    # branch.pattern を正規表現にする。名前は上で [a-z0-9/-] だけと確かめたので、
    # 形の中の . などの記号に当たることはなく、プレースホルダを置き換えるだけでよい
    re="$(jq -r '
      .labels.types as $t
      | .branch.pattern
      | gsub("\\{type\\}"; "(" + ($t | join("|")) + ")")
      | gsub("\\{issue_number\\}"; "[0-9]+")
      | gsub("\\{slug\\}"; "[a-z0-9]+(-[a-z0-9]+)*")
      | "^" + . + "$"' <<<"$config")"
    jq -e -n --arg b "$check" --arg r "$re" '$b | test($r)' >/dev/null \
      || reason="branch.pattern（$(jq -r '.branch.pattern' <<<"$config")）の形になっていません"
  fi
  jq -n --arg b "$check" --arg r "$reason" '{branch: $b, valid: ($r == ""), reason: (if $r == "" then null else $r end)}'
  [ -z "$reason" ]
  exit
fi

[ -n "$issue" ] || dw_die "--issue は必須です" 64
# スキルの引数の #12 も受ける（dw_issue_number）
issue="$(dw_issue_number --issue "$issue")"
[ -n "$slug" ] || dw_die "--slug は必須です" 64

# 小文字にし、英数字以外（日本語を含む）を - にまとめ、前後の - を除いて 40 文字までにする
slug="$(printf '%s' "$slug" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
  | LC_ALL=C sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40 | sed 's/-$//')"
[ -n "$slug" ] || dw_die "短い説明に英数字がありません。英語で指定してください" 64

config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
if [ -z "$type" ]; then
  dw_require gh
  # PR の番号なら止まる（dw_read_issue）
  issue_json="$(dw_read_issue "$issue" labels)"
  types="$(jq -c --argjson t "$(jq -c '.labels.types' <<<"$config")" '[.labels[].name | select(. as $n | $t | index($n))]' <<<"$issue_json")"
  case "$(jq length <<<"$types")" in
    1) type="$(jq -r '.[0]' <<<"$types")" ;;
    0) dw_die "Issue #${issue} に type ラベルがありません（$(jq -r '.labels.types | join(" / ")' <<<"$config") のどれか1つを付けてください）" 2 ;;
    *) dw_die "Issue #${issue} に type ラベルが複数あります（$(jq -r 'join(", ")' <<<"$types")）。1つにしてください" 2 ;;
  esac
fi
jq -e --arg t "$type" '.labels.types | index($t)' <<<"$config" >/dev/null \
  || dw_die "type は labels.types のどれかにしてください: $type" 64

pattern="$(jq -r '.branch.pattern' <<<"$config")"
branch="$(jq -rn --arg p "$pattern" --arg t "$type" --arg i "$issue" --arg s "$slug" \
  '$p | gsub("\\{type\\}"; $t) | gsub("\\{issue_number\\}"; $i) | gsub("\\{slug\\}"; $s)')"
reason="$(problem "$branch")"
[ -z "$reason" ] || dw_die "ブランチ名 ${branch} が規約に合いません（${reason}）。branch.pattern を確かめてください" 2

jq -n --arg b "$branch" --arg t "$type" --argjson i "$issue" --arg s "$slug" \
  '{branch: $b, type: $t, issue: $i, slug: $s}'
