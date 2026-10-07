#!/usr/bin/env bats

load test_helper

@test "設定ファイルが無ければプラグインの既定値を返す" {
  run_script config.sh .status.start
  assert_success
  assert_output "In Progress"
}

@test "上位の層が決めていない項目には下位の層の値が効く" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo '{"commit": {"scope_required": true}}' >.claude/dev-workflow/config.json
  run_script config.sh '[.language, .commit.scope_required, .commit.types[0]] | tojson'
  assert_success
  assert_output '["en",true,"feat"]'
}

@test "同じ項目はリポジトリの規約がユーザーの好みより優先される" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo '{"language": "ja"}' >.claude/dev-workflow/config.json
  run_script config.sh .language
  assert_output "ja"
}

@test "個人の上書き（local）はリポジトリの規約より優先される" {
  echo '{"language": "ja"}' >.claude/dev-workflow/config.json
  echo '{"language": "en"}' >.claude/dev-workflow/config.local.json
  run_script config.sh .language
  assert_output "en"
}

@test "ワークツリーではメインのワークツリーの local を使う" {
  echo '{"language": "en"}' >.claude/dev-workflow/config.local.json
  git worktree add -q -b feat/1-x "$TMP/wt"
  cd "$TMP/wt"
  run_script config.sh .language
  assert_output "en"
}

@test "既にある PR テンプレートを検出し、リポジトリの規約で上書きできる" {
  mkdir -p .github
  touch .github/pull_request_template.md
  run_script config.sh .pr.template
  assert_output ".github/pull_request_template.md"

  echo '{"pr": {"template": "docs/pr.md"}}' >.claude/dev-workflow/config.json
  run_script config.sh .pr.template
  assert_output "docs/pr.md"
}

@test "commitlint の設定を検出する" {
  touch commitlint.config.js
  run_script config.sh .detected.commitlint
  assert_output "commitlint.config.js"
}

@test "ガイドはユーザー → リポジトリの順に並ぶ" {
  mark_set_up
  mkdir -p .claude/dev-workflow
  echo user >"$WORKFLOW_USER_DIR/commit.md"
  echo repo >.claude/dev-workflow/commit.md
  run_script config.sh '.guides.commit[1]'
  assert_output "$REPO/.claude/dev-workflow/commit.md"
  run_script config.sh '.guides.commit[0]'
  assert_output "$WORKFLOW_USER_DIR/commit.md"
}

@test "明示的な null で既定値を消せる" {
  echo '{"status": {"done": null}}' >.claude/dev-workflow/config.json
  run_script config.sh .status.done
  assert_output "null"
}

@test "JSON として読めない設定はエラーになる" {
  echo '{broken' >.claude/dev-workflow/config.json
  run_script config.sh
  assert_failure 2
  assert_output --partial "JSON のオブジェクトとして読めません"
}

@test "オブジェクト以外の設定（配列・null・複数の値）はエラーになる" {
  mark_set_up
  for body in '[]' 'null' '{"a": 1}{"b": 2}'; do
    printf '%s\n' "$body" >"$WORKFLOW_USER_DIR/config.json"
    run_script config.sh
    assert_failure 2
    assert_output --partial "JSON のオブジェクトとして読めません"
  done
}

@test "WORKFLOW_REPO_ROOT を指定すると、今いる場所ではなくそのリポジトリの local を使う" {
  echo '{"language": "en"}' >.claude/dev-workflow/config.local.json
  git worktree add -q -b feat/1-x "$TMP/wt"
  mkdir -p "$TMP/other/.claude/dev-workflow"
  git -C "$TMP/other" init -q -b main
  echo '{"language": "fr"}' >"$TMP/other/.claude/dev-workflow/config.local.json"
  cd "$TMP/other"
  WORKFLOW_REPO_ROOT="$TMP/wt" run_script config.sh .language
  assert_output "en"
}

@test "テンプレートは大文字小文字を区別せずに検出し、実際のパスを返す" {
  mkdir -p docs .github/Issue_Template
  touch docs/PULL_REQUEST_TEMPLATE.md
  run_script config.sh '[.pr.template, .detected.issue_templates, .detected.pr_templates] | tojson'
  assert_success
  assert_output '["docs/PULL_REQUEST_TEMPLATE.md",".github/Issue_Template",null]'
}

