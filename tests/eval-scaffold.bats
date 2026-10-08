#!/usr/bin/env bats
# eval のケースの準備の共通処理（plugins/dev-workflow/evals/lib/scaffold.bash）と、各ケースの準備のスクリプトのテスト

load test_helper

EVALS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/evals"

setup() {
  test_helper_setup
  WS="$TMP/ws"
  mkdir -p "$WS"
  cd "$WS" || return 1
  # 準備のスクリプトが作るリポジトリで、偽の gh を使えるようにする（tests/eval/run.sh と同じ）
  export PATH="$BATS_TEST_DIRNAME/eval/bin:$PATH"
}

# scaffold.bash を読み込んで、引数の処理を作業用のディレクトリで実行する
scaffold() {
  run "${TEST_BASH:-bash}" -c ". \"$EVALS/lib/scaffold.bash\" && $1"
}

@test "eval_repo は、導入済みの git リポジトリを作り、origin/main を作る" {
  scaffold eval_repo
  assert_success
  assert_equal "$(git branch --show-current)" main
  assert_equal "$(cat .claude/dev-workflow/config.json)" '{}'
  git rev-parse --verify -q origin/main
  assert_equal "$(git rev-parse origin/main)" "$(git rev-parse HEAD)"
  # 偽の gh の表と bare のリポジトリは、git の対象にしない
  assert_equal "$(git status --porcelain)" ""
}

@test "eval_repo は、PATH の gh が偽物でなければ、何も作らずに失敗する（run.sh を使わずに動かしたとき）" {
  mkdir -p "$TMP/realbin"
  printf '#!/bin/sh\necho real\n' >"$TMP/realbin/gh"
  chmod +x "$TMP/realbin/gh"
  PATH="$TMP/realbin:$PATH" scaffold eval_repo
  assert_failure
  assert_output --partial "tests/eval/run.sh"
  [ ! -e .git ]
}

@test "eval_repo の origin は、ブランチの削除と fast-forward でない push を拒む" {
  scaffold eval_repo
  assert_success
  run git push -q origin --delete main
  assert_failure
  git commit -q --allow-empty -m more
  git push -q origin main
  git reset -q --hard HEAD^
  run git push -q --force origin main
  assert_failure
}

@test "eval_repo に渡した設定を config.json に書く" {
  scaffold "eval_repo '{\"project\": {\"owner\": \"me\", \"number\": 4}}'"
  assert_success
  assert_equal "$(jq -c . .claude/dev-workflow/config.json)" '{"project":{"owner":"me","number":4}}'
}

@test "eval_repo の後、gh repo view と gh api user に答える" {
  scaffold eval_repo
  assert_success
  assert_equal "$(gh repo view --json nameWithOwner -q .nameWithOwner)" "me/demo"
  assert_equal "$(gh api user -q .login)" "me"
}

@test "fake_issue の Issue を gh issue view で読める" {
  scaffold "eval_repo && fake_issue 7 'タイトル' fix '## やること'"
  assert_success
  run gh issue view 7 --json number,title,body,labels,state
  assert_success
  assert_equal "$(jq -c '[.number, .title, .labels[0].name, .state, .body]' <<<"$output")" '[7,"タイトル","fix","OPEN","## やること"]'
}

@test "fake_issue の Issue は、番号・#番号・URL のどれで指定しても、オプションの前後どちらでも読める" {
  scaffold "eval_repo && fake_issue 7 'タイトル' fix '## やること' && fake_issue 70 '別' feat ''"
  assert_success
  local args
  for args in "7" "#7" "https://github.com/me/demo/issues/7" "7 --json title" "--json title 7" "-R me/demo 7 --json title"; do
    # shellcheck disable=SC2086 # 引数に分けるため、クォートしない
    run gh issue view $args
    assert_success
    assert_equal "$(jq -r .title <<<"$output")" "タイトル"
  done
}

@test "fake_gh_defaults の後、起票や PR の作成に成功したように答え、書き込みとして記録する" {
  scaffold "eval_repo && fake_gh_defaults"
  assert_success
  assert_equal "$(gh issue create --title t)" "https://github.com/me/demo/issues/99"
  assert_equal "$(gh pr close 2 && echo ok)" ok
  assert_equal "$(gh api -X POST repos/me/demo/issues/99/dependencies/blocked_by -F issue_id=1)" '{}'
  assert_equal "$(wc -l <.fake-gh/writes | tr -d ' ')" 3
}

@test "fake_gh_defaults の後、よく使う読むだけの呼び出しに答え、書き込みとして数えない" {
  scaffold "eval_repo && fake_gh_defaults"
  assert_success
  gh pr status >/dev/null
  gh search issues login >/dev/null
  gh project field-list 4 --owner me --format json >/dev/null
  gh issue list --state open --json number >/dev/null
  assert_equal "$(wc -l <.fake-gh/writes | tr -d ' ')" 0
}

