#!/usr/bin/env bats
# Issue の作業のブランチと PR を探す（issue-branches.sh）。
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

setup() {
  test_helper_setup
  setup_fake_gh
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  link_prs
}

# Issue 17 に紐付く PR（closedByPullRequestsReferences）を決め、PR ごとの中身を作る
# 使い方: link_prs [<番号>:<状態>:<ブランチ>:<フォークか>[:<PR のリポジトリ>]]...
link_prs() {
  local refs='[]' spec n state branch fork repo
  for spec in "$@"; do
    IFS=: read -r n state branch fork repo <<<"$spec"
    repo="${repo:-me/demo}"
    refs="$(jq -c --argjson n "$n" --arg r "$repo" \
      '. + [{number: $n, url: "https://github.com/\($r)/pull/\($n)", repository: {name: ($r | split("/")[1]), owner: {login: ($r | split("/")[0])}}}]' <<<"$refs")"
    jq -n --argjson n "$n" --arg s "$state" --arg b "$branch" --argjson f "$fork" --arg r "$repo" \
      '{number: $n, url: "https://github.com/\($r)/pull/\($n)", state: $s, headRefName: $b, isCrossRepository: $f}' >"$FIX/pr-$n.json"
  done
  jq --argjson refs "$refs" '. + {closedByPullRequestsReferences: $refs}' "$FIX/issue-17.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issue-17.json"
}

run_branches() {
  run_script issue-branches.sh "$@"
  printf '%s\n' "$output"
  json="$(json_of "$output")"
}

@test "名前で、手元とリモートのこの Issue のブランチを見つける（ほかの Issue のブランチは入れない）" {
  git branch feat/17-x
  git branch fix/170-y
  git push -q origin main:refs/heads/docs/17-z
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[.branches[] | [.name, .local, .remote, .pr]]' <<<"$json")" \
    '[["docs/17-z",false,true,null],["feat/17-x",true,false,null]]'
  assert_equal "$(jq -c .prs <<<"$json")" '[]'
}

@test "ワークツリーで使っているブランチには、その場所を付ける" {
  git worktree add -q -b feat/17-x "$TMP/wt"
  run_branches --issue '#17'
  assert_success
  assert_equal "$(jq -r '.branches[0].worktree' <<<"$json")" "$TMP/wt"
}

@test "規約に合わない名前のブランチも、Issue に紐付く PR から見つける（開いている・マージ済み）" {
  git branch fix-foo
  link_prs 5:OPEN:fix-foo:false 6:MERGED:old-work:false
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[.branches[] | [.name, .local, .pr]]' <<<"$json")" '[["fix-foo",true,5],["old-work",false,6]]'
  assert_equal "$(jq -c '[.prs[] | [.number, .state, .fork]]' <<<"$json")" '[[5,"OPEN",false],[6,"MERGED",false]]'
}

@test "マージせずに閉じた PR は除く" {
  link_prs 5:CLOSED:fix-foo:false
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[.branches, .prs]' <<<"$json")" '[[],[]]'
}

@test "フォークや別のリポジトリの PR は prs に fork として出し、ブランチには入れない" {
  link_prs 5:OPEN:patch-1:true 6:OPEN:feat/17-x:false:other/lib
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c .branches <<<"$json")" '[]'
  assert_equal "$(jq -c '[.prs[] | [.number, .fork]]' <<<"$json")" '[[5,true],[6,true]]'
}

@test "名前と PR の両方で見つかったブランチは1つにまとめる" {
  git branch feat/17-x
  link_prs 5:OPEN:feat/17-x:false
  run_branches --issue 17
  assert_success
  assert_equal "$(jq -c '[.branches[] | [.name, .pr]]' <<<"$json")" '[["feat/17-x",5]]'
}

@test "origin を読めなければ、「リモートに無い」と区別できないまま出さずに止まる" {
  git branch feat/17-x
  git remote set-url origin "$TMP/no-such.git"
  run_branches --issue 17
  assert_failure 1
  assert_output "error: origin のブランチを読めませんでした（通信や認証を確かめてください）"
}

@test "Issue を読めなければ止まる。--issue が数字でなければ使い方の誤り" {
  FAKE_FAIL=issue-view run_branches --issue 17
  assert_failure 1
  assert_output --partial "Issue #17 を読めません: gh: failed"
  run_branches --issue x
  assert_failure 64
}

@test "先頭に 0 が付いた --issue（017）でも、名前のブランチ（feat/17-x）を見つける" {
  git branch feat/17-x
  run_branches --issue 017
  assert_success
  assert_equal "$(jq -c '[.issue, [.branches[].name]]' <<<"$json")" '[17,["feat/17-x"]]'
}

@test "PR の番号は Issue として受け取らずに止まる（task-finish が PR を Issue として閉じないため）" {
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21, "closedByPullRequestsReferences": []}' >"$FIX/issue-21.json"
  run_branches --issue 21
  assert_failure 2
  assert_output --partial "#21 は PR です。Issue の番号を指定してください"
}
