#!/usr/bin/env bats
# repair-push-check.sh：無人で push する前の、パスの機械的な確認（ADR 000285）。本物の git で確かめる。

load test_helper

setup() {
  test_helper_setup
  # origin（bare）を作って、main を push する
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  mkdir -p .github/workflows .claude/dev-workflow src
  echo a >src/a.txt
  echo w >.github/workflows/ci.yml
  git add -A && git commit -q -m base
  git push -q origin main
  git checkout -q -b feat/1-x
}

commit_file() { mkdir -p "$(dirname "$1")" && echo "$2" >"$1" && git add "$1" && git commit -q -m "change $1"; }

@test "通常のファイルだけなら ok" {
  commit_file src/b.txt b
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c . <<<"$output")" '{"ok":true,"forbidden":[],"compared_with":"origin/main"}'
}

@test ".github/workflows/ を変えていたら ok が false で、そのパスを返す" {
  commit_file .github/workflows/ci.yml changed
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[false,[".github/workflows/ci.yml"]]'
}

@test ".claude/ を新しく足していたら ok が false" {
  commit_file .claude/dev-workflow/x.json '{}'
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[false,[".claude/dev-workflow/x.json"]]'
}

@test "取り込んだ main が変えた .github/workflows/ は数えない（main と同じ内容のパス）" {
  # main が workflows を変え、それを取り込む
  git checkout -q main
  commit_file .github/workflows/ci.yml from-main
  git push -q origin main
  git checkout -q feat/1-x
  commit_file src/b.txt b
  git fetch -q origin
  git merge -q --no-edit origin/main
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .forbidden]' <<<"$output")" '[true,[]]'
}

@test "origin のブランチがあれば、それとの差だけを見る（push 済みの変更は数えない）" {
  commit_file .github/workflows/ci.yml pushed
  git push -q origin feat/1-x
  commit_file src/b.txt b
  git fetch -q origin
  run_script repair-push-check.sh --base-branch main
  assert_success
  assert_equal "$(jq -c '[.ok, .compared_with]' <<<"$output")" '[true,"origin/feat/1-x"]'
}

@test "origin/<base> が無いと止まる" {
  run_script repair-push-check.sh --base-branch nothing
  assert_failure 2
}

@test "--base-branch が無いと止まる" {
  run_script repair-push-check.sh
  assert_failure 64
}
