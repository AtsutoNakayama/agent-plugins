#!/usr/bin/env bash
# tests/*.bats を N 個のシャード（CI の matrix の1つ分）に分け、所要時間が偏らないようにする。
# 使い方: shard-bats.sh <シャードの数> [--dir <bats のあるディレクトリ>] [--weights <所要時間の表>]
# 出力: [{"shard": 1, "files": "tests/a.bats tests/b.bats"}, ...]（ファイルは空白区切り。ファイルの数より多くは作らない）
# 分け方: 所要時間の長いファイルから順に、そのときいちばん軽いシャードへ入れる（貪欲法）。
# 所要時間は bats-weights.tsv（<ファイル名><タブ><秒>）の目安。表に無いファイルは表の平均で見積もるので、
# 表が古くても、新しい .bats は必ずどれかのシャードに入る。
# macOS 標準の bash 3.2 でも動く。
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
  echo "使い方: shard-bats.sh <シャードの数（1以上の整数）> [--dir <ディレクトリ>] [--weights <表>]" >&2
  exit 1
}

dir=tests
weights="$here/bats-weights.tsv"
n=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="${2:?--dir にはディレクトリが要ります}"; shift 2 ;;
    --weights) weights="${2:?--weights にはファイルが要ります}"; shift 2 ;;
    -*) usage ;;
    *) [ -z "$n" ] || usage; n="$1"; shift ;;
  esac
done
case "$n" in
  '' | *[!0-9]* | 0) usage ;;
esac

files=""
for f in "$dir"/*.bats; do
  [ -e "$f" ] || continue
  files="$files$f"$'\n'
done
if [ -z "$files" ]; then
  echo "$dir に .bats がありません" >&2
  exit 1
fi

printf '%s' "$files" | awk -v n="$n" -v wf="$weights" '
  BEGIN {
    FS = "\t"
    while ((getline line < wf) > 0) {
      if (line ~ /^#/ || line == "") continue
      # TAB で区切られた「ファイル名 秒（数）」の行だけを読む（壊れた行で平均を崩さない）
      if (split(line, a, "\t") != 2 || a[1] == "" || a[2] !~ /^[0-9]+$/) continue
      w[a[1]] = a[2] + 0; sum += a[2]; cnt++
    }
    avg = cnt ? sum / cnt : 1
  }
  {
    cnt_f++
    path[cnt_f] = $0
    base = $0; sub(".*/", "", base)
    wt[cnt_f] = (base in w) ? w[base] : avg
  }
  END {
    # 重い順に並べる（挿入ソート。同じ重さは名前順）
    for (i = 1; i <= cnt_f; i++) ord[i] = i
    for (i = 2; i <= cnt_f; i++) {
      v = ord[i]; j = i - 1
      while (j >= 1 && (wt[ord[j]] < wt[v] || (wt[ord[j]] == wt[v] && path[ord[j]] > path[v]))) { ord[j + 1] = ord[j]; j-- }
      ord[j + 1] = v
    }
    for (s = 1; s <= n; s++) { load[s] = 0; num[s] = 0 }
    for (i = 1; i <= cnt_f; i++) {
      k = ord[i]; best = 1
      for (s = 2; s <= n; s++) if (load[s] < load[best]) best = s
      load[best] += wt[k]
      # 代入の左辺を先に作る awk（busybox など）でも空白が先頭に付かないよう、個数で分ける
      list[best] = (num[best] > 0) ? list[best] " " path[k] : path[k]
      num[best]++
    }
    for (s = 1; s <= n; s++) if (num[s] > 0) printf "%d\t%s\n", s, list[s]
  }
' | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {shard: (.[0] | tonumber), files: .[1]})'
