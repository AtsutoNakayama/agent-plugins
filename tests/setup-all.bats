#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# プラグインを一時ディレクトリにコピーし、setup-labels / setup-project / setup-repo を偽物に差し替える。
# 偽物は受け取った引数を $CALLS に「<名前> [引数]...」で1行ずつ記録し、$FIX/<名前>.json を出力する。
# FAKE_FAIL に指定した名前の偽物は失敗する。
setup_fake_plugin() {
  PLUGIN="$TMP/plugin"
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$FIX"
  : >"$CALLS"
  cp -R "$BATS_TEST_DIRNAME/../plugins/dev-workflow" "$PLUGIN"
  for name in labels project repo; do
    cat >"$PLUGIN/scripts/setup/setup-$name.sh" <<SH
#!/usr/bin/env bash
printf 'setup-$name' >>"\$CALLS"
[ \$# -eq 0 ] || printf ' [%s]' "\$@" >>"\$CALLS"
echo >>"\$CALLS"
if [ "\${FAKE_FAIL:-}" = setup-$name ]; then echo "error: setup-$name failed" >&2; exit 1; fi
cat "\$FIX/setup-$name.json"
SH
  done
  echo '{"actions": []}' >"$FIX/setup-labels.json"
  echo '{"actions": [], "workflows": {"auto_add": true, "url": "https://example.com/w"}}' >"$FIX/setup-project.json"
  echo '{"actions": [], "branch": "main"}' >"$FIX/setup-repo.json"
}

run_all() {
  run "${TEST_BASH:-bash}" "$PLUGIN/scripts/setup/setup-all.sh" "$@"
  # bats は失敗したテストの標準出力だけを表示するので、原因を追えるよう出力を残す
  printf '%s\n' "$output"
  # 標準エラーの警告の後ろに出る JSON だけを取り出す
  # macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
  json="$(printf '%s\n' "$output" | LC_ALL=C sed -n '/^{/,$p')"
}

# 使い方: args_of <名前> → 最後の呼び出し（dry-run で確かめた後の本番）の引数
args_of() { grep "^$1" "$CALLS" | tail -n 1 | sed "s/^$1 \{0,1\}//"; }

@test "3つのスクリプトにオプションを振り分けて実行する" {
  setup_fake_plugin
  run_all --keep-defaults --number 3 --title Board --require-approval 1
  assert_success
  assert_equal "$(args_of setup-labels)" "[--keep-defaults]"
  assert_equal "$(args_of setup-project)" "[--write-config] [--number] [3] [--title] [Board]"
  assert_equal "$(args_of setup-repo)" "[--require-approval] [1]"
}

@test "オプションが無くても実行できる（bash 3.2 の空の配列）" {
  setup_fake_plugin
  run_all
  assert_success
  assert_equal "$(args_of setup-labels)" ""
  assert_equal "$(args_of setup-project)" "[--write-config]"
}

@test "--dry-run は3つすべてに渡し、テンプレートを作らない" {
  setup_fake_plugin
  run_all --dry-run
  assert_success
  assert_equal "$(grep -c -- '\[--dry-run\]' "$CALLS")" 3
  [ ! -e .github ]
  assert_equal "$(jq -c .templates.created <<<"$json")" '[".github/pull_request_template.md",".github/ISSUE_TEMPLATE/task.md"]'
}

@test "テンプレートが無ければ作る" {
  setup_fake_plugin
  run_all
  assert_success
  cmp .github/pull_request_template.md "$PLUGIN/templates/pull_request_template.md"
  cmp .github/ISSUE_TEMPLATE/task.md "$PLUGIN/templates/ISSUE_TEMPLATE/task.md"
}

@test "既にあるテンプレートは上書きせず、作らない" {
  setup_fake_plugin
  mkdir -p .github/ISSUE_TEMPLATE
  echo mine >.github/PULL_REQUEST_TEMPLATE.md
  echo bug >.github/ISSUE_TEMPLATE/bug.md
  run_all
  assert_success
  # macOS は大文字小文字を区別しないので、ファイルの有無ではなく中身と数で確かめる
  assert_equal "$(cat .github/PULL_REQUEST_TEMPLATE.md)" mine
  assert_equal "$(find .github -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" 2
  [ ! -e .github/ISSUE_TEMPLATE/task.md ]
  assert_equal "$(jq -c '[.templates.skipped[].existing]' <<<"$json")" '[".github/PULL_REQUEST_TEMPLATE.md",".github/ISSUE_TEMPLATE"]'
}

@test "作ったファイルと、変わった .claude/workflow.json を PR でマージするよう案内する" {
  setup_fake_plugin
  echo '{}' >.claude/workflow.json
  run_all
  assert_success
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" \
    ".github/pull_request_template.md・.github/ISSUE_TEMPLATE/task.md・.claude/workflow.json をコミットし、PR で main にマージする"
}

# テンプレートを既にあるものとし、.claude/workflow.json をコミットした状態にする。使い方: committed_config <JSON>
committed_config() {
  mkdir -p .github/ISSUE_TEMPLATE
  touch .github/pull_request_template.md .github/ISSUE_TEMPLATE/x.md
  echo "$1" >.claude/workflow.json
  git add .claude/workflow.json
  git -c user.name=t -c user.email=t@example.com commit -q -m config
}

@test "dry-run では、.claude/workflow.json の project が変わるときだけ案内する" {
  setup_fake_plugin
  committed_config '{"project": {"owner": "me", "number": 3}}'
  echo '{"actions": [], "project": {"owner": "me", "number": 3, "created": false}, "workflows": {"auto_add": true}}' >"$FIX/setup-project.json"
  run_all --dry-run
  assert_success
  assert_equal "$(jq -c .next_steps <<<"$json")" '[]'

  echo '{"project": {"owner": "me", "number": 2}}' >.claude/workflow.json
  git -c user.name=t -c user.email=t@example.com commit -q -am config2
  run_all --dry-run
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/workflow.json をコミットし、PR で main にマージする"
}

@test "dry-run で Project を新しく作る予定なら、owner だけの設定でも変わるとみなす" {
  setup_fake_plugin
  committed_config '{"project": {"owner": "me", "number": null}}'
  echo '{"actions": [], "project": {"owner": "me", "created": true}, "workflows": {"auto_add": null}}' >"$FIX/setup-project.json"
  run_all --dry-run
  assert_success
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/workflow.json をコミットし、PR で main にマージする"
}

@test "dry-run で .claude/workflow.json が未コミットなら、中身が同じでもコミットを案内する" {
  setup_fake_plugin
  committed_config '{"project": {"owner": "me", "number": 3}}'
  git rm -q --cached .claude/workflow.json
  echo '{"actions": [], "project": {"owner": "me", "number": 3, "created": false}, "workflows": {"auto_add": true}}' >"$FIX/setup-project.json"
  run_all --dry-run
  assert_success
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/workflow.json をコミットし、PR で main にマージする"
}

@test "git に無視された .claude/workflow.json も、中身が変われば案内し、.gitignore を直すよう伝える" {
  setup_fake_plugin
  mkdir -p .github/ISSUE_TEMPLATE
  touch .github/pull_request_template.md .github/ISSUE_TEMPLATE/x.md
  echo '.claude/' >.gitignore
  echo '{}' >.claude/workflow.json
  # 偽の setup-project が、本番（dry-run でないとき）だけ project を書き込む
  cat >>"$PLUGIN/scripts/setup/setup-project.sh" <<'SH'
case " $* " in *" --dry-run "*) ;; *) echo '{"project": {"owner": "me", "number": 3}}' >.claude/workflow.json ;; esac
SH
  run_all
  assert_success
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/workflow.json をコミットし、PR で main にマージする"
  assert_equal "$(jq -r '.next_steps[1]' <<<"$json")" \
    ".claude/workflow.json が git に無視されているので、.gitignore で無視を外す（例：.claude/ を .claude/* に変えて !.claude/workflow.json を足す）"
  assert_output --partial "git に無視されているのでコミットできません: .claude/workflow.json"
}

