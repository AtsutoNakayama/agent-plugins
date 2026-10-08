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

@test ".bats が無いディレクトリはエラー" {
  mkdir "$TMP/empty"
  run "${TEST_BASH:-bash}" "$SHARD" 2 --dir "$TMP/empty"
  assert_failure
}

@test "このリポジトリの tests/ の全ファイルが入り、表に無い・消えたファイルは無い" {
  cd "$BATS_TEST_DIRNAME/.."
  run "${TEST_BASH:-bash}" "$SHARD" 4
  assert_success
  assert_equal "$(jq -r '.[].files | split(" ")[]' <<<"$output" | sort)" "$(printf '%s\n' tests/*.bats)"
  # 表の更新漏れに気づけるよう、表のファイルが実在するかも確かめる
  local name
  while IFS=$'\t' read -r name _; do
    case "$name" in '#'* | '') continue ;; esac
    [ -f "tests/$name" ] || fail "表に載っているのに無いファイル: $name"
  done <.github/scripts/bats-weights.tsv
  [ "$(grep -vc '^#' .github/scripts/bats-weights.tsv)" -ge 1 ]
}

@test "実際の tests/ で、最も重いシャードが、平均の1.5倍を超えない（偏らない）" {
  cd "$BATS_TEST_DIRNAME/.."
  run "${TEST_BASH:-bash}" "$SHARD" 4
  assert_success
  local total max=0 l
  total=$(awk -F'\t' '!/^#/ && NF { s += $2 } END { print s }' .github/scripts/bats-weights.tsv)
  while read -r l; do
    [ "$l" -gt "$max" ] && max=$l
  done < <(jq -r '.[].files' <<<"$output" | while read -r fs; do
    t=0
    for f in $fs; do t=$((t + $(awk -F'\t' -v n="${f#tests/}" '$1 == n { print $2 }' .github/scripts/bats-weights.tsv))); done
    echo "$t"
  done)
  [ $((max * 4)) -le $((total * 3 / 2)) ] || fail "偏っている: 最大 $max / 合計 $total"
}
