#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# チームの設定（.claude/workflow.json）をコミットし、origin 役の bare リポジトリに main を push しておく
setup_origin() {
  git add .claude/workflow.json
  git -c user.name=t -c user.email=t@example.com commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git -C "$REPO" remote add origin "$TMP/origin.git"
  git -C "$REPO" push -q origin main
}

run_start() {
  run_script task-start.sh "$@"
  printf '%s\n' "$output"
  json="$(json_of "$output")"
}

@test "ワークツリーとブランチを origin/main から作り、割り当てて In Progress に移す" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --slug "task start"
  assert_success
  wt="$REPO/.claude/worktrees/feat/17-task-start"
  assert_equal "$(jq -c '[.branch, .worktree, .created.worktree, .created.branch, .assigned, .status.to]' <<<"$json")" \
    "[\"feat/17-task-start\",\"$wt\",true,true,true,\"In Progress\"]"
  assert_equal "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" feat/17-task-start
  assert_equal "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$REPO" rev-parse origin/main)"
  # origin/main を追跡しない
  run git -C "$wt" rev-parse --abbrev-ref '@{upstream}'
  assert_failure
  assert_equal "$(args edit)" "17 --add-assignee @me"
  assert_equal "$(args SetField | jq -r .v.singleSelectOptionId)" O2
}

@test "ワークツリーの置き場所が無視されていなければ、.git/info/exclude に足す" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --slug x
  assert_success
  grep -qx '.claude/worktrees/' .git/info/exclude
  assert_equal "$(git status --porcelain -uall)" ""
}

@test "既に無視されていれば .git/info/exclude に足さない" {
  setup_fake_gh
  setup_origin
  echo '.claude/worktrees/' >.gitignore
  run_start --issue 17 --slug x
  assert_success
  run grep -c 'worktrees' .git/info/exclude
  assert_output 0
}

@test "2回目は既にあるワークツリーと割り当てを使い回し、何も変えない" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --slug x
  fake_issue 17 '["feat"]' OPEN '["me"]'
  issue_item "In Progress"
  : >"$CALLS"
  run_start --issue 17 --slug x
  assert_success
  assert_equal "$(jq -c '[.created.worktree, .assigned, .actions]' <<<"$json")" '[false,false,[]]'
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}

@test "ワークツリーの中から実行しても、メインのワークツリーの下に作る" {
  setup_fake_gh
  setup_origin
  fake_issue 18 '["fix"]'
  run_start --issue 17 --slug x
  cd .claude/worktrees/feat/17-x
  run_start --issue 18 --slug y
  assert_success
  assert_equal "$(jq -r .worktree <<<"$json")" "$REPO/.claude/worktrees/fix/18-y"
}

@test "ブランチだけあるときは、そのブランチでワークツリーを作る" {
  setup_fake_gh
  setup_origin
  git branch feat/17-x
  run_start --issue 17 --slug x
  assert_success
  assert_equal "$(jq -c '[.created.worktree, .created.branch]' <<<"$json")" '[true,false]'
}

@test "origin に push 済みのブランチがあれば、そこから作って追跡する（ローカルには無い）" {
  setup_fake_gh
  setup_origin
  git checkout -q -b feat/17-x
  git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "pushed work"
  git push -q origin feat/17-x
  pushed="$(git rev-parse HEAD)"
  git checkout -q main
  git branch -q -D feat/17-x
  run_start --issue 17 --slug x
  assert_success
  assert_equal "$(git -C .claude/worktrees/feat/17-x rev-parse HEAD)" "$pushed"
  assert_equal "$(git -C .claude/worktrees/feat/17-x rev-parse --abbrev-ref '@{upstream}')" origin/feat/17-x
  assert_equal "$(jq -r '.actions[0]' <<<"$json")" \
    "push 済みの origin/feat/17-x からブランチ feat/17-x を作り、ワークツリーを $REPO/.claude/worktrees/feat/17-x に作る"
}

@test "dry-run では何も作らず、割り当ても列の移動もしない" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --slug x --dry-run
  assert_success
  [ ! -e .claude/worktrees ]
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
  assert_equal "$(jq '.actions | length' <<<"$json")" 4
}

@test "project.number が未設定なら、警告して列の移動だけ飛ばす（dry-run も同じ）" {
  setup_fake_gh
  echo '{}' >.claude/workflow.json
  setup_origin
  for mode in --dry-run ""; do
    run_start --issue 17 --slug x ${mode:+"$mode"}
    assert_success
    assert_output --partial "project.number が未設定なので、Project の列は移しません"
    assert_equal "$(jq -c '.status.skipped' <<<"$json")" true
  done
  assert_equal "$(called ProjectFields)" 0
  assert_equal "$(called edit)" 1
}

@test "branch.worktree_dir が絶対パスなら、その下に作る" {
  setup_fake_gh
  jq '. + {branch: {worktree_dir: "'"$TMP"'/wt"}}' .claude/workflow.json >"$TMP/c.json" && mv "$TMP/c.json" .claude/workflow.json
  setup_origin
  run_start --issue 17 --slug x
  assert_success
  assert_equal "$(jq -r .worktree <<<"$json")" "$TMP/wt/feat/17-x"
  [ -d "$TMP/wt/feat/17-x" ]
  run grep -c worktrees .git/info/exclude
  assert_output 0
}

@test "ワークツリーのディレクトリが手で消されていたら、記録を片付けて作り直す" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --slug x
  rm -rf .claude/worktrees/feat/17-x
  run_start --issue 17 --slug x
  assert_success
  [ -d .claude/worktrees/feat/17-x ]
  assert_equal "$(jq -r '.actions[0]' <<<"$json")" "消えたワークツリー $REPO/.claude/worktrees/feat/17-x の記録を片付ける（git worktree prune）"
  assert_equal "$(jq -c '[.created.worktree, .created.branch]' <<<"$json")" '[true,false]'
}

@test "閉じた Issue ではエラーになる" {
  setup_fake_gh
  fake_issue 17 '["feat"]' CLOSED
  run_start --issue 17 --slug x
  assert_failure 2
  assert_output --partial "Issue #17 は閉じています"
}

@test "割り当てに失敗したら止まる" {
  setup_fake_gh
  setup_origin
  FAKE_FAIL=edit run_start --issue 17 --slug x
  assert_failure 1
  assert_output --partial "Issue #17 を割り当てられませんでした"
  assert_equal "$(called SetField)" 0
}
