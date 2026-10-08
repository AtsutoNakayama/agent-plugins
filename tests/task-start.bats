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

@test "base_branch がダッシュで始まれば、取得せずに止まる（git fetch のオプションとして扱わせない）" {
  setup_fake_gh
  jq '.base_branch = "-v"' .claude/dev-workflow/config.json >"$TMP/config.json"
  mv "$TMP/config.json" .claude/dev-workflow/config.json
  setup_origin
  run_start --issue 17 --slug "task start"
  assert_failure 2
  assert_output --partial "設定の base_branch が git のブランチ名として使えません: -v"
  [ ! -e "$REPO/.claude/worktrees/feat/17-task-start" ]
  assert_equal "$(args edit)" ""
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

@test "gh が 2.94.0 より古ければ（subIssuesSummary を読めない）、何も変えずに更新を促して止まる（--no-worktree も同じ）" {
  setup_fake_gh
  setup_origin
  FAKE_GH_VERSION=2.93.0 run_start --issue 17 --slug "task start"
  assert_failure 2
  assert_output --partial "サブ Issue と Issue を閉じる PR を読む（gh issue view --json subIssuesSummary,closedByPullRequestsReferences）には gh 2.94.0 以上が要ります（今は 2.93.0）"
  FAKE_GH_VERSION=2.93.0 run_start --issue 17 --no-worktree
  assert_failure 2
  assert_output --partial "gh 2.94.0 以上が要ります"
  [ ! -d "$REPO/.claude/worktrees/feat/17-task-start" ]
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
  for mode in --dry-run ""; do
    run_start --issue 17 --no-worktree ${mode:+"$mode"}
    assert_failure 2
    assert_output --partial "Issue #17 には既にブランチ feat/17-x（ワークツリー $TMP/wt） があります"
  done
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}

@test "--no-worktree は、名前が似ているだけのブランチ（branch.pattern に合わない）では止まらず、警告して着手する" {
  setup_fake_gh
  setup_origin
  git push -q origin main:refs/heads/wip/17-try
  run_start --issue 17 --no-worktree
  assert_success
  assert_output --partial "Issue #17 に関係するかもしれないブランチ（wip/17-try）があります"
  assert_equal "$(called edit)" 1
}

@test "--no-worktree で止まるとき、手で消したワークツリーの場所は伝えない" {
  setup_fake_gh
  setup_origin
  git worktree add -q -b feat/17-x "$TMP/wt"
  rm -rf "$TMP/wt"
  run_start --issue 17 --no-worktree
  assert_failure 2
  assert_output --partial "Issue #17 には既にブランチ feat/17-x があります"
  refute_output --partial "ワークツリー $TMP/wt"
}

@test "--no-worktree でも、origin を読めなければ、割り当ても列の移動もせずに止まる（dry-run も同じ）" {
  setup_fake_gh
  setup_origin
  git remote set-url origin "$TMP/no-such.git"
  for mode in --dry-run ""; do
    run_start --issue 17 --no-worktree ${mode:+"$mode"}
    assert_failure 1
    assert_output --partial "origin のブランチを読めませんでした（通信や認証を確かめてください）"
  done
  assert_equal "$(called edit)" 0
  assert_equal "$(called SetField)" 0
}

@test "--no-worktree は、確かなブランチがあればマージ済みでも止め、終わった作業なら task-finish で片付けるよう伝える" {
  setup_fake_gh
  setup_origin
  git push -q origin main:refs/heads/feat/17-x
  run_start --issue 17 --no-worktree
  assert_failure 2
  assert_output --partial "Issue #17 には既にブランチ feat/17-x があります"
  assert_output --partial "終わった作業のブランチなら、先に task-finish で片付けてください"
  assert_equal "$(called edit)" 0
}

@test "--no-worktree は、Issue を閉じる PR のブランチが残っていれば警告して着手し、残っていなければ警告しない" {
  setup_fake_gh
  setup_origin
  jq '. + {closedByPullRequestsReferences: [{number: 5, url: "https://github.com/me/demo/pull/5", repository: {name: "demo", owner: {login: "me"}}}]}' \
    "$FIX/issue-17.json" >"$FIX/i" && mv "$FIX/i" "$FIX/issue-17.json"
  echo '{"number": 5, "url": "https://github.com/me/demo/pull/5", "state": "OPEN", "headRefName": "fix-foo", "isCrossRepository": false}' >"$FIX/pr-5.json"
  run_start --issue 17 --no-worktree
  assert_success
  refute_output --partial "関係するかもしれないブランチ"
  git push -q origin main:refs/heads/fix-foo
  run_start --issue 17 --no-worktree
  assert_success
  assert_output --partial "Issue #17 に関係するかもしれないブランチ（fix-foo）があります"
}

@test "--branch は、既にあるブランチを名前を作り直さずにそのまま使う（番号の先頭が 0・長い短い説明でも。手元か origin のもの）" {
  setup_fake_gh
  setup_origin
  long="feat/017-$(printf 'a%.0s' $(seq 1 50))"
  git branch "$long"
  run_start --issue 17 --branch "$long"
  assert_success
  assert_equal "$(jq -c '[.branch, .created.worktree, .created.branch]' <<<"$json")" "[\"$long\",true,false]"
  assert_equal "$(git -C ".claude/worktrees/$long" rev-parse --abbrev-ref HEAD)" "$long"
  git push -q origin main:refs/heads/fix/17-remote
  run_start --issue 17 --branch fix/17-remote
  assert_success
  assert_equal "$(git -C .claude/worktrees/fix/17-remote rev-parse --abbrev-ref '@{upstream}')" origin/fix/17-remote
}

@test "--branch のブランチが手元にも origin にも無ければ、何も作らずに止まる" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --branch feat/17-none
  assert_failure 2
  assert_output --partial "ブランチ feat/17-none が手元にも origin にもありません"
  [ ! -d .claude/worktrees ] || fail "ワークツリーを作りました"
  assert_equal "$(called edit)" 0
}

