#!/usr/bin/env bash
# ADR の置き場所（設定の adr.dir）にある ADR を一覧にし、JSON で出力する。
# task-create・pr-create が、ADR の作成を提案する前に、その Issue の ADR が既にあるかを確かめるのに使う。
#
# 使い方: adr-list.sh [--issue N]
#
#   --issue N  front matter の issue が N の ADR だけを出す（#N でもよい。先頭の 0 はそろえる）
#
# 置き場所の直下の *.md を読み、ファイル名の順（ロケールに左右されない文字の順）に出す（下のディレクトリは読まない）。置き場所が無ければ、ADR は無いものとする。
# front matter（先頭の --- から次の --- まで）の issue・status と、最初の「# 」の見出しを読む。行末の CR と先頭の BOM は外して読む。
# issue は数字だけ（前後の引用符・# と先頭の 0 は外す）なら番号、それ以外（無い・テンプレートのまま）は null。
#
# 出力:
#   dir      ADR の置き場所（adr.dir。リポジトリのルートからの相対パス）
#   suggest  設定の adr.suggest（task-create・pr-create で ADR の作成を提案するか。既定 true）
#   issue    --issue の番号（無ければ null）
#   adrs     ADR の一覧。path（リポジトリのルートからの相対パス）・issue・status・title（無ければ null）
#
# 終了コード: 64 引数の誤り / 2 リポジトリの外、設定を読めない、adr.dir・adr.suggest の値の誤り
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

issue=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --issue)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      issue="$(dw_issue_number --issue "$2")"
      shift 2
      ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

repo_root="$(dw_repo_root || true)"
[ -n "$repo_root" ] || dw_die "git のリポジトリの中ではありません" 2
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")" || dw_die "設定を読めません（config.sh で確かめてください）" 2
adr_dir="$(dw_adr_dir "$config")"
# 書いていない（null を含む）なら提案する。true・false 以外は、提案するかを決められないので止める。
# false を既定値に置き換えないよう、// は使わない
suggest="$(jq -c '[.adr.suggest?][0] | if . == null then true else . end' <<<"$config")"
case "$suggest" in
  true | false) ;;
  *) dw_die "adr.suggest は true か false にしてください: ${suggest}" 2 ;;
esac

# ADR ごとに「パス<TAB>issue<TAB>status<TAB>title」の1行にし、最後に1回の jq でまとめる。
# ADR が多くても遅くならないよう、awk は全部のファイルに1回だけ起動する。awk は中身の無いファイルを1行も読まないので、
# そのファイルは、ファイルの一覧（files）から、値の無い ADR として補う
files="" rows=""
if [ -d "$repo_root/$adr_dir" ]; then
  # awk にはリポジトリのルートからの相対パスで渡し、出力のパスをそのまま使う
  set --
  for f in "$repo_root/$adr_dir"/*.md; do
    [ -f "$f" ] && set -- "$@" "${f#"$repo_root"/}"
  done
  if [ $# -gt 0 ]; then
    files="$(printf '%s\n' "$@")"
    rows="$(cd "$repo_root" && awk "$DW_AWK_STRIP_CR_BOM"'
      function clean(v) {
        sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t\r]+$/, "", v)
        if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
        gsub(/\t/, " ", v)
        return v
      }
      function flush() { if (cur != "") printf "%s\t%s\t%s\t%s\n", cur, i, s, t }
      FNR == 1 { flush(); cur = FILENAME; i = s = t = ""; fm = 0; done = 0 }
      done { next }
      FNR == 1 && $0 == "---" { fm = 1; next }
      fm && $0 == "---" { fm = 0; next }
      fm && /^issue:/ && i == "" { i = clean($0); next }
      fm && /^status:/ && s == "" { s = clean($0); next }
      !fm && /^# / { t = substr($0, 3); sub(/[ \t\r]+$/, "", t); gsub(/\t/, " ", t); done = 1; next }
      END { flush() }' "$@")"
  fi
fi

# shellcheck disable=SC2016 # jq の変数を bash に展開させない
printf '%s' "$rows" | jq -R -s --arg files "$files" --arg dir "$adr_dir" --argjson suggest "$suggest" --arg want "$issue" '
  def nz: if . == "" then null else . end;
  # issue の値は、前後の # と先頭の 0 を外して、数字だけなら番号にする
  def num: ltrimstr("#") | if test("^[0-9]+$") and test("[1-9]") then tonumber else null end;
  (reduce (split("\n")[] | select(. != "") | split("\t")) as $r ({}; .[$r[0]] = $r)) as $rows
  | [$files | split("\n")[] | select(. != "") | . as $p | ($rows[$p] // [$p])
    | {path: $p, issue: (.[1] // "" | num), status: (.[2] // "" | nz), title: (.[3] // "" | nz)}]
  # glob の並びはロケールで変わるので、文字の順に並べ直す
  | sort_by(.path)
  | (if $want == "" then null else ($want | tonumber) end) as $n
  | {dir: $dir, suggest: $suggest, issue: $n,
     adrs: (if $n == null then . else map(select(.issue == $n)) end)}'
