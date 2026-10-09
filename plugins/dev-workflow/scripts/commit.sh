#!/usr/bin/env bash
# コミットメッセージを規約（Conventional Commits）で検証してから、ステージした変更をコミットする。
#
# 使い方: commit.sh --message-file PATH [--dry-run]
#   --message-file PATH   コミットメッセージのファイル。- なら標準入力
#   --dry-run             コミットせず、検証だけを行う
#
# 検証すること:
#   - 1行目が設定の commit.pattern に合う（<type>(<scope>): <要約>）
#   - commit.scope_required が true ならスコープがある
#   - Refs を付けていない（Issue との紐付けは PR の Closes #N で行う）
#   - マージ先のブランチ（base_branch）の上ではない。ステージした変更がある
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require git jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

message_file="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --message-file)
      need_value "$@"
      message_file="$2"
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$message_file" ] || dw_die "--message-file は必須です" 64
if [ "$message_file" = - ]; then
  message="$(cat)"
else
  [ -f "$message_file" ] || dw_die "メッセージのファイルがありません: $message_file" 64
  message="$(cat "$message_file")"
fi

dw_repo_root >/dev/null || dw_die "リポジトリの中で実行してください" 64
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"

# --- メッセージの検証 -----------------------------------------------------------
# 1行目だけを読むのに head を使わない（長いメッセージで、head が先に終わると printf が SIGPIPE で終わり、pipefail で止まるため）
subject="$(printf '%s\n' "$message" | sed -n 1p)"
[ -n "$subject" ] || dw_die "コミットメッセージの1行目（要約）が空です" 2
# 2行目は空行（1行目が要約、3行目から本文）
second="$(printf '%s\n' "$message" | sed -n 2p)"
[ -z "$second" ] || dw_die "1行目（要約）の次は空行にしてください" 2

# commit.pattern が文字列でない・正規表現として正しくないときは、設定の誤りとして止まる（dw_config_regex_test）
dw_config_regex_test "$config" commit.pattern "$subject" \
  || dw_die "1行目が規約に合いません（<type>(<scope>): <要約>。type は $(jq -r '.commit.types | join(" / ")' <<<"$config")）: $subject" 2

if [ "$(jq -r '.commit.scope_required' <<<"$config")" = true ]; then
  jq -e --arg s "$subject" '$s | test("^[a-z]+\\([^)]+\\)")' <<<null >/dev/null \
    || dw_die "スコープが必要です（<type>(<scope>): <要約>）: $subject" 2
fi

if printf '%s\n' "$message" | grep -qiE '^refs:?[[:space:]]'; then
  dw_die "Refs は付けないでください（Issue との紐付けは PR の Closes #N で行います）" 2
fi

# --- ブランチと変更の確認 -------------------------------------------------------
branch="$(git symbolic-ref --short -q HEAD || true)"
[ -n "$branch" ] || dw_die "ブランチの上にいません（detached HEAD）" 2
base="$(dw_base_branch "$config")"
[ "$branch" != "$base" ] || dw_die "${base} の上ではコミットしません。作業用のブランチを作ってください（task-start）" 2
git diff --cached --quiet && dw_die "ステージした変更がありません（git add してください）" 2

if $dry_run; then
  jq -n --arg b "$branch" --arg s "$subject" '{dry_run: true, branch: $b, subject: $s, sha: null}'
  exit 0
fi

printf '%s\n' "$message" | git commit -q -F - || dw_die "コミットできませんでした"
jq -n --arg b "$branch" --arg s "$subject" --arg sha "$(git rev-parse HEAD)" \
  '{dry_run: false, branch: $b, subject: $s, sha: $sha}'