@test "--branch は --slug・--no-worktree と一緒に指定できず、ブランチ名として正しくない名前は受け取らない" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --branch feat/17-x --slug x
  assert_failure 64
  run_start --issue 17 --branch feat/17-x --no-worktree
  assert_failure 64
  # dw_valid_base_branch と同じ決まりで、名前の書式だけを見る（@{-1} を今のリポジトリで展開しない。HEAD・@・+ も断る）
  for name in -x a..b '@{-1}' HEAD @ +feat/17-x; do
    run_start --issue 17 --branch "$name"
    assert_failure 64
    assert_output --partial "--branch のブランチ名が正しくありません"
  done
  assert_equal "$(called edit)" 0
}

@test "--branch は、branch.pattern に合い番号が --issue と同じブランチだけを受け取る（main や別の Issue のブランチは断る）" {
  setup_fake_gh
  setup_origin
  git branch feat/99-other
  git branch wip-17
  for name in main feat/99-other wip-17; do
    run_start --issue 17 --branch "$name"
    assert_failure 2
    assert_output --partial "ブランチ ${name} は、Issue #17 の作業のブランチ（branch.pattern に合い、番号が 17）ではありません"
  done
  [ ! -e .claude/worktrees ]
  assert_equal "$(called edit)" 0
}

@test "--branch で手元に無いブランチを渡し、origin を読めなければ、「無い」とせずに何も作らずに止まる" {
  setup_fake_gh
  setup_origin
  git remote set-url origin "$TMP/no-such.git"
  run_start --issue 17 --branch feat/17-x
  assert_failure 1
  assert_output --partial "origin のブランチを読めませんでした（通信や認証を確かめてください）"
  [ ! -e .claude/worktrees ]
  assert_equal "$(called edit)" 0
}

@test "--branch は、branch.pattern が正規表現として正しくなければ、番号が合わないのではなく設定の誤りで終了コード 2" {
  setup_fake_gh
  echo '{"branch": {"pattern": "{type}/{issue_number}-{slug}("}}' >.claude/dev-workflow/config.json
  setup_origin
  git branch feat/17-x
  run_start --issue 17 --branch feat/17-x
  assert_failure 2
  assert_output --partial "正規表現として正しくありません"
  refute_output --partial "作業のブランチ（branch.pattern に合い"
}

@test "親の列を移せなかったときは、警告を status.warnings に出す。警告が無ければ空の配列" {
  setup_fake_gh
  setup_origin
  jq -nc '{number: 10, title: "親 10", state: "open", state_reason: null, url: "https://api.github.com/repos/me/demo/issues/10", repository_url: "https://api.github.com/repos/me/demo"}' >"$FIX/parent-17.json"
  jq -n '{data: {repository: {issue: {url: "https://github.com/me/demo/issues/10", projectItems: {nodes: [{id: "IT10", project: {id: "P4"}, fieldValueByName: {name: "Todo"}}]}}}}}' >"$FIX/IssueItem-issue-10.json"
  FAKE_FAIL=SetField.2 FAKE_FAIL_MSG="gh: boom" run_start --issue 17 --slug "task start"
  assert_success
  assert_equal "$(jq -c '.status.warnings | length' <<<"$json")" 1
  assert_equal "$(jq -r '.status.warnings[0]' <<<"$json")" "親の Issue #10 の列を start に移せませんでした（Issue #17 の移動は済んでいます）（原因: Issue #10 の Status を「In Progress」にできませんでした）"
  assert_equal "$(jq -c '.status.parents' <<<"$json")" "[]"
}

@test "親が無いとき、status.warnings は空の配列" {
  setup_fake_gh
  setup_origin
  run_start --issue 17 --slug "task start"
  assert_success
  assert_equal "$(jq -c '.status.warnings' <<<"$json")" "[]"
}
