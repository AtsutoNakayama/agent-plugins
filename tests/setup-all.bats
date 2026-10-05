#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# プラグインを一時ディレクトリにコピーし、setup-labels / setup-project / setup-repo / setup-models を偽物に差し替える。
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
  for name in labels project repo models; do
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
  echo '{"review": {"model": null, "decided": false, "layers": []}, "file": null, "changed": false, "actions": []}' >"$FIX/setup-models.json"
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

@test "4つのスクリプトにオプションを振り分けて実行する" {
  setup_fake_plugin
  run_all --keep-defaults --number 3 --title Board --require-approval 1 --review-model opus --models-scope local
  assert_success
  assert_equal "$(args_of setup-labels)" "[--keep-defaults]"
  assert_equal "$(args_of setup-project)" "[--write-config] [--number] [3] [--title] [Board]"
  assert_equal "$(args_of setup-repo)" "[--require-approval] [1]"
  assert_equal "$(args_of setup-models)" "[--review-model] [opus] [--scope] [local]"
}

@test "setup-models.sh の出力を models に入れる" {
  setup_fake_plugin
  echo '{"review": {"model": "opus", "decided": true, "layers": []}, "file": null, "changed": false, "actions": []}' >"$FIX/setup-models.json"
  run_all
  assert_success
  assert_equal "$(jq -r .models.review.model <<<"$json")" opus
}

@test "dry-run で、レビューのモデルをチームの層に書く予定なら、.claude/dev-workflow/config.json のコミットを案内する" {
  setup_fake_plugin
  committed_config '{"project": {"owner": "me", "number": 3}}'
  echo '{"actions": [], "project": {"owner": "me", "number": 3, "created": false}, "workflows": {"auto_add": true}}' >"$FIX/setup-project.json"
  jq -n --arg f "$REPO/.claude/dev-workflow/config.json" '{review: {model: "opus"}, file: $f, changed: true, actions: ["x"]}' \
    >"$FIX/setup-models.json"
  run_all --dry-run --review-model opus --models-scope team
  assert_success
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/dev-workflow/config.json をコミットし、PR で main にマージする"

  # 個人の層（config.local.json）に書く予定なら、コミットは要らない
  jq -n --arg f "$REPO/.claude/dev-workflow/config.local.json" '{review: {model: "opus"}, file: $f, changed: true, actions: ["x"]}' \
    >"$FIX/setup-models.json"
  run_all --dry-run --review-model opus --models-scope local
  assert_success
  assert_equal "$(jq -c .next_steps <<<"$json")" '[]'
}

@test "--required-check は何度でも指定でき、setup-repo.sh に渡す" {
  setup_fake_plugin
  run_all --required-check lint-result --required-check test-result
  assert_success
  assert_equal "$(args_of setup-repo)" "[--required-check] [lint-result] [--required-check] [test-result]"
}

@test "--merge-queue と --no-merge-queue を setup-repo.sh に渡す" {
  setup_fake_plugin
  run_all --merge-queue
  assert_success
  assert_equal "$(args_of setup-repo)" "[--merge-queue]"
  run_all --no-merge-queue
  assert_success
  assert_equal "$(args_of setup-repo)" "[--no-merge-queue]"
}

@test "オプションが無くても実行できる（bash 3.2 の空の配列）" {
  setup_fake_plugin
  run_all
  assert_success
  assert_equal "$(args_of setup-labels)" ""
  assert_equal "$(args_of setup-project)" "[--write-config]"
}

@test "--models-scope だけを付けると、その名前で使い方の誤り（64）にする" {
  setup_fake_plugin
  run_all --models-scope local
  assert_failure 64
  assert_output --partial "--models-scope は --review-model と一緒に使ってください"
  assert_equal "$(wc -l <"$CALLS" | tr -d ' ')" 0
}

@test "個人の設定が git に無視されていなければ、.gitignore に足すよう案内する" {
  setup_fake_plugin
  echo '{"review": {"model": "opus"}, "file": "x", "changed": true, "ignored": false, "actions": []}' >"$FIX/setup-models.json"
  run_all --review-model opus --models-scope local
  assert_success
  jq -e '.next_steps | any(test("config.local.json（個人の設定）が git に無視されていないので、.gitignore に足す"))' <<<"$json" >/dev/null \
    || fail "next_steps に .gitignore の案内がありません: $json"
}