@test "自動追加が無効なら、有効にするよう案内する" {
  setup_fake_plugin
  echo '{"actions": [], "workflows": {"auto_add": false, "url": "https://example.com/w"}}' >"$FIX/setup-project.json"
  run_all
  assert_success
  assert_equal "$(jq -r '.next_steps[-1]' <<<"$json")" "自動追加（Auto-add to project）を https://example.com/w で有効にする"
}

@test "確認の dry-run で失敗したら、何も変更しない" {
  setup_fake_plugin
  FAKE_FAIL=setup-repo run_all
  assert_failure 1
  assert_output --partial "setup-repo failed"
  assert_output --partial "何も変更していません"
  # 3つとも dry-run でだけ呼ばれている
  assert_equal "$(grep -c -- '\[--dry-run\]' "$CALLS")" 3
  assert_equal "$(wc -l <"$CALLS" | tr -d ' ')" 3
  [ ! -e .github ]
}

@test "確認の dry-run の途中で失敗したら、残りのスクリプトは呼ばない" {
  setup_fake_plugin
  FAKE_FAIL=setup-labels run_all
  assert_failure 1
  assert_equal "$(args_of setup-project)" ""
}

@test "確認が通ったら、dry-run の後に本番を実行し、警告は1回だけ出す" {
  setup_fake_plugin
  sed -i.bak 's|^cat |echo "warn: w-setup-repo" >\&2; cat |' "$PLUGIN/scripts/setup/setup-repo.sh"
  run_all
  assert_success
  assert_equal "$(grep -c '^setup-repo' "$CALLS")" 2
  assert_equal "$(grep -c '^setup-repo \[--dry-run\]' "$CALLS")" 1
  assert_equal "$(grep -c 'w-setup-repo' <<<"$output")" 1
}

@test "チームの設定で pr.template が null でも、置き場所にあるテンプレートは上書きしない" {
  setup_fake_plugin
  mkdir -p .github
  echo mine >.github/Pull_Request_Template.md
  echo '{"pr": {"template": null}}' >.claude/workflow.json
  run_all
  assert_success
  # macOS は大文字小文字を区別しないので、ファイルの有無ではなく中身と数で確かめる
  assert_equal "$(cat .github/Pull_Request_Template.md)" mine
  assert_equal "$(find .github -maxdepth 1 -iname 'pull_request_template.md' | wc -l | tr -d ' ')" 1
  assert_equal "$(jq -r '.templates.skipped[0].existing' <<<"$json")" ".github/Pull_Request_Template.md"
}

@test "PR テンプレートのディレクトリや古い形式の Issue テンプレートがあれば作らない" {
  setup_fake_plugin
  mkdir -p .github/PULL_REQUEST_TEMPLATE
  touch .github/PULL_REQUEST_TEMPLATE/feature.md .github/ISSUE_TEMPLATE.md
  run_all
  assert_success
  assert_equal "$(jq -c '[.templates.skipped[].existing]' <<<"$json")" '[".github/PULL_REQUEST_TEMPLATE",".github/ISSUE_TEMPLATE.md"]'
  [ ! -e .github/pull_request_template.md ]
  [ ! -e .github/ISSUE_TEMPLATE/task.md ]
}

@test "リポジトリの外では終了コード 64" {
  setup_fake_plugin
  cd "$TMP"
  run_all
  assert_failure 64
}

@test "不明な引数は終了コード 64" {
  setup_fake_plugin
  run_all --repo me/demo
  assert_failure 64
}
