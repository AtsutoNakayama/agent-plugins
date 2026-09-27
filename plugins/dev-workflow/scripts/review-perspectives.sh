#!/usr/bin/env bash
# レビューの観点ファイルを3つの層から集め、JSON で出力する。
#
# 使い方: review-perspectives.sh
#
# 層（下ほど優先。同じ名前の観点は上位の層のファイルが使われる）:
#   3. プラグインに同梱する共通の観点   review/*.md
#   2. ユーザーの観点                   ~/.claude/review/*.md
#   1. リポジトリの観点                 <repo>/.claude/review/*.md
#
# 観点ファイルの形式（1ファイルに1観点）:
#   ---
#   title: 一覧に出す1行の説明（必須）
#   enabled: false        （任意。下位の層にある同じ名前の観点を止める）
#   ---
#   本文：サブエージェントへのレビューの指示（何を確かめ、どう指摘するか）
#
#   - 観点の名前はファイル名（.md を除く）。小文字の英数字と - だけ
#   - enabled: false のときは本文を省いてよい
#
# 出力:
#   perspectives  使う観点（名前の順）。name・title・layer・path・overrides（上書きした下位の層のパス）
#   disabled      enabled: false で止めた観点。name・layer・path・overrides
#   invalid       形式の誤りで使わないファイル。path・reason・overrides（標準エラーにも warn を出す）
#                 ファイル名が正しければ、下位の層にある同じ名前の観点も使わない（止めるつもりの書き間違いで動かさない）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

repo_root="$(dw_repo_root || true)"

# 先頭の --- で囲まれた部分を出力する。閉じる --- が無ければ失敗する
# 行末の CR と、先頭の BOM（Windows のエディタが付ける）は取り除く
frontmatter() {
  awk '{ sub(/\r$/, "") }
    NR == 1 { sub(/^\357\273\277/, ""); if ($0 != "---") exit 1; on = 1; next }
    $0 == "---" { closed = 1; exit }
    { print }
    END { if (!closed) exit 1 }' "$1"
}

# 閉じる --- より後ろ（本文）のうち、空白でない行の数
body_lines() {
  awk '{ sub(/\r$/, "") } NR == 1 { sub(/^\357\273\277/, "") } n >= 2 && NF { c++ } $0 == "---" && n < 2 { n++ } END { print c + 0 }' "$1"
}

# frontmatter から <キー> の値を取り出す。前後の空白と、囲む引用符を外す
fm_value() {
  printf '%s\n' "$1" | sed -n "s/^$2:[[:space:]]*//p" | head -n 1 \
    | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

records='[]'
invalid='[]'

# 使い方: add_invalid <パス> <理由> [<層の名前> <観点の名前>]
# 観点の名前を渡すと、その名前の観点として並べ、下位の層にある同じ名前の観点を使わないようにする
add_invalid() {
  dw_warn "観点ファイルを使いません（$2）: $1"
  invalid="$(jq -c --arg p "$1" --arg r "$2" '. + [{path: $p, reason: $r}]' <<<"$invalid")"
  [ $# -ge 4 ] || return 0
  records="$(jq -c --arg n "$4" --arg l "$3" --arg p "$1" \
    '. + [{name: $n, title: "", enabled: false, invalid: true, layer: $l, path: $p}]' <<<"$records")"
}

# 使い方: collect <層の名前> <ディレクトリ>
collect() {
  local layer="$1" dir="$2" f name fm title enabled
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .md)"
    if ! printf '%s' "$name" | grep -Eq '^[a-z0-9][a-z0-9-]*$'; then
      add_invalid "$f" "ファイル名は小文字の英数字と - だけにしてください"
      continue
    fi
    if ! fm="$(frontmatter "$f")"; then
      add_invalid "$f" "先頭に --- で囲んだ frontmatter がありません" "$layer" "$name"
      continue
    fi
    enabled="$(fm_value "$fm" enabled)"
    case "$enabled" in
      "" | true) enabled=true ;;
      false) ;;
      *) add_invalid "$f" "enabled は true か false にしてください" "$layer" "$name"; continue ;;
    esac
    title="$(fm_value "$fm" title)"
    if [ "$enabled" = true ]; then
      if [ -z "$title" ]; then
        add_invalid "$f" "title がありません" "$layer" "$name"
        continue
      fi
      if [ "$(body_lines "$f")" -eq 0 ]; then
        add_invalid "$f" "本文（レビューの指示）がありません" "$layer" "$name"
        continue
      fi
    fi
    records="$(jq -c --arg n "$name" --arg t "$title" --argjson e "$enabled" --arg l "$layer" --arg p "$f" \
      '. + [{name: $n, title: $t, enabled: $e, layer: $l, path: $p}]' <<<"$records")"
  done
}

collect plugin "$DW_PLUGIN_ROOT/review"
collect user "$(dw_user_review_dir)"
[ -z "$repo_root" ] || collect repo "$repo_root/.claude/review"

# 優先度の低い層から順に入れ、同じ名前は後の層で置き換える
result="$(jq -n --argjson r "$records" --argjson inv "$invalid" '
  (reduce $r[] as $x ({};
    .[$x.name] as $prev
    | .[$x.name] = ($x + {overrides: (if $prev then $prev.overrides + [$prev.path] else [] end)})))
  | [.[]] | sort_by(.name) as $all
  | ([$all[] | select(.invalid) | {key: .path, value: .overrides}] | from_entries) as $shadow
  | {
      perspectives: [$all[] | select(.enabled) | {name, title, layer, path, overrides}],
      disabled: [$all[] | select((.enabled | not) and (.invalid | not)) | {name, layer, path, overrides}],
      invalid: [$inv[] | . + {overrides: ($shadow[.path] // [])}]
    }')"

# 形式の誤ったファイルに隠れて使わなくなった下位の層の観点を知らせる
jq -r '.invalid[] | select(.overrides != []) | .path | split("/") | last | rtrimstr(".md")' <<<"$result" \
  | while IFS= read -r name; do
    dw_warn "形式の誤ったファイルがあるので、同じ名前の下位の層の観点も使いません: $name"
  done
printf '%s\n' "$result"
