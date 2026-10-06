#!/usr/bin/env bash
# claude plugin eval のケースで使う偽の gh（同じディレクトリの gh は、このファイルへのシンボリックリンク。
# shellcheck の対象にするため、本体は拡張子の付いたこのファイルにしてある）。GitHub に触れずに、ケースの準備のスクリプト
# （plugins/dev-workflow/evals/lib/scaffold.bash の fake_gh）が作業用のディレクトリに置いた表で答える。
# tests/eval/run.sh が、このディレクトリを PATH の先頭に足す。eval のサンドボックスの中からは、PATH にあるディレクトリしか
# 見えないので、本体も gh と同じディレクトリに置く。
#
# 表と記録は、今のディレクトリから上に辿って最初に見つかる .fake-gh/ に置く（ワークツリーの中で呼ばれても、作業用のリポジトリのものを使う）
#   .fake-gh/routes  1行に1つ「<パターン>\t<応答のファイル>\t<終了コード>」。パターンは bash の case のパターンで、
#                    引数を空白でつないだ文字列に当てる。gh api graphql は「api graphql <操作名>」に当てる。上から最初に合うものを使う
#   .fake-gh/calls   呼ばれるたびに、引数を空白でつないだ1行を足す（graphql は「api graphql <操作名> <変数の JSON>」）
# 応答のファイルは .fake-gh/ からの相対パス。終了コードが 0 でなければ、応答を標準エラーに出して、その終了コードで終わる。
# -q / --jq があれば、応答に jq -r で当てる。合うパターンが無ければ、記録してから失敗する（足りない応答に気付けるように）。
set -euo pipefail

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
  # スクリプトは、クエリと変数を JSON にして --input - で渡す（dw_gql）。クエリには必ず操作名がある
  body="$(cat)"
  op="$(jq -r '.query // ""' <<<"$body" | grep -oE '(query|mutation) [A-Za-z]+' | head -n 1 | cut -d' ' -f2 || true)"
  key="api graphql ${op}"
  echo "$key $(jq -c '.variables // {}' <<<"$body")" >>"$base/calls"
else
  echo "$key" >>"$base/calls"
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
