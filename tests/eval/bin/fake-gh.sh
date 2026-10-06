#!/usr/bin/env bash
# claude plugin eval のケースで使う偽の gh（同じディレクトリの gh は、このファイルへのシンボリックリンク。
# 本体は、shellcheck の対象にするため、拡張子の付いたこのファイルにしてある）。GitHub に触れずに、ケースの準備のスクリプト
# （plugins/dev-workflow/evals/lib/scaffold.bash の fake_gh）が作業用のディレクトリに置いた表で答える。
# tests/eval/run.sh が、このディレクトリを PATH の先頭に足す。eval のサンドボックスの中からは、PATH にあるディレクトリしか
# 見えないので、本体も gh と同じディレクトリに置く。
#
# 表と記録は、今のディレクトリから上に辿って最初に見つかる .fake-gh/ に置く（ワークツリーの中で呼ばれても、作業用のリポジトリのものを使う）
#   .fake-gh/routes  1行に1つ「<パターン>\t<応答のファイル>\t<終了コード>」。パターンは bash の case のパターンで、表を引く鍵に当てる。
#                    上から最初に合うものを使う。鍵は、ふつうは引数を空白でつないだ文字列で、次の2つだけ形をそろえる
#                    - gh api graphql：「api graphql <操作名>」
#                    - gh issue view：「issue view <番号> <残りの引数>」（#番号・URL の指定は番号にし、番号を先頭に並べ直す）
#   .fake-gh/calls   呼ばれるたびに、引数を空白でつないだ1行を足す（graphql は「api graphql <操作名> <変数の JSON>」）
#   .fake-gh/writes  GitHub に書き込む呼び出しなら、calls と同じ1行をここにも足す（grader は、これが空かで「書き込まなかった」を確かめる）
# 応答のファイルは .fake-gh/ からの相対パス。終了コードが 0 でなければ、応答を標準エラーに出して、その終了コードで終わる。
# -q / --jq があれば、応答に jq -r で当てる。合うパターンが無ければ、記録してから失敗する（足りない応答に気付けるように）。
#
# 書き込みかどうかは、ここで1か所で決める（ケースごとに正規表現を書くと、スクリプトの実際の呼び方とずれて見逃すため）。
# 読むだけと確かに分かる呼び出しだけを読むだけにし、それ以外（知らない形・読み取れない形）はすべて書き込みとみなす。
# gh の引数の書き方は多いので、知っている形だけを書き込みとして拾うと、知らない形をすり抜けさせてしまうため。
#   gh api（graphql）  引数のどこかに graphql があれば GraphQL。クエリを読めて、それが query（か無名の { … }）のときだけ読むだけ
#   gh api（REST）     -X / --method が GET・HEAD のとき、または指定が無く、本文も無いときだけ読むだけ。
#                      -f…・-F…・--field…・--raw-field…・--input… で始まる引数が1つでもあれば、本文がある（gh は POST で送る）
#   それ以外           最初の2つの語（-R / --repo とその値は飛ばす）が、読むだけのもの（view・list・status・checkout など）のときだけ読むだけ
set -euo pipefail

dir="$PWD"
while [ ! -f "$dir/.fake-gh/routes" ]; do
  [ "$dir" != / ] || { echo "fake gh: .fake-gh/routes が見つかりません（${PWD} から上）" >&2; exit 1; }
  dir="$(dirname "$dir")"
done
base="$dir/.fake-gh"

# --- 1. 引数を読む ---------------------------------------------------------------
# -q / --jq の式と、gh api の -X / --method・本文（-f・-F など）・GraphQL かどうか
q="" method="" has_body=false graphql=false stdin_input=false input_file="" fields=() prev=""
for a in "$@"; do
  case "$prev" in
    -q | --jq) q="$a" ;;
    -X | --method) method="$a" ;;
    -f | -F | --field | --raw-field) fields+=("$a") ;;
    --input) if [ "$a" = - ]; then stdin_input=true; else input_file="$a"; fi ;;
  esac
  case "$a" in
    --jq=*) q="${a#--jq=}" ;;
    -X?*) method="${a#-X}" ;;
    --method=*) method="${a#--method=}" ;;
    -f?* | -F?*) fields+=("${a#-?}") ;;
    --field=* | --raw-field=*) fields+=("${a#*=}") ;;
    --input=-) stdin_input=true ;;
    --input=*) input_file="${a#--input=}" ;;
  esac
  case "$a" in -f* | -F* | --field* | --raw-field* | --input*) has_body=true ;; esac
  [ "$a" != graphql ] || graphql=true
  prev="$a"