@test "fake_gh_defaults より前にケースで足した行が、既定の行より先に当たる" {
  scaffold "eval_repo && fake_gh_read 'issue list*' '[{\"number\": 5}]' && fake_gh_defaults"
  assert_success
  assert_equal "$(gh issue list --json number -q '.[0].number')" 5
}

@test "fake_gh_defaults の後、issue-create.sh が起票まで進み、書き込みとして記録される" {
  scaffold "eval_repo && fake_gh_defaults"
  assert_success
  printf '本文' >"$TMP/body.md"
  # Project が未設定という警告（標準エラー）は見ない
  run "${TEST_BASH:-bash}" -c "\"\$0\" \"$SCRIPTS/issue-create.sh\" --title t --type feat --body-file \"$TMP/body.md\" 2>/dev/null" "${TEST_BASH:-bash}"
  assert_success
  assert_equal "$(jq -r .number <<<"$output")" 99
  run grep -c '^api -X POST repos/me/demo/issues ' .fake-gh/writes
  assert_output 1
}

@test "各ケースの準備のスクリプトが成功する" {
  local f n=0
  for f in "$EVALS"/*/fixture.sh; do
    rm -rf "$WS" && mkdir -p "$WS" && cd "$WS"
    run "${TEST_BASH:-bash}" "$f"
    assert_success
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

@test "fix のケースの準備の後、task-start はどの短い説明でもルートを使い回す（別のワークツリーを作らない）" {
  run "${TEST_BASH:-bash}" "$EVALS/fix-same-cause-elsewhere/fixture.sh"
  assert_success
  local slug
  for slug in "quote the name variable" "Fix/Greet Name" "x" "fix name 2 名前"; do
    # Project が未設定という警告（標準エラー）は見ない
    run "${TEST_BASH:-bash}" -c "\"\$0\" \"$SCRIPTS/task-start.sh\" --issue 1 --slug \"\$1\" 2>/dev/null" "${TEST_BASH:-bash}" "$slug"
    assert_success
    assert_equal "$(jq -r .worktree <<<"$output")" "$WS"
    assert_equal "$(jq -r .created.branch <<<"$output")" false
  done
  assert_equal "$(git worktree list | wc -l | tr -d ' ')" 1
}

# 使い方: grader_pattern <ケース> <grader の名前> → grader の pattern（シングルクォートで囲んだ値）
grader_pattern() { sed -n "s/^pattern: '\\(.*\\)'\$/\\1/p" "$EVALS/$1/graders/$2.md"; }

@test "task-auto の無効のケースの準備の後、auto-check.sh は disabled を返し、何も書き込まない" {
  run "${TEST_BASH:-bash}" "$EVALS/task-auto-disabled-does-nothing/fixture.sh"
  assert_success
  run "${TEST_BASH:-bash}" "$SCRIPTS/auto-check.sh" --issue 2
  assert_success
  assert_equal "$(jq -r .action <<<"$output")" disabled
  [ ! -s .fake-gh/writes ] || fail "書き込みが記録されました: $(cat .fake-gh/writes)"
}

@test "task-auto の止まるケースの準備の後、auto-check.sh は hold を返し、auto-hold.sh の書き込みが grader に当たる" {
  run "${TEST_BASH:-bash}" "$EVALS/task-auto-stops-on-breaking/fixture.sh"
  assert_success
  run "${TEST_BASH:-bash}" "$SCRIPTS/auto-check.sh" --issue '#2'
  assert_success
  assert_equal "$(jq -c '[.action, .reasons]' <<<"$output")" '["hold",["breaking ラベルが付いています（破壊的変更と移行のしかたは、人が決めます）"]]'
  [ ! -s .fake-gh/writes ] || fail "auto-check.sh が書き込みました: $(cat .fake-gh/writes)"
  printf '止まった理由\n' >"$TMP/reason.md"
  run "${TEST_BASH:-bash}" "$SCRIPTS/auto-hold.sh" --issue 2 --reason-file "$TMP/reason.md"
  assert_success
  assert_equal "$(jq -c '[.commented, .status.from, .status.to]' <<<"$output")" '[true,"Todo","On Hold"]'
  local c=task-auto-stops-on-breaking
  grep -qE "$(grader_pattern $c comments-on-issue)" .fake-gh/writes || fail "comments-on-issue に当たりません: $(cat .fake-gh/writes)"
  grep -qE "$(grader_pattern $c moves-to-hold)" .fake-gh/writes || fail "moves-to-hold に当たりません: $(cat .fake-gh/writes)"
  if grep -qE "$(grader_pattern $c no-other-writes)" .fake-gh/writes; then fail "no-other-writes に当たります: $(cat .fake-gh/writes)"; fi
}
