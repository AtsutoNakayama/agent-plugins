#!/usr/bin/env bash
# レビューの観点ファイルを3つの層から集め、JSON で出力する。
# --base と --target を渡すと、観点ごとの実行する条件で、今の変更に当てはまらない観点を外す。
#
# 使い方: review-perspectives.sh [--base <基点> --target <マージ先> [--type <type>] [--issue <番号>]]
#
#   --base    基点のコミット（git merge-base origin/<base_branch> HEAD）。差分のファイルは git diff <基点> で読む
#   --target  マージ先の ref（例: origin/main）。base_ahead の条件で、基点より進んでいるかを見る
#   --type    変更の type（Issue の type ラベル。Issue が無ければブランチ名の type）。分からなければ省く
#   --issue   作業中の Issue の番号。Issue が無ければ省く（issue: required の観点を外す）
#
# 層（下ほど優先。同じ名前の観点は上位の層のファイルが使われる）:
#   3. プラグインに同梱する共通の観点   review/*.md
#   2. ユーザーの観点                   ~/.claude/dev-workflow/review/*.md
#   1. リポジトリの観点                 <repo>/.claude/dev-workflow/review/*.md
#
# 観点ファイルの形式（1ファイルに1観点）:
#   ---
#   title: 一覧に出す1行の説明（必須）
#   enabled: false            （任意。下位の層にある同じ名前の観点を止める）
#   builtin: code-review      （任意。本文の代わりに、組み込みの /code-review を実行する）
#   types: [fix, perf]        （任意。変更の type がこのどれかのときだけ実行する）
#   paths: ["*.sh", "docs/*"] （任意。差分のファイルがこのパターンのどれかに当たるときだけ実行する）
#   issue: required           （任意。Issue があるときだけ実行する）
#   base_ahead: required      （任意。マージ先が基点より進んでいる（ブランチを作った後に
#                               コミットが入った）ときだけ実行する）
#   ---
#   本文：サブエージェントへのレビューの指示（何を確かめ、どう指摘するか）
#
#   - 観点の名前はファイル名（.md を除く）。小文字の英数字と - だけ
#   - enabled: false のときは本文を省いてよい。builtin を書いたときも本文を省いてよい
#   - 条件（types・paths・issue・base_ahead）を書かなければ毎回実行する。複数書けば、すべてに当てはまるときだけ実行する
#   - types・paths は [a, b] の形か、1つだけの値で書く。paths のパターンはリポジトリからの相対パスに当て、
#     * は / も含めて任意の文字列に当たる（例: "*.sh" はどのディレクトリの .sh にも当たる）
#   - --type を渡さなければ（type が分からなければ）、types の条件では外さない
#   - 条件は観点ファイルごとに書く。上位の層で同じ名前の観点を置くと、条件も上位の層のファイルのものになる
#
# 出力:
#   perspectives  使う観点（名前の順）。name・title・layer・path・builtin（無ければ null）・
#                 overrides（上書きした下位の層のパス）
#   skipped       条件に当てはまらないので外した観点。name・layer・path・reason（外した理由）
#   disabled      enabled: false で止めた観点。name・layer・path・overrides
#   invalid       形式の誤りで使わないファイル。path・reason・overrides（標準エラーにも warn を出す）
#                 ファイル名が正しければ、下位の層にある同じ名前の観点も使わない（止めるつもりの書き間違いで動かさない）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

base="" target="" type="" issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --base | --target | --type | --issue)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --base) base="$2" ;;
        --target) target="$2" ;;
        --type) type="$2" ;;
        --issue) issue="$2" ;;
      esac
      shift 2
      ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

