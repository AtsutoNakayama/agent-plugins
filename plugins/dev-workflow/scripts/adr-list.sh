#!/usr/bin/env bash
# ADR の置き場所（設定の adr.dir）にある ADR を一覧にし、JSON で出力する。
# task-create・pr-create が、ADR の作成を提案するかを決めるのに使う。
#
# 使い方: adr-list.sh [--issue N]
#
#   --issue N  front matter の issue が N の ADR だけを出し、その Issue で ADR の作成を提案するか（proposal）も決める
#              （#N でもよい。先頭の 0 はそろえる）
#
# 置き場所の直下の *.md を読み、ファイル名の順（ロケールに左右されない文字の順）に出す（下のディレクトリは読まない）。置き場所が無ければ、ADR は無いものとする。
# front matter（先頭の --- から次の --- まで）の issue・status と、最初の「# 」の見出しを読む。行末の CR と先頭の BOM は外して読む。
# 見出しと補足は、front matter の後の本文を、Issue の本文と同じ md_scan（lib/common.sh）で読み、コードブロックの中と
# 複数行の HTML のコメントの中の行は除く（コードブロックの中の「# 」の行は見出しにしない）。
# 「補足」の節（見出しが「## 補足」か、MADR の元の「## More Information」の節。閉じの # と大文字・小文字の違いは問わない。
# 次の「# 」か「## 」の見出しまで）からは、インラインのリンク [文](先) の先と、参照形式のリンクの定義 [ref]: 先 の先を読み、
# リンクしている ADR を求める。画像のリンク ![文](先)、行の中の HTML のコメントとインラインのコードの中のリンクは数えない。
# リンクの先は、その ADR のファイルからの相対パス（/ で始まればリポジトリのルートからのパス）として解き、#・? からの後ろは
# 外す。URL（https: など）と、置き場所の直下の ADR でない先と、自分へのリンクは数えない。パスは . と .. と重なった / を
# 解いて比べる（adr.dir が ./docs/adr のようでも当たる）。
# 値は YAML の1行として読む（空白の後の # からのコメントを外し、囲む引用符を外してエスケープを元の文字に戻す）。
# issue は数字だけ（先頭の # と 0 は外す）なら番号、それ以外（無い・テンプレートのまま）は null。# を付けるなら、引用符で
# 囲む（"#151"）。囲まない #151 は、YAML のとおりコメントなので、値なし（null）になる。
#
# 出力:
#   dir      ADR の置き場所（adr.dir。リポジトリのルートからの相対パス）
#   suggest  設定の adr.suggest（task-create・pr-create で ADR の作成を提案するか。既定 true）
#   issue    --issue の番号（無ければ null）
#   adrs     ADR の一覧。path（リポジトリのルートからの相対パス）・issue・status・title（無ければ null）・
#              cited_in_supplements（ほかの ADR のうち、「補足」の節からこの ADR にリンクしているもののパスの一覧。
#              無ければ []。ファイル名の順）。過去の判断を一部だけ変える ADR は、その関係を自分の「補足」に書き、
#              変えられる側には何も書かないので、その逆引きにする。補足でリンクしているだけで、変えているとは限らない
#              （「これは変えない」と参照しているだけのこともある）ので、変えているかは、その ADR の補足を読んで確かめる。
#              --issue で絞っても、逆引きは置き場所の全部の ADR から作る
#   proposal --issue のとき、その Issue で ADR の作成を提案するか（--issue が無ければ null）。上から順に決める
#              disabled  adr.suggest が false。提案しない
#              exists    その Issue の ADR がある（adrs が空でない）。提案しない
#              pending   Issue のチェックリストに、取り消し線もチェックも無い ADR の項目がある。提案ではなく、
#                        ADR の項目が残っていて ADR がまだ無いことを伝える
#              done      ADR の項目にチェックがある（ほかの置き場所に残したなど）。提案しない
#              declined  ADR の項目が取り消した項目（「ADR に残す」が、閉じた取り消し線（~~ か ~）の内側にだけある）だけ。
#                        提案を断った記録なので、提案しない
#              judge     ADR の項目が無い。AI が差分から、ADR にすべき判断があるかを判断する
#            ADR の項目は、Issue の本文のチェックリストの項目（md_scan）のうち、文に「ADR に残す」を含むもの
#            （「ADR」と「に残す」の間の空白は、無くても全角でもよい。task-create・pr-create が足す形。
#            ADR を話題にしているだけの項目は含めない）。
#            Issue の本文を gh で読むのは、pending・done・declined・judge を決めるときだけ
#   adr_tasks proposal を決めるのに読んだ ADR の項目（checked・text）。Issue を読まなかったときは null
#
# 終了コード: 64 引数の誤り / 2 リポジトリの外、設定を読めない、adr.dir・adr.suggest の値の誤り /
#             Issue を読むとき（proposal が disabled・exists でないとき）だけ、--issue が PR の番号か無い番号なら 2、
#             Issue を読めなければ（通信・認証など）1
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
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

