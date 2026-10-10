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
  assert_equal "$(jq -c . <<<"$output")" '{"branch":"feat/17-x","base_branch":"main","target":"main","ref":"origin/main","from":"base_branch","pr":null,"fallback":null,"fetched":true}'
  assert_equal "$(args pr-list)" "--head feat/17-x --state open --json number,url,baseRefName,isCrossRepository"
}

@test "開いた PR のマージ先が設定の base_branch と違えば、PR のマージ先をマージ先にし、手元に無くても取得する（#284）" {
  setup_branch
  remote_branch release/v1
  echo '[{"number": 7, "url": "https://github.com/me/demo/pull/7", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .ref, .from, .pr, .fallback, .fetched]' <<<"$output")" '["release/v1","origin/release/v1","pr",{"number":7,"url":"https://github.com/me/demo/pull/7"},null,true]'
  assert_equal "$(git rev-parse origin/release/v1)" "$(git rev-parse main)"
}

@test "fork の PR だけなら、設定の base_branch をマージ先にする（fallback ではない）" {
  setup_branch
  remote_branch release/v1
  echo '[{"number": 9, "url": "u", "isCrossRepository": true, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .pr, .fallback]' <<<"$output")" '["main","base_branch",null,null]'
}

@test "PR の応答を読めなければ、設定の base_branch を使い、fallback に pr_unreadable を出す" {
  setup_branch
  for response in 'not json' '{}'; do
    echo "$response" >"$FIX/pr-list.raw"
    run_target
    assert_success
    assert_equal "$(jq -c '[.target, .from, .pr, .fallback, .fetched]' <<<"$output")" '["main","base_branch",null,"pr_unreadable",true]'
    grep -qF 'pr_unreadable' "$TMP/err" || fail "$(cat "$TMP/err")"
  done
  rm "$FIX/pr-list.raw"
  FAKE_FAIL=pr-list run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .pr, .fallback, .fetched]' <<<"$output")" '["main","base_branch",null,"pr_unreadable",true]'
  grep -qF 'pr_unreadable' "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "PR のマージ先を使えなければ、警告して続け、理由を fallback に出す（読むだけの側。#284）" {
  setup_branch
  remote_branch release/v1
  # ブランチ名として使えない：base_branch に戻す
  echo '[{"number": 7, "url": "u", "isCrossRepository": false, "baseRefName": "-x"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .pr.number, .fallback]' <<<"$output")" '["main","base_branch",7,"invalid_name"]'
  grep -qF 'PR のマージ先（"-x"）は git のブランチ名として使えません。マージ先を origin/main として判断します' "$TMP/err" || fail "$(cat "$TMP/err")"
  # マージ先の違う PR が複数：最初の PR のマージ先で続ける
  echo '[{"number": 7, "url": "u", "isCrossRepository": false, "baseRefName": "release/v1"}, {"number": 8, "url": "u8", "isCrossRepository": false, "baseRefName": "main"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .pr.number, .fallback]' <<<"$output")" '["release/v1","pr",7,"multiple_prs"]'
  grep -qF 'マージ先の違う開いた PR が複数あります（最初の PR のマージ先は "release/v1"）' "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "from は、PR の baseRefName をそのまま使ったときだけ pr（base_branch と同じ値でも pr。無いか空なら base_branch。#284）" {
  setup_branch
  echo '[{"number": 7, "url": "u", "isCrossRepository": false, "baseRefName": "main"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .pr.number, .fallback]' <<<"$output")" '["main","pr",7,null]'
  for pr in '{"number": 7, "url": "u", "isCrossRepository": false}' '{"number": 7, "url": "u", "isCrossRepository": false, "baseRefName": ""}'; do
    echo "[$pr]" >"$FIX/pr-list.json"
    run_target
    assert_success
    assert_equal "$(jq -c '[.target, .from, .pr.number, .fallback]' <<<"$output")" '["main","base_branch",7,null]'
  done
}

@test "マージ先の違う PR が複数あり、最初の PR のマージ先も取得できなければ、両方を警告し、fallback は fetch_failed にする（#284）" {
  setup_branch
  # origin に release/v1 が無い
  echo '[{"number": 7, "url": "u", "isCrossRepository": false, "baseRefName": "release/v1"}, {"number": 8, "url": "u8", "isCrossRepository": false, "baseRefName": "main"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .pr.number, .fallback]' <<<"$output")" '["main","base_branch",7,"fetch_failed"]'
  grep -qF 'マージ先の違う開いた PR が複数あります（最初の PR のマージ先は "release/v1"）' "$TMP/err" || fail "$(cat "$TMP/err")"
  grep -qF 'PR のマージ先（"release/v1"）を origin から取得できず、手元にもありません' "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "multiple_prs のメッセージの最初の PR のマージ先は、PR から読んだ値（空なら空）を出し、置き換えた base_branch を出さない（#284）" {
  setup_branch
  remote_branch release/v1
  echo '[{"number": 7, "url": "u", "isCrossRepository": false, "baseRefName": ""}, {"number": 8, "url": "u8", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .from, .fallback]' <<<"$output")" '["main","base_branch","multiple_prs"]'
  grep -qF '（最初の PR のマージ先は ""）' "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "PR のマージ先を取得できず、手元にも無ければ、警告して設定の base_branch に戻す（#284）" {
  setup_branch
  # origin に release/v1 が無い
  echo '[{"number": 7, "url": "u", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_target
  assert_success
  assert_equal "$(jq -c '[.target, .ref, .from, .pr.number, .fallback, .fetched]' <<<"$output")" '["main","origin/main","base_branch",7,"fetch_failed",true]'
  grep -qF 'PR のマージ先（"release/v1"）を origin から取得できず、手元にもありません。マージ先を origin/main として判断します' "$TMP/err" \
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

@test "設定を読めなければ、merge-target.sh のメッセージで終了コード 2 で止まる" {
  setup_branch
  echo '{' >.claude/dev-workflow/config.json
  run_target
  assert_failure 2
  grep -qF "設定を読めません（config.sh で確かめてください）" "$TMP/err" || fail "$(cat "$TMP/err")"
}
