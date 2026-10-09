#!/usr/bin/env bats
# repair-run-count.sh：無人の push の回数を、repair-run のマーカーの head から数える（ADR 000339）。値だけで決める

load test_helper

setup() {
  test_helper_setup
  A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  C=cccccccccccccccccccccccccccccccccccccccc
}

# 使い方: comments <本文>... → gh pr view --json comments の形（投稿者 bot、時刻は 1 分ずつ後）
comments() {
  jq -n '{comments: ($ARGS.positional | to_entries
    | map({author: {login: "bot"}, body: .value, createdAt: ("2026-10-10T00:0\(.key):00Z")}))}' --args "$@"
}
run_mark() { printf '<!-- dev-workflow:repair-run head=%s -->\n\n## 代わりに決めたこと\n' "$1"; }
count() { run_script repair-run-count.sh "$@" <"$TMP/in.json"; }

@test "push していない回（head が今の head と同じ）は数えない（#332）" {
  # A から B へ push した回と、B で push に失敗した回（PR の head は B のまま）
  comments "$(run_mark "$A")" "$(run_mark "$B")" >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads, .not_pushed, .runs]' <<<"$output")" "[1,[\"$A\"],1,2]"
}

@test "コメントを付けた後に push の前で止まった回だけなら、0 回" {
  comments "$(run_mark "$A")" >"$TMP/in.json"
  count --head "$A"
  assert_success
  assert_equal "$(jq -c '[.count, .not_pushed]' <<<"$output")" '[0,1]'
}

@test "同じ head の repair-run が重なっても、1 回と数える（失敗した後に同じ sha から push し直した）" {
  comments "$(run_mark "$A")" "$(run_mark "$A")" "$(run_mark "$B")" >"$TMP/in.json"
  count --head "$C"
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads]' <<<"$output")" "[2,[\"$A\",\"$B\"]]"
}

@test "head の無い古い形式は、1 つを 1 回と数える" {
  comments '<!-- dev-workflow:repair-run -->' '<!-- dev-workflow:repair-run -->' "$(run_mark "$A")" >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -c '[.count, .legacy, .runs]' <<<"$output")" '[3,2,3]'
}

@test "sha の大文字と小文字は区別しない" {
  comments "$(run_mark "$(tr a-f A-F <<<"$A")")" >"$TMP/in.json"
  count --head "$A"
  assert_success
  assert_equal "$(jq -r .count <<<"$output")" 0
}

@test "本文の先頭に無いマーカー（引用など）と、ほかのマーカーは数えない" {
  comments "> $(run_mark "$A")" "前置き $(run_mark "$A")" '<!-- dev-workflow:repair-done sha=x -->' '<!-- dev-workflow:repair-runx -->' >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -c '[.count, .runs]' <<<"$output")" '[0,0]'
}

@test "--logins を渡すと、その投稿者のコメントだけを数える" {
  jq -n --arg a "$(run_mark "$A")" --arg b "$(run_mark "$B")" '{comments: [
    {author: {login: "bot"}, body: $a, createdAt: "2026-10-10T00:00:00Z"},
    {author: {login: "someone"}, body: $b, createdAt: "2026-10-10T00:01:00Z"}]}' >"$TMP/in.json"
  count --head "$C" --logins 'other,bot'
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads]' <<<"$output")" "[1,[\"$A\"]]"
}

@test "--since より後のコメントだけを数える（再開の起点）" {
  comments "$(run_mark "$A")" "$(run_mark "$B")" >"$TMP/in.json"
  count --head "$C" --since 2026-10-10T00:00:30Z
  assert_success
  assert_equal "$(jq -c '[.count, .pushed_heads]' <<<"$output")" "[1,[\"$B\"]]"
}

@test "gh api の出力（配列、--paginate --slurp の配列の配列）も読める" {
  jq -n --arg a "$(run_mark "$A")" --arg b "$(run_mark "$B")" '[[
    {user: {login: "bot"}, body: $a, created_at: "2026-10-10T00:00:00Z"}],
    [{user: {login: "bot"}, body: $b, created_at: "2026-10-10T00:01:00Z"}]]' >"$TMP/in.json"
  count --head "$B" --logins bot
  assert_success
  assert_equal "$(jq -c '[.count, .not_pushed]' <<<"$output")" '[1,1]'
}

@test "repair-run が無ければ 0 回" {
  comments '人のコメント' >"$TMP/in.json"
  count --head "$A"
  assert_success
  assert_equal "$(jq -c . <<<"$output")" '{"count":0,"pushed_heads":[],"legacy":0,"not_pushed":0,"runs":0}'
}

@test "コメントが長くても（引数の長さの上限の 128 KiB を超えても）数える" {
  # 入力を作る側も引数の上限に当たるので、本文はファイルから読ませる
  { run_mark "$A"; head -c 140000 /dev/zero | tr '\0' x; } >"$TMP/long.md"
  jq -n --rawfile b "$TMP/long.md" '{comments: [{author: {login: "bot"}, body: $b, createdAt: "2026-10-10T00:00:00Z"}]}' >"$TMP/in.json"
  count --head "$B"
  assert_success
  assert_equal "$(jq -r .count <<<"$output")" 1
}

@test "--head が無い・16 進でない・--since が時刻でない・不明な引数・入力が違うときは 64 で止まる" {
  comments >"$TMP/in.json"
  count
  assert_failure 64
  count --head xyz
  assert_failure 64
  count --head "$A" --since yesterday
  assert_failure 64
  count --head "$A" --nope
  assert_failure 64
  count --head
  assert_failure 64
  echo '{"x":1}' >"$TMP/in.json"
  count --head "$A"
  assert_failure 64
  echo 'not json' >"$TMP/in.json"
  count --head "$A"
  assert_failure 64
}
