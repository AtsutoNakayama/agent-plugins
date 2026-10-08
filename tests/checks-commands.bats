#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

TEAM=.claude/dev-workflow/config.json
LOCAL=.claude/dev-workflow/config.local.json

@test "設定が無ければ commands は null で、手がかりは空になる" {
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c '[.commands, .hints.contributing, .hints.package_scripts, .hints.makefile_targets, .hints.ci_workflows, .hints.project_files]' <<<"$output")" \
    '[null,null,null,[],[],[]]'
}

@test "package.json・Makefile・CI・CONTRIBUTING.md・言語の設定ファイルから手がかりを出す（CONTRIBUTING.md が無くても出る）" {
  echo '{"scripts": {"test": "jest", "lint:fix": "eslint --fix .", "start": "node ."}}' >package.json
  printf 'VAR=1\ntest:\n\tbats tests\nlint-all: a\nother:\ntest-x := 1\ntest:=1\n' >Makefile
  mkdir -p .github/workflows
  : >.github/workflows/ci.yml
  : >go.mod
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c .hints <<<"$output")" \
    '{"contributing":null,"package_scripts":{"test":"jest","lint:fix":"eslint --fix ."},"makefile_targets":["lint-all","test"],"ci_workflows":[".github/workflows/ci.yml"],"project_files":["go.mod"]}'
  : >CONTRIBUTING.md
  run_script checks-commands.sh
  assert_equal "$(jq -r .hints.contributing <<<"$output")" CONTRIBUTING.md
}

@test "壊れた package.json は止まる" {
  echo '{' >package.json
  run_script checks-commands.sh
  assert_failure 2
}

@test "設定の checks.commands があれば、それを出し、手がかりは調べない" {
  echo '{"scripts": {"test": "jest"}}' >package.json
  echo '{"checks": {"commands": ["make lint", "make test"]}}' >"$TEAM"
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c '[.commands, .hints]' <<<"$output")" '[["make lint","make test"],null]'
}

@test "空の配列は、実行するものが無いと決めてあることとして出す" {
  echo '{"checks": {"commands": []}}' >"$TEAM"
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c '[.commands, .hints]' <<<"$output")" '[[],null]'
}

@test "個人の設定（local）が、チームの設定より優先される" {
  echo '{"checks": {"commands": ["make test"]}}' >"$TEAM"
  echo '{"checks": {"commands": ["make lint"]}}' >"$LOCAL"
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c .commands <<<"$output")" '["make lint"]'
}

@test "checks.commands が配列でない・文字列でない・空の要素があれば止まる" {
  for v in '"make test"' '[1]' '[""]' '["  "]' '{}'; do
    echo "{\"checks\": {\"commands\": $v}}" >"$TEAM"
    run_script checks-commands.sh
    assert_failure 2
  done
}

@test "--save --scope team は、ほかの項目を残して config.json に書き、次から読める" {
  echo '{"language": "en", "checks": {"other": 1}}' >"$TEAM"
  run_script checks-commands.sh --save --scope team --command "make lint" --command "bats tests"
  assert_success
  assert_equal "$(jq -c '[.commands, .saved.scope, .saved.commands, .hints]' <<<"$output")" \
    '[["make lint","bats tests"],"team",["make lint","bats tests"],null]'
  assert_equal "$(jq -c '[.language, .checks]' "$TEAM")" '["en",{"other":1,"commands":["make lint","bats tests"]}]'
  run_script checks-commands.sh
  assert_equal "$(jq -c .commands <<<"$output")" '["make lint","bats tests"]'
}

@test "--save --scope local は config.local.json に書き、git に無視されていなければ案内を出す" {
  run_script checks-commands.sh --save --scope local --command "make test"
  assert_success
  assert_equal "$(jq -c .checks.commands "$LOCAL")" '["make test"]'
  [ ! -e "$TEAM" ]
  jq -e '.saved.local_hint | test("gitignore")' <<<"$output" >/dev/null
  echo '.claude/dev-workflow/config.local.json' >.gitignore
  run_script checks-commands.sh --save --scope local --command "make test"
  assert_equal "$(jq -c .saved.local_hint <<<"$output")" null
}

@test "--save --none は、実行するものが無いと保存する" {
  run_script checks-commands.sh --save --scope team --none
  assert_success
  assert_equal "$(jq -c .checks.commands "$TEAM")" '[]'
  assert_equal "$(jq -c .commands <<<"$output")" '[]'
}

@test "引数の誤りは 64 で止まり、何も書かない" {
  run_script checks-commands.sh --save --command "make test"
  assert_failure 64
  run_script checks-commands.sh --save --scope other --command "make test"
  assert_failure 64
  run_script checks-commands.sh --save --scope team
  assert_failure 64
  run_script checks-commands.sh --save --scope team --none --command "make test"
  assert_failure 64
  run_script checks-commands.sh --save --scope team --command ""
  assert_failure 64
  run_script checks-commands.sh --save --scope team --command "  "
  assert_failure 64
  run_script checks-commands.sh --save --scope team --command $'a\nb'
  assert_failure 64
  run_script checks-commands.sh --scope team
  assert_failure 64
  run_script checks-commands.sh --bogus
  assert_failure 64
  [ ! -e "$TEAM" ] || [ "$(jq -c '.checks // null' "$TEAM")" = null ]
  [ ! -e "$LOCAL" ]
}

@test "package.json の scripts がオブジェクトでなくても止まらず、package_scripts は空になる" {
  echo '{"scripts": []}' >package.json
  run_script checks-commands.sh
  assert_success
  assert_equal "$(jq -c .hints.package_scripts <<<"$output")" '{}'
}

@test "--save は、checks がオブジェクトでない設定を壊さず、2 で止まる" {
  echo '{"checks": "make test"}' >"$TEAM"
  run_script checks-commands.sh --save --scope team --command "make test"
  assert_failure 2
  assert_equal "$(jq -c .checks "$TEAM")" '"make test"'
}

@test "--save は、優先される層が別の値を決めていて保存した値が使われないとき、warning を出す" {
  echo '{"checks": {"commands": ["make ci"]}}' >"$LOCAL"
  run_script checks-commands.sh --save --scope team --command "make test"
  assert_success
  assert_equal "$(jq -c '[.saved.commands, .commands]' <<<"$output")" '[["make test"],["make ci"]]'
  jq -e '.saved.warning | test("make ci")' <<<"$output" >/dev/null
  run_script checks-commands.sh --save --scope local --command "make ci"
  assert_equal "$(jq -c .saved.warning <<<"$output")" null
}

@test "--help に決め方（設定 → 推測 → 聞いて保存）が書かれている（スキルはここを指す）" {
  run_script checks-commands.sh --help
  assert_success
  assert_output --partial "commands が配列"
  assert_output --partial "hints"
  assert_output --partial "--save"
}
