#!/usr/bin/env bats
# bats を CI のシャードに分けるスクリプト（.github/scripts/shard-bats.sh）。

load test_helper

SHARD="$BATS_TEST_DIRNAME/../.github/scripts/shard-bats.sh"

setup() {
  TMP="$(mktemp -d)"
  mkdir "$TMP/t"
  # a が重く、b〜e は軽い。f は表に無い
  printf '# コメント\n\na.bats\t100\nb.bats\t10\nc.bats\t10\nd.bats\t10\ne.bats\t10\n' >"$TMP/w.tsv"
  local f
  for f in a b c d e f; do : >"$TMP/t/$f.bats"; done
  : >"$TMP/t/helper.bash"
}

teardown() {
  rm -rf "$TMP"
}

shard() {
  run "${TEST_BASH:-bash}" "$SHARD" "$1" --dir "$TMP/t" --weights "$TMP/w.tsv"
}

@test "全ファイルが、重複なく、ちょうど1つのシャードに入る" {
  shard 3
  assert_success
  run jq -r '.[].files | split(" ")[]' <<<"$output"
  assert_equal "$(sort <<<"$output")" "$(printf '%s\n' "$TMP"/t/{a,b,c,d,e,f}.bats)"
}

@test "重いファイルは1つで1シャードを占め、残りが別のシャードにまとまる" {
  shard 2
  assert_success
  assert_equal "$(jq -r '.[0].files' <<<"$output")" "$TMP/t/a.bats"
  assert_equal "$(jq -r '.[1].files | split(" ") | length' <<<"$output")" 5
}

@test "表に無いファイルは、表の平均で見積もって、どれかのシャードに入れる" {
  shard 2
  assert_success
  [[ "$output" == *"f.bats"* ]]
}

@test "シャードの数がファイルの数より多いときは、空のシャードを作らない" {
  shard 20
  assert_success
  assert_equal "$(jq length <<<"$output")" 6
  assert_equal "$(jq '[.[].shard] | sort' -c <<<"$output")" "[1,2,3,4,5,6]"
}

@test "シャードが1つなら、全ファイルが入る" {
  shard 1
  assert_success
  assert_equal "$(jq -r '.[0].files | split(" ") | length' <<<"$output")" 6
}

@test "表が無くても動く（全部同じ重さ）" {
  run "${TEST_BASH:-bash}" "$SHARD" 2 --dir "$TMP/t" --weights "$TMP/none.tsv"
  assert_success
  assert_equal "$(jq -r '.[].files | split(" ") | length' <<<"$output" | tr '\n' ' ')" "3 3 "
}

@test "シャードの数が整数でない・0・指定なしならエラー" {
  shard 0
  assert_failure
  shard x
  assert_failure
  run "${TEST_BASH:-bash}" "$SHARD" --dir "$TMP/t"
  assert_failure
}

@test "未知のオプションと余分な位置引数は、使い方を出して断る" {
  run "${TEST_BASH:-bash}" "$SHARD" 2 --foo --dir "$TMP/t"
  assert_failure
  assert_output --partial "使い方"
  run "${TEST_BASH:-bash}" "$SHARD" --foo --dir "$TMP/t"
  assert_failure
  assert_output --partial "使い方"
  run "${TEST_BASH:-bash}" "$SHARD" 2 3 --dir "$TMP/t"
  assert_failure
  assert_output --partial "使い方"
}

@test ".bats が無いディレクトリはエラー" {
  mkdir "$TMP/empty"
  run "${TEST_BASH:-bash}" "$SHARD" 2 --dir "$TMP/empty"
  assert_failure
}

@test "このリポジトリの tests/ の全ファイルがシャードに入り、表に載っているファイルが全部ある" {
  cd "$BATS_TEST_DIRNAME/.."
  run "${TEST_BASH:-bash}" "$SHARD" 4
  assert_success
  assert_equal "$(jq -r '.[].files | split(" ")[]' <<<"$output" | sort)" "$(printf '%s\n' tests/*.bats)"
  # 改名・削除の更新漏れに気づけるよう、表に載っているのに無いファイルを確かめる
  # （tests/ にあって表に無いファイルは、平均で見積もられるので、失敗にしない）
  local name
  while IFS=$'\t' read -r name _; do
    case "$name" in '#'* | '') continue ;; esac
    [ -f "tests/$name" ] || fail "表に載っているのに無いファイル: $name"
  done <.github/scripts/bats-weights.tsv
}

@test "実際の tests/ で、最も重いシャードが、平均の1.5倍を超えない（偏らない）" {
  cd "$BATS_TEST_DIRNAME/.."
  run "${TEST_BASH:-bash}" "$SHARD" 4
  assert_success
  local total max=0 files t f w
  total=$(awk -F'\t' '!/^#/ && NF { s += $2 } END { print s + 0 }' .github/scripts/bats-weights.tsv)
  files=$(jq -r '.[].files' <<<"$output")
  while read -r fs; do
    t=0
    for f in $fs; do
      # 表に無いファイルは、表の平均で見積もる（shard-bats.sh と同じ）。数でなければ失敗させる
      w=$(awk -F'\t' -v n="${f#tests/}" '!/^#/ && NF { s += $2; c++; if ($1 == n) v = $2 } END { print (v != "") ? v + 0 : int(s / c) }' .github/scripts/bats-weights.tsv)
      [[ "$w" =~ ^[0-9]+$ ]] || fail "重みが数でない: $f / $w"
      t=$((t + w))
    done
    if [ "$t" -gt "$max" ]; then max=$t; fi
  done <<<"$files"
  [ $((max * 4)) -le $((total * 3 / 2)) ] || fail "偏っている: 最大 $max / 合計 $total"
}

@test "表の壊れた行（TAB が無い・秒が数でない）は読み飛ばし、平均を崩さない" {
  mkdir "$TMP/u"
  : >"$TMP/u/a.bats" && : >"$TMP/u/b.bats" && : >"$TMP/u/f.bats"
  # 正しい行の平均は 80。壊れた行が 0 として数えられると 40 になり、f は b より軽く見積もられる
  printf 'a.bats\t100\nb.bats\t60\nc.bats 5\nd.bats\tabc\n' >"$TMP/bad.tsv"
  run "${TEST_BASH:-bash}" "$SHARD" 2 --dir "$TMP/u" --weights "$TMP/bad.tsv"
  assert_success
  assert_equal "$(jq -r '.[1].files' <<<"$output")" "$TMP/u/f.bats $TMP/u/b.bats"
}

@test "表のファイル名が空の行は読み飛ばし、平均を崩さない" {
  mkdir "$TMP/v"
  : >"$TMP/v/a.bats" && : >"$TMP/v/b.bats" && : >"$TMP/v/f.bats"
  # 正しい行の平均は 80。空のファイル名の行が数えられると平均が上がり、f は a より重く見積もられる
  printf 'a.bats\t100\nb.bats\t60\n\t500\n' >"$TMP/empty-name.tsv"
  run "${TEST_BASH:-bash}" "$SHARD" 2 --dir "$TMP/v" --weights "$TMP/empty-name.tsv"
  assert_success
  assert_equal "$(jq -r '.[0].files' <<<"$output")" "$TMP/v/a.bats"
  assert_equal "$(jq -r '.[1].files' <<<"$output")" "$TMP/v/f.bats $TMP/v/b.bats"
}