done
[ "${1:-}" = api ] || graphql=false
method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"

# 最初の2つの語（-R / --repo とその値は飛ばす）
words=() skip=false
for a in "$@"; do
  if $skip; then skip=false; continue; fi
  case "$a" in
    -R | --repo) skip=true ;;
    -*) ;;
    *) words+=("$a") ;;
  esac
  [ "${#words[@]}" -lt 2 ] || break
done
w0="${words[0]:-}" w1="${words[1]:-}"

# --- 2. 書き込みか、表を引く鍵、記録する行を決める -------------------------------------
write=true
key="$*"
line="$*"
if $graphql; then
  # スクリプトは、クエリと変数を JSON にして --input - で渡す（dw_gql）。ファイルや -f query=… で渡されたときも読む
  body='{}'
  if $stdin_input; then
    body="$(cat)"
  elif [ -n "$input_file" ] && [ -f "$input_file" ]; then
    body="$(cat "$input_file")"
  fi
  query="$(jq -r '.query // ""' <<<"$body" 2>/dev/null || true)"
  vars="$(jq -c '.variables // {}' <<<"$body" 2>/dev/null || echo '{}')"
  for f in ${fields[@]+"${fields[@]}"}; do
    case "$f" in
      query=@*) if [ -f "${f#query=@}" ]; then query="$(cat "${f#query=@}")"; else query=""; fi ;;
      query=*) query="${f#query=}" ;;
      *=*) vars="$(jq -c --arg k "${f%%=*}" --arg v "${f#*=}" '. + {($k): $v}' <<<"$vars")" ;;
    esac
  done
  op="$(printf '%s\n' "$query" | grep -oE '(query|mutation|subscription) [A-Za-z_][A-Za-z0-9_]*' | head -n 1 | cut -d' ' -f2 || true)"
  key="api graphql ${op}"
  line="$key $vars"
  # 読めて、query（か、操作の種類を省いた { … }）で始まるときだけ読むだけ
  if printf '%s\n' "$query" | grep -qE '^[[:space:]]*(query([^A-Za-z0-9_]|$)|\{)'; then write=false; fi
elif [ "$w0" = api ]; then
  # 送る本文は読まない（書き込みかは引数で決まる）。書き手が詰まらないよう、標準入力は読み捨てる
  if $stdin_input; then cat >/dev/null; fi
  case "$method" in
    GET | HEAD) write=false ;;
    "") $has_body || write=false ;;
  esac
else
  case "$w0" in
    "" | search | status | browse | help | version | auth | completion | config) write=false ;;
  esac
  case "$w1" in
    view | list | status | diff | checks | field-list | item-list | get | download | watch | checkout | clone | token) write=false ;;
  esac
  # gh issue view は、Issue の指定（番号・#番号・URL）を番号にそろえ、先頭に並べ直して表を引く（オプションの位置によらず当てるため）
  if [ "$w0 $w1" = "issue view" ]; then
    ref="" rest=() seen=0 prev=""
    for a in "$@"; do
      if [ "$seen" -lt 2 ]; then
        case "$a" in issue | view) seen=$((seen + 1)); prev="$a"; continue ;; esac
      fi
      case "$prev" in
        -R | --repo | --json | -q | --jq | -t | --template) rest+=("$a"); prev="$a"; continue ;;
      esac
      case "$a" in
        -*) rest+=("$a") ;;
        *) if [ -z "$ref" ]; then ref="$a"; else rest+=("$a"); fi ;;
      esac
      prev="$a"
    done
    ref="${ref#\#}"
    ref="${ref##*/issues/}"
    key="issue view ${ref}${rest[0]+ ${rest[*]}}"
  fi
fi

echo "$line" >>"$base/calls"
if $write; then echo "$line" >>"$base/writes"; fi

# --- 3. 表を引いて答える -------------------------------------------------------------
while IFS="$(printf '\t')" read -r pat file code; do
  [ -n "$pat" ] || continue
  # shellcheck disable=SC2254 # パターンとして当てるため、クォートしない
  case "$key" in
    $pat)
      if [ "${code:-0}" != 0 ]; then
        cat "$base/$file" >&2
        exit "$code"
      fi
      if [ -n "$q" ]; then jq -r "$q" "$base/$file"; else cat "$base/$file"; fi
      exit 0
      ;;
  esac
done <"$base/routes"

echo "fake gh: 応答が用意されていない呼び出しです: gh ${key}" >&2
exit 1
