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
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "BEHIND", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -r '.pr | [.number, .merge_state] | map(tostring) | join(" ")' <<<"$output")" "5 BEHIND"
  assert_equal "$(args pr-list)" "--head feat/17-x --state open --json number,url,mergeStateStatus,isCrossRepository"
}

@test "fork の同じ名前のブランチからの PR は除く" {
  setup_branch
  echo '[{"number": 9, "url": "u", "mergeStateStatus": "CLEAN", "isCrossRepository": true}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -c .pr <<<"$output")" "null"
}

@test "gh が無くても、遅れの数は出す（pr は null）" {
  setup_branch
  mkdir "$TMP/nogh"
  for c in git jq bash env sed awk cat dirname basename grep cut head tr sort mktemp rm wc; do
    ln -s "$(command -v "$c")" "$TMP/nogh/$c" 2>/dev/null || true
  done
  PATH="$TMP/nogh" run_status
  assert_success
  assert_equal "$(jq -r '[.behind, .pr] | map(tostring) | join(" ")' <<<"$output")" "0 null"
}

@test "未コミットの変更があれば dirty が true" {
  setup_branch
  run_status
  assert_equal "$(jq -r .dirty <<<"$output")" "false"
  echo more >>work.txt
  run_status
  assert_equal "$(jq -r .dirty <<<"$output")" "true"
}

@test "origin にブランチが無ければ unpushed・unpulled は null" {
  setup_branch
  run_status
  assert_equal "$(jq -c '[.unpushed, .unpulled]' <<<"$output")" "[null,null]"
}

@test "未 push のコミットと、手元に無い origin のコミットの数を出す" {
  setup_branch
  git push -q origin feat/17-x
  echo a >a.txt
  git add a.txt
  git commit -q -m "feat: a"
  run_status
  assert_equal "$(jq -c '[.unpushed, .unpulled]' <<<"$output")" "[1,0]"
  git clone -q -b feat/17-x "$TMP/origin.git" "$TMP/other2"
  echo b >"$TMP/other2/b.txt"
  git -C "$TMP/other2" add b.txt
  git -C "$TMP/other2" commit -q -m "feat: b"
  git -C "$TMP/other2" push -q origin feat/17-x
  run_status
  assert_equal "$(jq -c '[.unpushed, .unpulled]' <<<"$output")" "[1,1]"
}

@test "PR を取得できなくても、遅れの数は出す（pr は null）" {
  setup_branch
  FAKE_FAIL=pr-list run_status
  assert_success
  assert_equal "$(jq -c .pr <<<"$output")" "null"
}

@test "base_branch の上では止まる" {
  setup_branch
  git switch -q main
  run_status
  assert_failure 64
  assert_output --partial "main には取り込めません"
}

@test "不明な引数（--branch など）は拒否する" {
  setup_branch
  run_status --branch feat/17-x
  assert_failure 64
  assert_output --partial "不明な引数です: --branch"
}

@test "base_branch がダッシュで始まっていても、オプションとして扱わず取得に失敗して止まる" {
  setup_branch
  echo '{"base_branch": "-foo", "project": {"owner": "me", "number": 4}}' >"$REPO/.claude/dev-workflow/config.json"
  run_status
  assert_failure
  assert_output --partial "origin/-foo を取得できませんでした"
}

@test "ブランチの上にいなければ止まる" {
  setup_branch
  git switch -q --detach
  run_status
  assert_failure 64
  assert_output --partial "ブランチの上にいません"
}

@test "未追跡のファイルだけなら dirty は false" {
  setup_branch
  echo memo >memo.txt
  run_status
  assert_equal "$(jq -r .dirty <<<"$output")" "false"
}

@test "origin でブランチが削除されていたら、残っている追跡ブランチではなく null を出す" {
  setup_branch
  git push -q origin feat/17-x
  git fetch -q origin
  git push -q origin --delete feat/17-x
  run_status
  assert_equal "$(jq -c '[.unpushed, .unpulled]' <<<"$output")" "[null,null]"
}

@test "PR のマージキューの状態（有効か・並んでいるときの状態と順番）を、PR の URL から読んで出す" {
  setup_branch
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "CLEAN", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  echo '{"data": {"resource": {"isMergeQueueEnabled": true, "mergeQueueEntry": {"state": "UNMERGEABLE", "position": 2}}}}' >"$FIX/PrQueue.json"
  run_status
  assert_success
  assert_equal "$(jq -c '.pr | [.merge_state, .merge_queue]' <<<"$output")" '["CLEAN",{"enabled":true,"state":"UNMERGEABLE","position":2}]'
  assert_equal "$(grep '^PrQueue ' "$CALLS")" 'PrQueue {"url":"https://github.com/me/demo/pull/5"}'
}

@test "キューに並んでいなければ state・position は null、キューが無ければ enabled は false" {
  setup_branch
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "CLEAN", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  echo '{"data": {"resource": {"isMergeQueueEnabled": true, "mergeQueueEntry": null}}}' >"$FIX/PrQueue.json"
  run_status
  assert_equal "$(jq -c .pr.merge_queue <<<"$output")" '{"enabled":true,"state":null,"position":null}'
  echo '{"data": {"resource": {"isMergeQueueEnabled": false, "mergeQueueEntry": null}}}' >"$FIX/PrQueue.json"
  run_status
  assert_equal "$(jq -c .pr.merge_queue <<<"$output")" '{"enabled":false,"state":null,"position":null}'
}

@test "マージキューの状態を取得できなくても、PR は出す（merge_queue は null）" {
  setup_branch
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "DIRTY", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  FAKE_FAIL=PrQueue run_status
  assert_success
  assert_equal "$(jq -c '.pr | [.number, .merge_state, .merge_queue]' <<<"$output")" '[5,"DIRTY",null]'
}

@test "PR が無ければ、マージキューの状態は問い合わせない" {
  setup_branch
  run_status
  assert_success
  assert_equal "$(grep -c '^PrQueue ' "$CALLS")" 0
}