# 条件で絞り込むのは --base を渡したときだけ（--type・--issue が無いことを「type も Issue も無い」と読むため）
filter=false
if [ -n "$base" ] || [ -n "$target" ] || [ -n "$type" ] || [ -n "$issue" ]; then
  [ -n "$base" ] && [ -n "$target" ] || dw_die "条件で絞り込むには --base と --target の両方を渡してください" 64
  case "$issue" in
    "" | *[!0-9]*) [ -z "$issue" ] || dw_die "--issue は Issue の番号にしてください: ${issue}" 64 ;;
  esac
  git rev-parse --verify --quiet "$base^{commit}" >/dev/null || dw_die "基点のコミットが見つかりません: ${base}" 2
  git rev-parse --verify --quiet "$target^{commit}" >/dev/null || dw_die "マージ先が見つかりません: ${target}" 2
  filter=true
fi

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

# frontmatter の値を一覧として読み、1行に1つ出力する。[a, b] の形と、1つだけの値を受け付ける
fm_list() {
  local v="$1"
  case "$v" in
    \[*\]) v="${v#\[}" v="${v%\]}" ;;
  esac
  printf '%s\n' "$v" | tr ',' '\n' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/" \
    | grep -v '^$' || true
}

# 1行に1つの値を JSON の配列にする
lines_json() { jq -Rsc 'split("\n") | map(select(. != ""))'; }

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

# frontmatter から実行する条件を読み、{types, paths, issue, base_ahead} の JSON を出力する。
# types・paths は書かなければ null。形式が誤っていれば、理由を出力して失敗する
conditions() {
  local fm="$1" v types=null paths=null issue_req=false ahead_req=false t
  if printf '%s\n' "$fm" | grep -q '^types:'; then
    v="$(fm_list "$(fm_value "$fm" types)")"
    if [ -z "$v" ]; then echo "types に type がありません"; return 1; fi
    while IFS= read -r t; do
      printf '%s' "$t" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
        || { echo "types は type の名前（小文字の英数字と -）の一覧にしてください"; return 1; }
    done <<<"$v"
    types="$(lines_json <<<"$v")"
  fi
  if printf '%s\n' "$fm" | grep -q '^paths:'; then
    v="$(fm_list "$(fm_value "$fm" paths)")"
    if [ -z "$v" ]; then echo "paths にパターンがありません"; return 1; fi
    paths="$(lines_json <<<"$v")"
  fi
  case "$(fm_value "$fm" issue)" in
    "") ;;
    required) issue_req=true ;;
    *) echo "issue は required にしてください"; return 1 ;;
  esac
  case "$(fm_value "$fm" base_ahead)" in
    "") ;;
    required) ahead_req=true ;;
    *) echo "base_ahead は required にしてください"; return 1 ;;
  esac
  jq -nc --argjson t "$types" --argjson p "$paths" --argjson i "$issue_req" --argjson a "$ahead_req" \
    '{types: $t, paths: $p, issue: $i, base_ahead: $a}'
}

# 使い方: collect <層の名前> <ディレクトリ>
collect() {
  local layer="$1" dir="$2" f name fm title enabled builtin when
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
    builtin="$(fm_value "$fm" builtin)"
    case "$builtin" in
      "" | code-review) ;;
      *) add_invalid "$f" "builtin は code-review にしてください" "$layer" "$name"; continue ;;
    esac
    if ! when="$(conditions "$fm")"; then
      add_invalid "$f" "$when" "$layer" "$name"
      continue
    fi
    if [ "$enabled" = true ]; then
      if [ -z "$title" ]; then
        add_invalid "$f" "title がありません" "$layer" "$name"
        continue
      fi
      if [ -z "$builtin" ] && [ "$(body_lines "$f")" -eq 0 ]; then
        add_invalid "$f" "本文（レビューの指示）がありません" "$layer" "$name"
        continue
      fi
    fi
    records="$(jq -c --arg n "$name" --arg t "$title" --argjson e "$enabled" --arg l "$layer" --arg p "$f" \
      --arg b "$builtin" --argjson w "$when" \
      '. + [{name: $n, title: $t, enabled: $e, layer: $l, path: $p,
        builtin: (if $b == "" then null else $b end), when: $w}]' <<<"$records")"
  done
}

collect plugin "$DW_PLUGIN_ROOT/review"
collect user "$(dw_user_review_dir)"
[ -z "$repo_root" ] || collect repo "$repo_root/.claude/dev-workflow/review"

