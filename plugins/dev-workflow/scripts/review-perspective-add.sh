#!/usr/bin/env bash
# レビューの観点ファイルを1つ作り、JSON で出力する。本文（レビューの指示）は標準入力から読む。
#
# 使い方: review-perspective-add.sh --name <名前> --layer user|repo --title <title> [--override] <本文
#
#   --name      観点の名前（ファイル名から .md を除いたもの）。小文字の英数字と - だけ
#   --layer     置く層。user は ~/.claude/review/、repo は <repo>/.claude/review/
#   --title     一覧に出す1行の説明
#   --override  ほかの層にある同じ名前の観点を、作る観点で置き換えてよい
#
# 同じ層に同じ名前のファイルがあれば、上書きせずに終了コード 3 で止まる。
# ほかの層に同じ名前のファイルがあれば、--override が無いかぎり何も作らずに終了コード 4 で止まる。
# 観点ファイルの形式は review-perspectives.sh --help を参照。
#
# 出力:
#   name・layer・path  作った観点
#   overrides          作った観点で置き換えた下位の層のファイル
#   shadowed_by        作った観点より優先される上位の層のファイル（あればこの観点は使われない）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

name=""
layer=""
title=""
override=false
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --name | --layer | --title)
      [ $# -ge 2 ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --name) name="$2" ;;
        --layer) layer="$2" ;;
        --title) title="$2" ;;
      esac
      shift 2
      ;;
    --override) override=true; shift ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

# grep は行ごとに見るので、改行を含む名前は先に弾く
case "$name" in
  *"
"*) dw_die "観点の名前は小文字の英数字と - だけにしてください" 64 ;;
esac
printf '%s' "$name" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
  || dw_die "観点の名前は小文字の英数字と - だけにしてください: ${name}" 64
case "$title" in
  *"
"*) dw_die "title は1行にしてください" 64 ;;
esac
title="$(printf '%s' "$title" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$title" ] || dw_die "--title がありません" 64

repo_root="$(dw_repo_root || true)"
user_dir="$(dw_user_review_dir)"
repo_dir=""
[ -z "$repo_root" ] || repo_dir="$repo_root/.claude/review"
case "$layer" in
  user) dir="$user_dir" ;;
  repo)
    [ -n "$repo_dir" ] || dw_die "git のリポジトリの中ではないので、repo の層には置けません" 2
    dir="$repo_dir"
    ;;
  *) dw_die "--layer は user か repo にしてください" 64 ;;
esac
path="$dir/$name.md"

body="$(cat)"
printf '%s' "$body" | grep -q '[^[:space:]]' || dw_die "本文（レビューの指示）が標準入力にありません" 64

[ ! -e "$path" ] || dw_die "同じ名前の観点が既にあるので上書きしません: ${path}" 3

# 優先度の低い層から順に、同じ名前のファイルを探す
overrides='[]'
shadowed='[]'
below=true
for d in "$DW_PLUGIN_ROOT/review" "$user_dir" "$repo_dir"; do
  [ -n "$d" ] || continue
  if [ "$d" = "$dir" ]; then
    below=false
    continue
  fi
  [ -e "$d/$name.md" ] || continue
  if [ "$override" = false ]; then
    dw_die "ほかの層に同じ名前の観点があります（置き換えるなら --override）: $d/$name.md" 4
  fi
  if [ "$below" = true ]; then
    overrides="$(jq -c --arg p "$d/$name.md" '. + [$p]' <<<"$overrides")"
  else
    shadowed="$(jq -c --arg p "$d/$name.md" '. + [$p]' <<<"$shadowed")"
  fi
done

mkdir -p "$dir"
# 確かめた後に別の処理が作ったファイルも上書きしないよう、noclobber で書く
if ! (set -C; printf -- '---\ntitle: %s\n---\n\n%s\n' "$title" "$body" >"$path") 2>/dev/null; then
  dw_die "観点ファイルを作れません（既にあるか、書き込めません）: ${path}" 3
fi

jq -n --arg n "$name" --arg l "$layer" --arg p "$path" --argjson o "$overrides" --argjson s "$shadowed" \
  '{name: $n, layer: $l, path: $p, overrides: $o, shadowed_by: $s}'