@test "テンプレートのディレクトリの候補に、同じ名前のファイルは当てはめない" {
  mkdir -p .github
  touch .github/pull_request_template .github/ISSUE_TEMPLATE.md
  run_script config.sh '[.detected.pr_templates, .detected.issue_templates] | tojson'
  assert_output '[null,".github/ISSUE_TEMPLATE.md"]'
}

@test "テンプレートは拡張子を問わずに検出する（.txt・拡張子なし）" {
  mkdir -p .github docs
  touch .github/Pull_Request_Template.txt docs/ISSUE_TEMPLATE
  run_script config.sh '[.pr.template, .detected.issue_templates] | tojson'
  assert_output '[".github/Pull_Request_Template.txt","docs/ISSUE_TEMPLATE"]'
}

@test "拡張子を問わない候補でも、名前が前方一致するだけのファイルやディレクトリには当てはめない" {
  mkdir -p .github/PULL_REQUEST_TEMPLATE
  touch .github/pull_request_template_old.md .github/PULL_REQUEST_TEMPLATE/a.md
  run_script config.sh '[.pr.template, .detected.pr_templates] | tojson'
  assert_output '[null,".github/PULL_REQUEST_TEMPLATE"]'
}

@test "拡張子が .md・.txt・なし以外のファイル（バックアップや .yml）はテンプレートとみなさない" {
  mkdir -p .github
  touch .github/pull_request_template.md~ .github/issue_template.yml
  run_script config.sh '[.pr.template, .detected.issue_templates] | tojson'
  assert_output '[null,null]'
}

@test "review.max_rounds の既定は 3 で、上位の層で上書きできる" {
  run_script config.sh .review.max_rounds
  assert_success
  assert_output "3"
  echo '{"review": {"max_rounds": 5}}' >.claude/dev-workflow/config.json
  run_script config.sh .review.max_rounds
  assert_success
  assert_output "5"
}

@test "review.max_rounds の既定は 1 以上の整数（review スキルが前提にしている）" {
  run_script config.sh '.review.max_rounds | (type == "number" and . >= 1 and . == floor)'
  assert_success
  assert_output "true"
}

@test "review.model の既定は null（セッションと同じモデル）で、上位の層で指定できる" {
  run_script config.sh .review.model
  assert_success
  assert_output "null"
  echo '{"review": {"model": "opus"}}' >.claude/dev-workflow/config.local.json
  run_script config.sh .review.model
  assert_success
  assert_output "opus"
}

@test "導入していないリポジトリやリポジトリの外では、ユーザーの層（設定とガイド）を読まない" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo user >"$WORKFLOW_USER_DIR/commit.md"
  run_script config.sh '[.language, .guides, .sources] | tojson'
  assert_success
  assert_output "[\"ja\",{},[\"$(cd "$SCRIPTS/.." && pwd)/defaults/workflow.json\"]]"
  cd "$TMP"
  run_script config.sh '[.language, .guides] | tojson'
  assert_success
  assert_output '["ja",{}]'
  # 壊れたユーザーの層も読まないので、止まらない
  echo '{broken' >"$WORKFLOW_USER_DIR/config.json"
  run_script config.sh .language
  assert_success
  assert_output ja
}

@test "導入したリポジトリでは、ユーザーの層を読む（ワークツリーにチームの設定が無くても、メインのワークツリーにあれば導入した）" {
  echo '{"language": "en"}' >"$WORKFLOW_USER_DIR/config.json"
  echo user >"$WORKFLOW_USER_DIR/commit.md"
  mark_set_up
  run_script config.sh '[.language, .guides.commit] | tojson'
  assert_output "[\"en\",[\"$WORKFLOW_USER_DIR/commit.md\"]]"
  # 初期設定をコミットする前に作ったワークツリーには、チームの設定が無い
  git worktree add -q "$TMP/wt" -b feat/1-x
  cd "$TMP/wt"
  [ ! -f .claude/dev-workflow/config.json ]
  run_script config.sh '[.language, .guides.commit] | tojson'
  assert_output "[\"en\",[\"$WORKFLOW_USER_DIR/commit.md\"]]"
}

@test "base_branch が不正でも、ほかの項目は読める（base_branch は使う側の dw_base_branch で検査する）" {
  echo '{"base_branch": "-foo"}' >.claude/dev-workflow/config.json
  run_script config.sh .status.start
  assert_success
  assert_output "In Progress"
}
