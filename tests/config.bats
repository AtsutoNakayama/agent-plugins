#!/usr/bin/env bats

load test_helper

@test "設定ファイルが無ければプラグインの既定値を返す" {
  run_script config.sh .status.start
  [ "$status" -eq 0 ]
  [ "$output" = "In Progress" ]
}

@test "上位の層が決めていない項目には下位の層の値が効く" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/workflow.json"
  echo '{"commit": {"scope_required": true}}' >.claude/workflow.json
  run_script config.sh '[.language, .commit.scope_required, .commit.types[0]] | tojson'
  [ "$status" -eq 0 ]
  [ "$output" = '["en",true,"feat"]' ]
}

@test "同じ項目はリポジトリの規約がユーザーの好みより優先される" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/workflow.json"
  echo '{"language": "ja"}' >.claude/workflow.json
  run_script config.sh .language
  [ "$output" = "ja" ]
}

@test "個人の上書き（local）はリポジトリの規約より優先される" {
  echo '{"language": "ja"}' >.claude/workflow.json
  echo '{"language": "en"}' >.claude/workflow.local.json
  run_script config.sh .language
  [ "$output" = "en" ]
}

@test "ワークツリーではメインのワークツリーの local を使う" {
  echo '{"language": "en"}' >.claude/workflow.local.json
  git worktree add -q -b feat/1-x "$TMP/wt"
  cd "$TMP/wt"
  run_script config.sh .language
  [ "$output" = "en" ]
}

@test "既にある PR テンプレートを検出し、リポジトリの規約で上書きできる" {
  mkdir -p .github
  touch .github/pull_request_template.md
  run_script config.sh .pr.template
  [ "$output" = ".github/pull_request_template.md" ]

  echo '{"pr": {"template": "docs/pr.md"}}' >.claude/workflow.json
  run_script config.sh .pr.template
  [ "$output" = "docs/pr.md" ]
}

@test "commitlint の設定を検出する" {
  touch commitlint.config.js
  run_script config.sh .detected.commitlint
  [ "$output" = "commitlint.config.js" ]
}

@test "ガイドはユーザー → リポジトリの順に並ぶ" {
  mkdir -p .claude/workflow
  echo user >"$WORKFLOW_USER_DIR/commit.md"
  echo repo >.claude/workflow/commit.md
  run_script config.sh '.guides.commit[1]'
  [ "$output" = "$REPO/.claude/workflow/commit.md" ]
  run_script config.sh '.guides.commit[0]'
  [ "$output" = "$WORKFLOW_USER_DIR/commit.md" ]
}

@test "明示的な null で既定値を消せる" {
  echo '{"status": {"done": null}}' >.claude/workflow.json
  run_script config.sh .status.done
  [ "$output" = "null" ]
}

@test "JSON として読めない設定はエラーになる" {
  echo '{broken' >.claude/workflow.json
  run_script config.sh
  [ "$status" -eq 2 ]
  [[ "$output" == *"JSON のオブジェクトとして読めません"* ]]
}

@test "オブジェクト以外の設定（配列・null・複数の値）はエラーになる" {
  for body in '[]' 'null' '{"a": 1}{"b": 2}'; do
    printf '%s\n' "$body" >"$WORKFLOW_USER_DIR/workflow.json"
    run_script config.sh
    [ "$status" -eq 2 ]
    [[ "$output" == *"JSON のオブジェクトとして読めません"* ]]
  done
}

@test "WORKFLOW_REPO_ROOT を指定すると、今いる場所ではなくそのリポジトリの local を使う" {
  echo '{"language": "en"}' >.claude/workflow.local.json
  git worktree add -q -b feat/1-x "$TMP/wt"
  mkdir -p "$TMP/other/.claude"
  git -C "$TMP/other" init -q -b main
  echo '{"language": "fr"}' >"$TMP/other/.claude/workflow.local.json"
  cd "$TMP/other"
  WORKFLOW_REPO_ROOT="$TMP/wt" run_script config.sh .language
  [ "$output" = "en" ]
}
