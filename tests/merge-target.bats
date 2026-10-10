#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# origin 役の bare リポジトリに main を push し、作業用のブランチ feat/17-x に1つコミットしておく
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

# origin に、手元の main と同じ位置のブランチ <名前> を作る。手元の origin/<名前> は作らない（取得はスクリプトが行う）
remote_branch() {
  git push -q origin "main:refs/heads/$1"
  git update-ref -d "refs/remotes/origin/$1"
}

# 標準エラーを $TMP/err に分けて実行する
run_target() {
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/merge-target.sh' 2>'$TMP/err'"
}

@test "PR が無ければ、設定の base_branch をマージ先にし、取得する" {
  setup_branch
  run_target
  assert_success
  assert_equal "$(jq -c . <<<"$output")" '{"branch":"feat/17-x","base_branch":"main","target":"main","ref":"origin/main","from":"base_branch","pr":null,"fetched":true}'
  assert_equal "$(args pr-list)" "--head feat/17-x --state open --json number,url,baseRefName,isCrossRepository"
}

@test "開いた PR のマージ先が設定の base_branch と違えば、PR のマージ先をマージ先にし、手元に無くても取得する（#284）" {
  setup_branch
  remote_branch release/v1
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .ref, .from, .pr, .fetched]' <<<"$output")" '["release/v1","origin/release/v1","pr",{"number":7,"url":"https://github.com/me/demo/pull/7"},true]'
  assert_equal "$(git rev-parse origin/release/v1)" "$(git rev-parse main)"
}

@test "fork の PR だけ・JSON でない応答・使えないマージ先・gh が失敗したときは、設定の base_branch をマージ先にする（#284）" {
  setup_branch
  remote_branch release/v1
  echo '[{"number": 9, "url": "u", "isCrossRepository": true, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .pr]' <<<"$output")" '["main","base_branch",null]'
  rm "$FIX/pr-list.json"
  echo 'not json' >"$FIX/pr-list.raw"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .pr]' <<<"$output")" '["main","base_branch",null]'
  rm "$FIX/pr-list.raw"
  echo '[{"number": 7, "url": "u", "isCrossRepository": false, "baseRefName": "-x"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .pr.number]' <<<"$output")" '["main","base_branch",7]'
  grep -qF "PR のマージ先（-x）は git のブランチ名として使えない" "$TMP/err" || fail "$(cat "$TMP/err")"
  FAKE_FAIL=pr-list run_target
  assert_success
  assert_equal "$(jq -c '[.target, .pr]' <<<"$output")" '["main",null]'
}

@test "PR のマージ先を取得できず、手元にも無ければ、警告して設定の base_branch に戻す（#284）" {
  setup_branch
  # origin に release/v1 が無い
  echo '[{"number": 7, "url": "u", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .ref, .from, .pr.number, .fetched]' <<<"$output")" '["main","origin/main","base_branch",7,true]'
  grep -qF "PR のマージ先の origin/release/v1 を取得できず、手元にもないので、設定の base_branch（main）をマージ先にします" "$TMP/err" \
    || fail "$(cat "$TMP/err")"
}

@test "取得できなくても手元に origin/<マージ先> があれば、警告してそれを使い、どれも無ければ終了コード 2 で止まる" {
  setup_branch
  git fetch -q origin
  git remote set-url origin "$TMP/no-such.git"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .fetched]' <<<"$output")" '["main",false]'
  grep -qF "origin/main を最新にできませんでした。手元の origin/main で判断します" "$TMP/err" || fail "$(cat "$TMP/err")"
  git update-ref -d refs/remotes/origin/main
  run_target
  assert_failure 2
  grep -qF "マージ先が見つかりません: origin/main" "$TMP/err" || fail "$(cat "$TMP/err")"
}
