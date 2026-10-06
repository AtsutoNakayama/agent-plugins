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

@test "fake_gh_writes の後、起票や PR の作成に成功したように答え、呼び出しを記録する" {
  scaffold "eval_repo && fake_gh_writes"
  assert_success
  assert_equal "$(gh issue create --title t)" "https://github.com/me/demo/issues/99"
  run grep -c '^issue create' .fake-gh/calls
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