@test "--dry-run は4つすべてに渡し、テンプレートを作らない" {
  setup_fake_plugin
  run_all --dry-run
  assert_success
  assert_equal "$(grep -c -- '\[--dry-run\]' "$CALLS")" 4
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

@test "作ったファイルと、変わった .claude/dev-workflow/config.json を PR でマージするよう案内する" {
  setup_fake_plugin
  echo '{}' >.claude/dev-workflow/config.json
  run_all
  assert_success
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" \
    ".github/pull_request_template.md・.github/ISSUE_TEMPLATE/task.md・.claude/dev-workflow/config.json をコミットし、PR で main にマージする"
}

# テンプレートを既にあるものとし、.claude/dev-workflow/config.json をコミットした状態にする。使い方: committed_config <JSON>
committed_config() {
  mkdir -p .github/ISSUE_TEMPLATE
  touch .github/pull_request_template.md .github/ISSUE_TEMPLATE/x.md
  echo "$1" >.claude/dev-workflow/config.json
  git add .claude/dev-workflow/config.json
  git -c user.name=t -c user.email=t@example.com commit -q -m config
}

@test "dry-run では、.claude/dev-workflow/config.json の project が変わるときだけ案内する" {
  setup_fake_plugin
  committed_config '{"project": {"owner": "me", "number": 3}}'
  echo '{"actions": [], "project": {"owner": "me", "number": 3, "created": false}, "workflows": {"auto_add": true}}' >"$FIX/setup-project.json"
  run_all --dry-run
  assert_success
  assert_equal "$(jq -c .next_steps <<<"$json")" '[]'

  echo '{"project": {"owner": "me", "number": 2}}' >.claude/dev-workflow/config.json
  git -c user.name=t -c user.email=t@example.com commit -q -am config2
  run_all --dry-run
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/dev-workflow/config.json をコミットし、PR で main にマージする"
}

@test "dry-run で Project を新しく作る予定なら、owner だけの設定でも変わるとみなす" {
  setup_fake_plugin
  committed_config '{"project": {"owner": "me", "number": null}}'
  echo '{"actions": [], "project": {"owner": "me", "created": true}, "workflows": {"auto_add": null}}' >"$FIX/setup-project.json"
  run_all --dry-run
  assert_success
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/dev-workflow/config.json をコミットし、PR で main にマージする"
}

@test "dry-run で .claude/dev-workflow/config.json が未コミットなら、中身が同じでもコミットを案内する" {
  setup_fake_plugin
  committed_config '{"project": {"owner": "me", "number": 3}}'
  git rm -q --cached .claude/dev-workflow/config.json
  echo '{"actions": [], "project": {"owner": "me", "number": 3, "created": false}, "workflows": {"auto_add": true}}' >"$FIX/setup-project.json"
  run_all --dry-run
  assert_success
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/dev-workflow/config.json をコミットし、PR で main にマージする"
}

@test "git に無視された .claude/dev-workflow/config.json も、中身が変われば案内し、.gitignore を直すよう伝える" {
  setup_fake_plugin
  mkdir -p .github/ISSUE_TEMPLATE
  touch .github/pull_request_template.md .github/ISSUE_TEMPLATE/x.md
  echo '.claude/' >.gitignore
  echo '{}' >.claude/dev-workflow/config.json
  # 偽の setup-project が、本番（dry-run でないとき）だけ project を書き込む
  cat >>"$PLUGIN/scripts/setup/setup-project.sh" <<'SH'
case " $* " in *" --dry-run "*) ;; *) echo '{"project": {"owner": "me", "number": 3}}' >.claude/dev-workflow/config.json ;; esac
SH
  run_all
  assert_success
  assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/dev-workflow/config.json をコミットし、PR で main にマージする"
  assert_equal "$(jq -r '.next_steps[1]' <<<"$json")" \
    ".claude/dev-workflow/config.json が git に無視されているので、.gitignore で無視を外す（例：.claude/ を .claude/* に変えて、!.claude/dev-workflow/ と .claude/dev-workflow/config.local.json をこの順に足す）"
  assert_output --partial "git に無視されているのでコミットできません: .claude/dev-workflow/config.json"
  # 例のとおりに直すと、チームの設定はコミットでき、個人の設定は無視されたままになる
  printf '%s\n' '.claude/*' '!.claude/dev-workflow/' '.claude/dev-workflow/config.local.json' >.gitignore
  echo '{}' >.claude/dev-workflow/config.local.json
  run git check-ignore -q .claude/dev-workflow/config.json
  assert_failure
  run git check-ignore -q .claude/dev-workflow/config.local.json
  assert_success
}