# ADR ごとに「A<TAB>パス<TAB>issue<TAB>status」の1行と、front matter の後の本文の行ごとに「B<TAB>パス<TAB>行」の1行にし、
# 最後に1回の jq でまとめる（見出しと補足は、jq で本文を md_scan に通して読む）。ADR が多くても遅くならないよう、awk は全部の
# ファイルに1回だけ起動する。awk は中身の無いファイルを1行も読まないので、そのファイルは、ファイルの一覧（files）から、値の無い
# ADR として補う
files="" rows=""
if [ -d "$repo_root/$adr_dir" ]; then
  # awk にはリポジトリのルートからの相対パスで渡し、出力のパスをそのまま使う
  set --
  for f in "$repo_root/$adr_dir"/*.md; do
    [ -f "$f" ] && set -- "$@" "${f#"$repo_root"/}"
  done
  if [ $# -gt 0 ]; then
    files="$(printf '%s\n' "$@")"
    rows="$(CDPATH='' cd "$repo_root" && awk "$DW_AWK_STRIP_CR_BOM$DW_AWK_YAML"'
      # YAML の1行の値を読む（strip・unquote は DW_AWK_YAML。merge-group-check.sh と同じ読み方）
      function clean(v) {
        sub(/^[^:]*:/, "", v)
        v = unquote(strip(v))
        gsub(/\t/, " ", v)
        return v
      }
      function flush() { if (cur != "") printf "A\t%s\t%s\t%s\n", cur, i, s }
      FNR == 1 { flush(); cur = FILENAME; i = s = ""; fm = 0 }
      FNR == 1 && $0 == "---" { fm = 1; next }
      fm && $0 == "---" { fm = 0; next }
      fm && /^issue:/ && i == "" { i = clean($0); next }
      fm && /^status:/ && s == "" { s = clean($0); next }
      fm { next }
      { printf "B\t%s\t%s\n", cur, $0 }
      END { flush() }' "$@")"
  fi
fi

# 1行目に、Issue を読まずに決まる proposal（読む必要があれば read、--issue が無ければ -）を、2行目からに出力の JSON を出す。
# ファイルの一覧と行（rows）は ADR が多いと長くなるので、引数ではなく一時ファイルにして --rawfile で渡す（引数1つの長さには
# 上限がある。標準入力の -R では、4096 バイトを超える1行（長い見出しなど）の BMP の外の文字が読み込みの区切りで割れることがある）
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
printf '%s' "$files" >"$tmp_dir/files"
printf '%s' "$rows" >"$tmp_dir/rows"
# shellcheck disable=SC2016 # jq の変数を bash に展開させない
res="$(jq -n -r --rawfile files "$tmp_dir/files" --rawfile row_lines "$tmp_dir/rows" \
  --arg dir "$adr_dir" --argjson suggest "$suggest" --arg want "$issue" "$DW_JQ_MD_SCAN"'
  def nz: if . == "" then null else . end;
  # issue の値は、先頭の #（引用符で囲んだ "#151" のときだけ残っている）と先頭の 0 を外して、数字だけなら番号にする
  def num: ltrimstr("#") | if test("^[0-9]+$") and test("[1-9]") then tonumber else null end;
  # パスの . と .. を解く（.. で上に出すぎたら null）
  def normpath: reduce (split("/")[] | select(. != "" and . != ".")) as $x ([];
      if . == null then null elif $x == ".." then (if length > 0 then .[:-1] else null end) else . + [$x] end)
    | if . == null then null else join("/") end;
  # 補足の節の見出し（「## 補足」か、MADR の元の「## More Information」。閉じの # と、大文字・小文字の違いも許す）と、節の終わり
  # （次の「# 」か「## 」の見出し）
  def sup_head: test("^ {0,3}##[ \t]+(補足|more information)([ \t]+#+)?[ \t]*$"; "i");
  def sup_end: test("^ {0,3}#{1,2}(\\s|$)");
  # 行から、インラインのリンク [文](先)（画像 ![文](先) は除く）の先と、参照形式のリンクの定義 [ref]: 先 の先を出す。
  # 行の中の HTML のコメントとインラインのコードの中は読まない
  def link_targets:
    gsub("<!--.*?-->"; "") | gsub("(?<b>`+).*?\\k<b>"; "")
    | ((capture("^ {0,3}\\[[^\\]]+\\]:[ \t]*(?:<(?<a>[^>]*)>|(?<b>[^ \t]+))") | .a // .b // ""),
       (capture("(?<!!)\\[[^\\]]*\\]\\([ \t]*(?:<(?<a>[^>]*)>|(?<b>[^)\\s]*))[^)]*\\)"; "g") | .a // .b // ""))
    | sub("[#?].*$"; "") | select(. != "");
  [$row_lines | split("\n")[] | select(. != "") | split("\t")] as $lines
  | (reduce ($lines[] | select(.[0] == "A")) as $r ({}; .[$r[1]] = $r[1:])) as $rows
  # 本文の行を ADR ごとにまとめ、md_scan で GitHub に表示される行（コードブロックと複数行の HTML のコメントを除く）にする
  | (reduce ($lines[] | select(.[0] == "B")) as $r ({}; .[$r[1]] += [$r[2:] | join("\t")])
     | map_values(join("\n") | md_scan | .lines | map(.text))) as $bodies
  # 補足のリンクの先を、リンクしている ADR のファイルからの相対パスとして、リポジトリのルートからのパスに解き、
  # 先（正規化したパス）ごとに、リンクしている ADR をまとめる
  | (reduce ($bodies | to_entries[] | .key as $from
        | foreach .value[] as $l ({sup: false};
            if $l | sup_head then {sup: true, l: null} elif $l | sup_end then {sup: false, l: null}
            else .l = (if .sup then $l else null end) end;
            .l // empty)
        | link_targets
        | select(test("^[A-Za-z][A-Za-z0-9+.-]*:") | not)
        | (if startswith("/") then . else ($from | sub("[^/]*$"; "")) + . end | normpath) as $to
        | select($to != null and $to != ($from | normpath))
        | {from: $from, to: $to}) as $k ({}; .[$k.to] += [$k.from])) as $cited
  | [$files | split("\n")[] | select(. != "") | . as $p | ($rows[$p] // [$p])
    | {path: $p, issue: (.[1] // "" | num), status: (.[2] // "" | nz),
       # 最初の「# 」の行を見出しにする（コードブロックの中の「# 」の行は見出しにしない）
       title: (first($bodies[$p][]? | select(startswith("# ")) | .[2:] | sub("[ \t]+$"; "") | gsub("\t"; " ")) // null),
       cited_in_supplements: ($cited[$p | normpath] // [] | unique)}]
  # glob の並びはロケールで変わるので、文字の順に並べ直す
  | sort_by(.path)
  | (if $want == "" then null else ($want | tonumber) end) as $n
  | (if $n == null then . else map(select(.issue == $n)) end) as $adrs
  # 提案するかは、状態の組み合わせだけで決まるので、ここで決める（AI が判断するのは judge のときの差分だけ）
  | (if $n == null then null elif $suggest == false then "disabled" elif ($adrs | length) > 0 then "exists" else "read" end) as $p
  | ($p // "-"),
    {dir: $dir, suggest: $suggest, issue: $n, adrs: $adrs,
     proposal: (if $p == "read" then null else $p end), adr_tasks: null}')"
nl='
'
state="${res%%"$nl"*}" out="${res#*"$nl"}"
if [ "$state" != read ]; then
  printf '%s\n' "$out"
  exit 0
fi
# Issue のチェックリストの ADR の項目から、pending・done・declined・judge を決める。
# Issue を読めなければ、dw_read_issue がここで止める。Issue の JSON（本文を含む）は大きいことがあるので、
# 引数ではなく標準入力で渡す（引数1つの長さには上限がある）
issue_json="$(dw_read_issue "$issue" body)"
jq --argjson out "$out" "$DW_JQ_MD_SCAN"'
  # \s は全角の空白にも当たる
  def adr_item: test("ADR\\s*に残す");
  # 「ADR に残す」が、閉じた取り消し線（GitHub と同じく ~~ か ~ で囲む）の内側にだけあれば、取り消した項目（断った記録）とみなす
  def struck: [.text | splits("~~?")] as $p
    | ([range(1; ($p | length) - 1; 2) | $p[.]] | any(adr_item))
      and ([range(0; $p | length) | select(. % 2 == 0 or . == ($p | length) - 1) | $p[.]] | any(adr_item) | not);
  (.body // "" | md_scan | .items | map(select(.text | adr_item) | {checked, text})) as $t
  | $out
  | .adr_tasks = $t
  | .proposal = (
      if any($t[]; (struck | not) and (.checked | not)) then "pending"
      elif any($t[]; (struck | not) and .checked) then "done"
      elif ($t | length) > 0 then "declined"
      else "judge" end)' <<<"$issue_json"