# 優先度の低い層から順に入れ、同じ名前は後の層で置き換える
result="$(jq -n --argjson r "$records" --argjson inv "$invalid" '
  (reduce $r[] as $x ({};
    .[$x.name] as $prev
    | .[$x.name] = ($x + {overrides: (if $prev then $prev.overrides + [$prev.path] else [] end)})))
  | [.[]] | sort_by(.name) as $all
  | ([$all[] | select(.invalid) | {key: .path, value: .overrides}] | from_entries) as $shadow
  | {
      perspectives: [$all[] | select(.enabled) | {name, title, layer, path, builtin, overrides, when}],
      disabled: [$all[] | select((.enabled | not) and (.invalid | not)) | {name, layer, path, overrides}],
      invalid: [$inv[] | . + {overrides: ($shadow[.path] // [])}]
    }')"

# 形式の誤ったファイルに隠れて使わなくなった下位の層の観点を知らせる
jq -r '.invalid[] | select(.overrides != []) | .path | split("/") | last | rtrimstr(".md")' <<<"$result" \
  | while IFS= read -r name; do
    dw_warn "形式の誤ったファイルがあるので、同じ名前の下位の層の観点も使いません: $name"
  done
# 条件に当てはまらない理由を出力する。当てはまれば何も出力しない
# 使い方: skip_reason <条件の JSON>
skip_reason() {
  local when="$1" list pat f hit=false
  if [ "$(jq -r .issue <<<"$when")" = true ] && [ -z "$issue" ]; then
    echo "Issue が無い（issue: required）"
    return
  fi
  list="$(jq -r '.types // empty | .[]' <<<"$when")"
  # type が分からなければ、types の条件では外さない
  if [ -n "$list" ] && [ -n "$type" ] && ! printf '%s\n' "$list" | grep -Fxq -- "$type"; then
    echo "type（${type}）が types（$(jq -r '.types | join("、")' <<<"$when")）のどれでもない"
    return
  fi
  list="$(jq -r '.paths // empty | .[]' <<<"$when")"
  if [ -n "$list" ]; then
    while IFS= read -r pat; do
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        # パターンとして当てるので、$pat は引用符で囲まない
        # shellcheck disable=SC2254
        case "$f" in $pat) hit=true; break 2 ;; esac
      done <<<"$changed"
    done <<<"$list"
    if [ "$hit" = false ]; then
      echo "差分のファイルが paths（$(jq -r '.paths | join("、")' <<<"$when")）のどれにも当たらない"
      return
    fi
  fi
  if [ "$(jq -r .base_ahead <<<"$when")" = true ] && [ "$ahead" -eq 0 ]; then
    echo "マージ先（${target}）が基点より進んでいない（base_ahead: required）"
  fi
}

skipped='[]'
if [ "$filter" = true ]; then
  # 名前を変えたファイルは、元の名前と新しい名前の両方を差分のファイルとみなす
  # 日本語などのファイル名を "docs/\350..." のように引用符で囲まずに出させる（囲むとパターンに当たらない）
  changed="$(git -c core.quotePath=false diff --name-only --no-renames "$base")" || dw_die "差分のファイルを読めません: git diff ${base}"
  ahead="$(git rev-list --count "$base..$target")" || dw_die "マージ先の進み具合を読めません: ${base}..${target}"
  kept='[]'
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    reason="$(skip_reason "$(jq -c .when <<<"$p")")"
    if [ -n "$reason" ]; then
      skipped="$(jq -c --argjson p "$p" --arg r "$reason" '. + [$p | {name, layer, path, reason: $r}]' <<<"$skipped")"
    else
      kept="$(jq -c --argjson p "$p" '. + [$p]' <<<"$kept")"
    fi
  done < <(jq -c '.perspectives[]' <<<"$result")
  result="$(jq -c --argjson k "$kept" '.perspectives = $k' <<<"$result")"
fi

jq --argjson s "$skipped" '{perspectives: [.perspectives[] | del(.when)], skipped: $s, disabled, invalid}' <<<"$result"
