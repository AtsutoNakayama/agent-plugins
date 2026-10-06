#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# チームの設定（.claude/dev-workflow/config.json）をコミットし、origin 役の bare リポジトリに main を push しておく
setup_origin() {
  git add .claude/dev-workflow/config.json
  git -c user.name=t -c user.email=t@example.com commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git -C "$REPO" remote add origin "$TMP/origin.git"
  git -C "$REPO" push -q origin main
}

# サブモジュール lib/sub（$TMP/sub）をコミットしておく。setup_origin より前に呼ぶ
add_submodule() {
  # 手元のパスのサブモジュールは、git の既定では取得を禁止されている（CVE-2022-39253）ので、テストの中だけ許す
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  git init -q -b main "$TMP/sub"
  echo sub >"$TMP/sub/README"
  git -C "$TMP/sub" add README
  git -C "$TMP/sub" commit -q -m sub
  git submodule add -q "$TMP/sub" lib/sub
  git commit -q -m submodule
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
  assert_equal "$(args SetField | jq -r '."single-select-option-id"')" O2
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
  echo '{}' >.claude/dev-workflow/config.json
  setup_origin
  for mode in --dry-run ""; do
    run_start --issue 17 --slug x ${mode:+"$mode"}
    assert_success
    assert_output --partial "project.number が未設定なので、Project の列は移しません"
    assert_equal "$(jq -c '.status.skipped' <<<"$json")" true
  done
  assert_equal "$(called ProjectView)" 0
  assert_equal "$(called edit)" 1
}

@test "branch.worktree_dir が絶対パスなら、その下に作る" {
  setup_fake_gh
  jq '. + {branch: {worktree_dir: "'"$TMP"'/wt"}}' .claude/dev-workflow/config.json >"$TMP/c.json" && mv "$TMP/c.json" .claude/dev-workflow/config.json
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

@test "--slug が無い、または英数字が無いときは、何も変えずにエラーになる" {
  setup_fake_gh
  setup_origin
  run_start --issue 17
  assert_failure 64
  assert_output --partial "--slug は必須です"
  run_start --issue 17 --slug "ログイン画面"
  assert_failure 64
  assert_output --partial "短い説明に英数字がありません"
  [ ! -e .claude/worktrees ]
  assert_equal "$(git branch --list 'feat/*')" ""
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}

@test "閉じた Issue ではエラーになる" {
  setup_fake_gh
  fake_issue 17 '["feat"]' CLOSED
  run_start --issue 17 --slug x
  assert_failure 2
  assert_output --partial "Issue #17 は閉じています"
}

@test "親の Issue（サブ Issue を持つ）では、何も作らず、割り当ても列の移動もせずに止まる（dry-run も同じ）" {
  setup_fake_gh
  setup_origin
  jq '. + {subIssuesSummary: {total: 3, completed: 1, percentCompleted: 33}}' "$FIX/issue-17.json" >"$FIX/i" \
    && mv "$FIX/i" "$FIX/issue-17.json"
  for mode in --dry-run ""; do
    run_start --issue 17 --slug x ${mode:+"$mode"}
    assert_failure 2
    assert_output "error: Issue #17 は親の Issue（子の Issue が 3 件）なので、着手しません。子の Issue に着手してください"
  done
  [ ! -e .claude/worktrees ]
  assert_equal "$(git branch --list 'feat/*')" ""
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}

@test "サブ Issue が無い Issue（subIssuesSummary の total が 0）には着手する" {
  setup_fake_gh
  setup_origin
  jq '. + {subIssuesSummary: {total: 0, completed: 0, percentCompleted: 0}}' "$FIX/issue-17.json" >"$FIX/i" \
    && mv "$FIX/i" "$FIX/issue-17.json"
  run_start --issue 17 --slug x
  assert_success
  assert_equal "$(jq -r .branch <<<"$json")" feat/17-x
}

@test "割り当てに失敗したら止まる" {
  setup_fake_gh
  setup_origin
  FAKE_FAIL=edit run_start --issue 17 --slug x
  assert_failure 1
  assert_output --partial "Issue #17 を割り当てられませんでした"
  assert_equal "$(called SetField)" 0
}

@test ".gitmodules があれば、ワークツリーのサブモジュールを初期化する" {
  setup_fake_gh
  add_submodule
  setup_origin
  run_start --issue 17 --slug x
  assert_success
  assert_equal "$(cat .claude/worktrees/feat/17-x/lib/sub/README)" sub
  jq -e 'any(.actions[]; . == "ワークツリーのサブモジュールを初期化する（git submodule update --init --recursive）")' <<<"$json"
}

@test "dry-run では、サブモジュールの初期化を予定に出すだけ" {
  setup_fake_gh
  add_submodule
  setup_origin
  run_start --issue 17 --slug x --dry-run
  assert_success
  [ ! -e .claude/worktrees ]
  jq -e 'any(.actions[]; . == "ワークツリーのサブモジュールを初期化する（git submodule update --init --recursive）")' <<<"$json"
}

@test "サブモジュールの初期化に失敗しても、警告して続ける。次に実行したとき初期化し直す" {
  setup_fake_gh
  add_submodule
  setup_origin
  mv "$TMP/sub" "$TMP/sub.away"
  run_start --issue 17 --slug x
  assert_success
  assert_output --partial "サブモジュールを初期化できませんでした"
  assert_equal "$(jq -r .status.to <<<"$json")" "In Progress"
  [ ! -e .claude/worktrees/feat/17-x/lib/sub/README ]
  mv "$TMP/sub.away" "$TMP/sub"
  run_start --issue 17 --slug x
  assert_success
  refute_output --partial "サブモジュールを初期化できませんでした"
  assert_equal "$(cat .claude/worktrees/feat/17-x/lib/sub/README)" sub
}

@test "入れ子のサブモジュールだけ初期化に失敗しても、次に実行したとき初期化し直す" {
  setup_fake_gh
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
  git init -q -b main "$TMP/nested"
  git -C "$TMP/nested" commit -q --allow-empty -m nested
  git init -q -b main "$TMP/sub"
  git -C "$TMP/sub" submodule add -q "$TMP/nested" n
  git -C "$TMP/sub" commit -q -m sub
  git submodule add -q "$TMP/sub" lib/sub
  git commit -q -m submodule
  setup_origin
  mv "$TMP/nested" "$TMP/nested.away"
  run_start --issue 17 --slug x
  assert_success
  assert_output --partial "サブモジュールを初期化できませんでした"
  mv "$TMP/nested.away" "$TMP/nested"
  run_start --issue 17 --slug x
  assert_success
  refute_output --partial "サブモジュールを初期化できませんでした"
  run git -C .claude/worktrees/feat/17-x submodule status --recursive
  refute_line --regexp '^-'
}

@test "dry-run で、手元の origin/main が .gitmodules を追加する前のものでも、初期化を予定に出す" {
  setup_fake_gh
  setup_origin
  add_submodule
  run_start --issue 17 --slug x --dry-run
  assert_success
  jq -e 'any(.actions[]; . == "ワークツリーのサブモジュールを初期化する（git submodule update --init --recursive）")' <<<"$json"
}

@test "--no-worktree では、ブランチもワークツリーも作らず、割り当てと列の移動だけを行う" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --no-worktree
  assert_success
  assert_equal "$(jq -c '[.branch, .worktree, .created.worktree, .created.branch, .assigned, .status.to]' <<<"$json")" \
    '[null,null,false,false,true,"In Progress"]'
  [ ! -e .claude/worktrees ]
  assert_equal "$(git branch --list 'feat/*')" ""
  assert_equal "$(git worktree list | wc -l | tr -d ' ')" 1
  run grep -c worktrees .git/info/exclude
  assert_output 0
  assert_equal "$(args edit)" "17 --add-assignee @me"
  assert_equal "$(args SetField | jq -r '."single-select-option-id"')" O2
}

