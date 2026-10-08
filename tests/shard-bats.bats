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

@test "このリポジトリの tests/ の全ファイルがシャードに入り、表と tests/ が食い違わない" {
  cd "$BATS_TEST_DIRNAME/.."
  run "${TEST_BASH:-bash}" "$SHARD" 4
  assert_success
  assert_equal "$(jq -r '.[].files | split(" ")[]' <<<"$output" | sort)" "$(printf '%s\n' tests/*.bats)"
  # 表の更新漏れに気づけるよう、表と tests/ の食い違いを両方向で確かめる
  local name f
  while IFS=$'\t' read -r name _; do
    case "$name" in '#'* | '') continue ;; esac
    [ -f "tests/$name" ] || fail "表に載っているのに無いファイル: $name"
  done <.github/scripts/bats-weights.tsv
  for f in tests/*.bats; do
    grep -q "^${f#tests/}"$'\t' .github/scripts/bats-weights.tsv || fail "tests/ にあるのに表に無いファイル（bats-weights.tsv に足す）: $f"
  done
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
      # 表に無いファイルは 0 とする（表の網羅は別のテストが確かめる）。数でなければ失敗させる
      w=$(awk -F'\t' -v n="${f#tests/}" '$1 == n { v = $2 } END { print v + 0 }' .github/scripts/bats-weights.tsv)
      [[ "$w" =~ ^[0-9]+$ ]] || fail "重みが数でない: $f / $w"
      t=$((t + w))
    done
    if [ "$t" -gt "$max" ]; then max=$t; fi
  done <<<"$files"
  [ $((max * 4)) -le $((total * 3 / 2)) ] || fail "偏っている: 最大 $max / 合計 $total"
}
