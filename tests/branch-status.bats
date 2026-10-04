#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# origin 役の bare リポジトリに main を push し、feat/17-x を作って1つコミットしておく
setup_branch() {
  setup_fake_gh
  git add .claude/dev-workflow/config.json
  git commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  git switch -q -c feat/17-x
  echo work >work.txt
  git add work.txt
  git commit -q -m "feat: work"
}

# origin の main に、別の PR がマージされたことにする（main を n 個進める）
advance_main() {
  local i
  git clone -q "$TMP/origin.git" "$TMP/other"
  for i in $(seq 1 "$1"); do
    echo "$i" >"$TMP/other/main-$i.txt"
    git -C "$TMP/other" add .
    git -C "$TMP/other" commit -q -m "main $i"
  done
  git -C "$TMP/other" push -q origin main
}

run_status() {
  run_script branch-status.sh "$@"
  printf '%s\n' "$output"
}

@test "main が進んでいなければ up_to_date で、先行のコミット数を出す" {
  setup_branch
  run_status
  assert_success
  assert_equal "$(jq -r '[.branch, .base, .behind, .ahead, .up_to_date, .pr] | map(tostring) | join(" ")' <<<"$output")" "feat/17-x main 0 1 true null"
}

@test "main が進んでいれば、遅れているコミット数を出す（取得は branch-status.sh が行う）" {
  setup_branch
  advance_main 2
  run_status
  assert_success
  assert_equal "$(jq -r '[.behind, .ahead, .up_to_date] | map(tostring) | join(" ")' <<<"$output")" "2 1 false"
}

@test "開いている PR のマージ状態を出す" {
  setup_branch
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "BEHIND"}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -r '.pr | [.number, .merge_state] | map(tostring) | join(" ")' <<<"$output")" "5 BEHIND"
  assert_equal "$(args pr-list)" "--head feat/17-x --state open --json number,url,mergeStateStatus"
}

@test "PR を取得できなくても、遅れの数は出す（pr は null）" {
  setup_branch
  FAKE_FAIL=pr-list run_status
  assert_success
  assert_equal "$(jq -c .pr <<<"$output")" "null"
}

@test "--branch で別のブランチを調べられる" {
  setup_branch
  git switch -q main
  run_status --branch feat/17-x
  assert_success
  assert_equal "$(jq -r .branch <<<"$output")" "feat/17-x"
}

@test "base_branch の上では止まる" {
  setup_branch
  git switch -q main
  run_status
  assert_failure 64
  assert_output --partial "main には取り込めません"
}

@test "存在しないブランチでは止まる" {
  setup_branch
  run_status --branch nope
  assert_failure 64
  assert_output --partial "ブランチ nope がありません"
}