@test "--no-worktree の dry-run では、割り当てと列の移動を予定に出すだけ" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --no-worktree --dry-run
  assert_success
  assert_equal "$(jq '.actions | length' <<<"$json")" 2
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}

@test "--no-worktree で着手した後に --slug で実行すると、ワークツリーとブランチだけを作る" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --no-worktree
  fake_issue 17 '["feat"]' OPEN '["me"]'
  issue_item "In Progress"
  : >"$CALLS"
  run_start --issue 17 --slug x
  assert_success
  assert_equal "$(jq -c '[.branch, .created.worktree, .created.branch, .assigned]' <<<"$json")" '["feat/17-x",true,true,false]'
  [ -d .claude/worktrees/feat/17-x ]
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}

@test "--no-worktree と --slug を一緒に指定すると、何も変えずにエラーになる" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --no-worktree --slug x
  assert_failure 64
  assert_output --partial "--no-worktree と --slug は一緒に指定できません"
  [ ! -e .claude/worktrees ]
  assert_equal "$(called edit)" 0
}

@test "--no-worktree でも、親の Issue には着手しない" {
  setup_fake_gh
  setup_origin
  jq '. + {subIssuesSummary: {total: 2, completed: 0, percentCompleted: 0}}' "$FIX/issue-17.json" >"$FIX/i" \
    && mv "$FIX/i" "$FIX/issue-17.json"
  run_start --issue 17 --no-worktree
  assert_failure 2
  assert_output --partial "親の Issue"
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}

@test "origin を読めなければ、「origin に無い」と区別できないので、ブランチもワークツリーも作らずに止まる（dry-run も同じ）" {
  setup_fake_gh
  setup_origin
  git remote set-url origin "$TMP/no-such.git"
  for mode in --dry-run ""; do
    run_start --issue 17 --slug x ${mode:+"$mode"}
    assert_failure 1
    assert_output --partial "origin のブランチを読めませんでした（通信や認証を確かめてください）"
  done
  [ ! -e .claude/worktrees ]
  assert_equal "$(git branch --list 'feat/*')" ""
  assert_equal "$(called edit)" 0
}

@test "PR の番号は Issue として受け取らず、割り当ても列の移動もせずに止まる（--no-worktree でも）" {
  setup_fake_gh
  setup_origin
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21, "title": "PR", "state": "OPEN", "assignees": [], "labels": [{"name": "feat"}]}' >"$FIX/issue-21.json"
  for args in "--no-worktree" "--slug x"; do
    # shellcheck disable=SC2086 # 単語に分けて渡すのが目的
    run_start --issue 21 $args
    assert_failure 2
    assert_output --partial "#21 は PR です。Issue の番号を指定してください"
  done
  [ ! -e .claude/worktrees ]
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}

@test "--no-worktree でも、Issue に既にブランチがあれば着手せず、ブランチとワークツリーの場所を伝えて止まる（dry-run も同じ）" {
  setup_fake_gh
  setup_origin
  git worktree add -q -b feat/17-x "$TMP/wt"
  git push -q origin main:refs/heads/wip/17-try
  for mode in --dry-run ""; do
    run_start --issue 17 --no-worktree ${mode:+"$mode"}
    assert_failure 2
    assert_output --partial "Issue #17 には既にブランチ feat/17-x（ワークツリー $TMP/wt）、wip/17-try があります"
  done
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}