@test "git に無視され、管理もされていない .claude/dev-workflow/config.json は、中身が変わらなくても案内する" {
  setup_fake_plugin
  mkdir -p .github/ISSUE_TEMPLATE
  touch .github/pull_request_template.md .github/ISSUE_TEMPLATE/x.md
  echo '.claude/' >.gitignore
  echo '{"project": {"owner": "me", "number": 3}}' >.claude/dev-workflow/config.json
  echo '{"actions": [], "project": {"owner": "me", "number": 3, "created": false}, "workflows": {"auto_add": true}}' >"$FIX/setup-project.json"
  for mode in --dry-run ""; do
    run_all ${mode:+"$mode"}
    assert_success
    assert_equal "$(jq -r '.next_steps[0]' <<<"$json")" ".claude/dev-workflow/config.json をコミットし、PR で main にマージする"
    assert_output --partial "git に無視されているのでコミットできません: .claude/dev-workflow/config.json"
  done
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
  FAKE_FAIL=setup-models run_all
  assert_failure 1
  assert_output --partial "setup-models failed"
  assert_output --partial "何も変更していません"
  # 4つとも dry-run でだけ呼ばれている
  assert_equal "$(grep -c -- '\[--dry-run\]' "$CALLS")" 4
  assert_equal "$(wc -l <"$CALLS" | tr -d ' ')" 4
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
  echo '{"pr": {"template": null}}' >.claude/dev-workflow/config.json
  run_all
  assert_success
  # macOS は大文字小文字を区別しないので、ファイルの有無ではなく中身と数で確かめる
  assert_equal "$(cat .github/Pull_Request_Template.md)" mine
  assert_equal "$(find .github -maxdepth 1 -iname 'pull_request_template.md' | wc -l | tr -d ' ')" 1
  assert_equal "$(jq -r '.templates.skipped[0].existing' <<<"$json")" ".github/Pull_Request_Template.md"
}

@test "個人の設定の pr.template があっても、リポジトリに無ければテンプレートを作る" {
  setup_fake_plugin
  echo '{"pr": {"template": "mine.md"}}' >"$WORKFLOW_USER_DIR/config.json"
  echo '{"pr": {"template": "local.md"}}' >.claude/dev-workflow/config.local.json
  run_all
  assert_success
  cmp .github/pull_request_template.md "$PLUGIN/templates/pull_request_template.md"
}

@test "チームの設定で pr.template が null でも、docs やリポジトリ直下のテンプレートがあれば作らない" {
  setup_fake_plugin
  mkdir -p docs
  echo mine >docs/PULL_REQUEST_TEMPLATE.md
  echo '{"pr": {"template": null}}' >.claude/dev-workflow/config.json
  run_all
  assert_success
  [ ! -e .github/pull_request_template.md ]
  assert_equal "$(jq -r '.templates.skipped[0].existing' <<<"$json")" "docs/PULL_REQUEST_TEMPLATE.md"
}

@test "チームの設定の pr.template が実在するファイルを指定していれば、PR テンプレートを作らない" {
  setup_fake_plugin
  mkdir -p .github/templates
  echo team >.github/templates/pr.md
  echo '{"pr": {"template": ".github/templates/pr.md"}}' >.claude/dev-workflow/config.json
  run_all
  assert_success
  [ ! -e .github/pull_request_template.md ]
  assert_equal "$(jq -r '.templates.skipped[0].existing' <<<"$json")" ".github/templates/pr.md"
}

@test "チームの設定の pr.template が無いファイルを指していれば、PR テンプレートを作る" {
  setup_fake_plugin
  echo '{"pr": {"template": ".github/templates/missing.md"}}' >.claude/dev-workflow/config.json
  run_all
  assert_success
  cmp .github/pull_request_template.md "$PLUGIN/templates/pull_request_template.md"
}

@test "チームの設定の pr.template がリポジトリの外を指していれば、PR テンプレートを作る" {
  setup_fake_plugin
  echo outside >"$TMP/outside.md"
  for path in "$TMP/outside.md" ../outside.md; do
    rm -rf .github
    jq -n --arg p "$path" '{pr: {template: $p}}' >.claude/dev-workflow/config.json
    run_all
    assert_success
    cmp .github/pull_request_template.md "$PLUGIN/templates/pull_request_template.md"
  done
}

@test ".md 以外の拡張子の PR テンプレートがあれば作らない" {
  setup_fake_plugin
  echo mine >pull_request_template.txt
  run_all
  assert_success
  [ ! -e .github/pull_request_template.md ]
  assert_equal "$(jq -r '.templates.skipped[0].existing' <<<"$json")" "pull_request_template.txt"
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
