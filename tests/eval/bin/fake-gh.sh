#!/usr/bin/env bash
# claude plugin eval のケースで使う偽の gh（同じディレクトリの gh は、このファイルへのシンボリックリンク。
# 本体は、shellcheck の対象にするため、拡張子の付いたこのファイルにしてある）。GitHub に触れずに、ケースの準備のスクリプト
# （plugins/dev-workflow/evals/lib/scaffold.bash の fake_gh）が作業用のディレクトリに置いた表で答える。
# tests/eval/run.sh が、このディレクトリを PATH の先頭に足す。eval のサンドボックスの中からは、PATH にあるディレクトリしか
# 見えないので、本体も gh と同じディレクトリに置く。
#
# 表と記録は、今のディレクトリから上に辿って最初に見つかる .fake-gh/ に置く（ワークツリーの中で呼ばれても、作業用のリポジトリのものを使う）
#   .fake-gh/routes  1行に1つ「<パターン>\t<応答のファイル>\t<終了コード>」。パターンは bash の case のパターンで、
#                    引数を空白でつないだ文字列に当てる。gh api graphql は「api graphql <操作名>」に当てる。上から最初に合うものを使う
#   .fake-gh/calls   呼ばれるたびに、引数を空白でつないだ1行を足す（graphql は「api graphql <操作名> <変数の JSON>」）
#   .fake-gh/writes  GitHub に書き込む呼び出しなら、calls と同じ1行をここにも足す（grader は、これが空かで「書き込まなかった」を確かめる）
# 応答のファイルは .fake-gh/ からの相対パス。終了コードが 0 でなければ、応答を標準エラーに出して、その終了コードで終わる。
# -q / --jq があれば、応答に jq -r で当てる。合うパターンが無ければ、記録してから失敗する（足りない応答に気付けるように）。
#
# 書き込みかどうかは、ここで1か所で決める（ケースごとに正規表現を書くと、スクリプトの実際の呼び方とずれて見逃すため）。
# 読むだけと分かっている呼び出しの他は、すべて書き込みとみなす（知らない呼び出しを見逃さないように）。
#   gh api graphql   クエリが mutation なら書き込み
#   gh api           -X / --method が GET 以外なら書き込み。指定が無くても、-f・-F・--field・--raw-field・--input があれば
#                    gh は POST で送るので書き込み
#   それ以外         最初の2つの語（-R / --repo とその値は飛ばす）が、読むだけのもの（view・list・status・diff・checks など）でなければ書き込み
set -euo pipefail

# 書き込みなら成功する。使い方: is_write <gh の引数>...
is_write() {
  local a prev="" method="" has_body=false words=() skip=false
  if [ "${1:-}" = api ]; then
    for a in "$@"; do
      case "$prev" in -X | --method) method="$a" ;; esac
      case "$a" in
        -X?*) method="${a#-X}" ;;
        --method=*) method="${a#--method=}" ;;
        -f | -F | --field | --raw-field | --input | --field=* | --raw-field=* | --input=*) has_body=true ;;
      esac
      prev="$a"
    done
    method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
    if [ -z "$method" ]; then
      if $has_body; then method=POST; else method=GET; fi
    fi
    [ "$method" != GET ]
    return
  fi
  for a in "$@"; do
    if $skip; then skip=false; continue; fi
    case "$a" in
      -R | --repo) skip=true ;;
      -*) ;;
      *) words+=("$a") ;;
    esac
    [ "${#words[@]}" -lt 2 ] || break
  done
  case "${words[0]:-}" in
    "" | search | status | browse | help | version) return 1 ;;
  esac
  case "${words[1]:-}" in
    view | list | status | diff | checks | field-list | item-list | get | download | watch) return 1 ;;
  esac
  return 0
}

dir="$PWD"
while [ ! -f "$dir/.fake-gh/routes" ]; do
  [ "$dir" != / ] || { echo "fake gh: .fake-gh/routes が見つかりません（${PWD} から上）" >&2; exit 1; }
  dir="$(dirname "$dir")"
done
base="$dir/.fake-gh"

q="" prev=""
for a in "$@"; do
  case "$prev" in -q | --jq) q="$a" ;; esac
  prev="$a"
done

key="$*"
if [ "${1:-} ${2:-}" = "api graphql" ]; then
  # スクリプトは、クエリと変数を JSON にして --input - で渡す（dw_gql）。-f query=… で渡されたときは、引数から読む
  body='{}'
  case " $* " in *" --input - "*) body="$(cat)" ;; esac
  query="$(jq -r '.query // ""' <<<"$body")"
  for a in "$@"; do
    case "$a" in query=*) query="${a#query=}" ;; esac
  done
  op="$(printf '%s\n' "$query" | grep -oE '(query|mutation) [A-Za-z]+' | head -n 1 | cut -d' ' -f2 || true)"
  key="api graphql ${op}"
  line="$key $(jq -c '.variables // {}' <<<"$body")"
  echo "$line" >>"$base/calls"
  if printf '%s\n' "$query" | grep -qE '^[[:space:]]*mutation([^A-Za-z0-9_]|$)'; then echo "$line" >>"$base/writes"; fi
else
  echo "$key" >>"$base/calls"
  if is_write "$@"; then echo "$key" >>"$base/writes"; fi
fi

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
