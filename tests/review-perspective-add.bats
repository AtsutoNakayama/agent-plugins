#!/usr/bin/env bats

load test_helper

PLUGIN_REVIEW="$(cd "$BATS_TEST_DIRNAME/../plugins/dev-workflow/review" && pwd)"

# 使い方: add <本文> <引数...> → 本文を標準入力に渡して review-perspective-add.sh を実行する
add() {
  local body="$1"
  shift
  run "${TEST_BASH:-bash}" "$SCRIPTS/review-perspective-add.sh" "$@" <<<"$body"
}

@test "user の層に観点ファイルを作り、review-perspectives.sh で使われる" {
  mark_set_up
  add $'差分の中の TODO を探す。\n\n見つからなければ [] を返す。' --name todo-left --layer user --title "TODO が残っていないか"
  assert_success
  assert_equal "$(jq -c '[.name, .layer, .path, .overrides, .shadowed_by]' <<<"$output")" \
    "[\"todo-left\",\"user\",\"$WORKFLOW_USER_DIR/review/todo-left.md\",[],[]]"
  assert_equal "$(cat "$WORKFLOW_USER_DIR/review/todo-left.md")" \
    "$(printf -- '---\ntitle: TODO が残っていないか\n---\n\n差分の中の TODO を探す。\n\n見つからなければ [] を返す。')"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c '.perspectives[] | select(.name == "todo-left") | [.title, .layer]' <<<"$output")" \
    '["TODO が残っていないか","user"]'
  assert_equal "$(jq -c '.invalid' <<<"$output")" "[]"
}

@test "repo の層にはリポジトリの .claude/dev-workflow/review/ に作る（無ければディレクトリを作る）" {
  add "指示" --name repo-only --layer repo --title "リポジトリの観点"
  assert_success
  assert_equal "$(jq -r '.path' <<<"$output")" "$REPO/.claude/dev-workflow/review/repo-only.md"
  [ -f "$REPO/.claude/dev-workflow/review/repo-only.md" ] || fail "ファイルがありません"
}

@test "repo の層に base_branch の上で作ると、work_branch が false になる" {
  add "指示" --name on-main --layer repo --title "観点"
  assert_success
  assert_equal "$(jq -c '[.branch, .work_branch]' <<<"$output")" '["main",false]'
}

@test "repo の層に作業用のブランチのワークツリーで作ると、そのワークツリーにでき、work_branch が true になる" {
  git -C "$REPO" worktree add -q -b feat/1-x "$TMP/wt"
  cd "$TMP/wt"
  add "指示" --name in-task --layer repo --title "観点"
  assert_success
  assert_equal "$(jq -c '[.path, .branch, .work_branch]' <<<"$output")" \
    "[\"$TMP/wt/.claude/dev-workflow/review/in-task.md\",\"feat/1-x\",true]"
  [ ! -e "$REPO/.claude/dev-workflow/review/in-task.md" ] || fail "メインのワークツリーに作っています"
}

@test "base_branch を設定で変えていれば、それを作業用のブランチとみなさない" {
  printf '{"base_branch": "develop"}\n' >"$REPO/.claude/dev-workflow/config.json"
  git -C "$REPO" switch -q -c develop
  add "指示" --name on-develop --layer repo --title "観点"
  assert_success
  assert_equal "$(jq -c '[.branch, .work_branch]' <<<"$output")" '["develop",false]'
}

@test "設定ファイルが壊れていても repo の層に観点を作り、work_branch は null にして警告する" {
  printf '{ broken\n' >"$REPO/.claude/dev-workflow/config.json"
  add "指示" --name broken-config --layer repo --title "観点"
  assert_success
  [ -f "$REPO/.claude/dev-workflow/review/broken-config.md" ] || fail "ファイルがありません"
  assert_equal "$(jq -c '[.branch, .work_branch]' <<<"$(printf '%s\n' "$output" | sed -n '/^{/,$p')")" '["main",null]'
  assert_output --partial "warn: "
}

@test "base_branch が使えない値でも repo の層に観点を作り、work_branch は null にして警告する（その値と比べない）" {
  for v in null 1 '"-foo"'; do
    echo "{\"base_branch\": $v}" >"$REPO/.claude/dev-workflow/config.json"
    rm -f "$REPO/.claude/dev-workflow/review/bad-base.md"
    add "指示" --name bad-base --layer repo --title "観点"
    assert_success
    assert_equal "$(jq -c '[.branch, .work_branch]' <<<"$(printf '%s\n' "$output" | sed -n '/^{/,$p')")" '["main",null]'
    assert_output --partial "warn: 作業用のブランチの上かは分かりません（設定の base_branch が"
  done
  assert_output --partial "使えません: -foo"
}

@test "repo の層に detached HEAD で作ると、branch が null で work_branch が false になる" {
  git -C "$REPO" switch -q --detach
  add "指示" --name detached --layer repo --title "観点"
  assert_success
  assert_equal "$(jq -c '[.branch, .work_branch]' <<<"$output")" '[null,false]'
}

@test "user の層に作ると、branch と work_branch は null になる" {
  mark_set_up
  add "指示" --name mine-only --layer user --title "観点"
  assert_success
  assert_equal "$(jq -c '[.branch, .work_branch]' <<<"$output")" '[null,null]'
}

@test "同じ層に同じ名前の観点があれば、上書きせずに止まる" {
  mkdir -p "$WORKFLOW_USER_DIR/review"
  printf 'もとの内容\n' >"$WORKFLOW_USER_DIR/review/mine.md"
  add "新しい指示" --name mine --layer user --title "新しい観点" --override
  assert_failure 3
  assert_output --partial "$WORKFLOW_USER_DIR/review/mine.md"
  assert_equal "$(cat "$WORKFLOW_USER_DIR/review/mine.md")" "もとの内容"
}

@test "ほかの層に同じ名前の観点があれば、--override が無いと何も作らずに止まる" {
  add "指示" --name docs-sync --layer user --title "自分の版"
  assert_failure 4
  assert_output --partial "$PLUGIN_REVIEW/docs-sync.md"
  [ ! -e "$WORKFLOW_USER_DIR/review/docs-sync.md" ] || fail "ファイルを作っています"
}

@test "--override で下位の層の観点を置き換え、上位の層にあれば shadowed_by に出す" {
  mark_set_up
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\ntitle: リポジトリの版\n---\n\n指示\n' >"$REPO/.claude/dev-workflow/review/docs-sync.md"
  add "指示" --name docs-sync --layer user --title "自分の版" --override
  assert_success
  assert_equal "$(jq -c '[.overrides, .shadowed_by]' <<<"$output")" \
    "[[\"$PLUGIN_REVIEW/docs-sync.md\"],[\"$REPO/.claude/dev-workflow/review/docs-sync.md\"]]"
}

@test "git のリポジトリの外では repo の層に置けない" {
  cd "$TMP"
  add "指示" --name outside --layer repo --title "観点"
  assert_failure 2
}

@test "名前・title・本文・層が正しくなければ、何も作らずに止まる" {
  add "指示" --name Bad_Name --layer user --title "観点"
  assert_failure 64
  add "指示" --name $'ok\nBAD' --layer user --title "観点"
  assert_failure 64
  add "指示" --name ok --layer user --title "  "
  assert_failure 64
  add "指示" --name ok --layer user --title $'1行目\n2行目'
  assert_failure 64
  add "  " --name ok --layer user --title "観点"
  assert_failure 64
  add "指示" --name ok --layer plugin --title "観点"
  assert_failure 64
  add "指示" --name ok --layer user
  assert_failure 64
  [ ! -e "$WORKFLOW_USER_DIR/review" ] || fail "何か作っています: $(ls -R "$WORKFLOW_USER_DIR/review")"
}

@test "引用符で囲んだ title は、読むときに引用符が外れるので受け付けない" {
  add "指示" --name quoted --layer user --title '""'
  assert_failure 64
  add "指示" --name quoted --layer user --title "'観点'"
  assert_failure 64
  add "指示" --name quoted --layer user --title '"A" と "B"'
  assert_failure 64
  [ ! -e "$WORKFLOW_USER_DIR/review/quoted.md" ] || fail "ファイルを作っています"
  add "指示" --name quoted --layer user --title '"A" を確かめるか'
  assert_success
}

@test "上位の層に同じ名前の観点があれば、下位の層とは別の終了コードで止まる" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\ntitle: リポジトリの版\n---\n\n指示\n' >"$REPO/.claude/dev-workflow/review/mine.md"
  add "指示" --name mine --layer user --title "自分の版"
  assert_failure 5
  assert_output --partial "$REPO/.claude/dev-workflow/review/mine.md"
  [ ! -e "$WORKFLOW_USER_DIR/review/mine.md" ] || fail "ファイルを作っています"
}

@test "上位と下位の両方の層にあれば、使われないことを優先して知らせる" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\ntitle: リポジトリの版\n---\n\n指示\n' >"$REPO/.claude/dev-workflow/review/docs-sync.md"
  add "指示" --name docs-sync --layer user --title "自分の版"
  assert_failure 5
  # --override で作り直すと下位の層の観点も置き換わるので、そのファイルも知らせる
  assert_output --partial "$PLUGIN_REVIEW/docs-sync.md"
}

@test "置く場所に壊れたシンボリックリンクがあれば、既にあるものとして止まる" {
  mkdir -p "$WORKFLOW_USER_DIR/review"
  ln -s "$TMP/nowhere/x.md" "$WORKFLOW_USER_DIR/review/link.md"
  add "指示" --name link --layer user --title "観点"
  assert_failure 3
}

@test "書き込めないときは、既にあるときと別の終了コードで止まる" {
  printf 'ファイル\n' >"$WORKFLOW_USER_DIR/review"
  add "指示" --name cannot --layer user --title "観点"
  assert_failure 1
  assert_output --partial "$WORKFLOW_USER_DIR/review"
}

@test "ディレクトリに書き込む権限が無いときも、既にあるときと別の終了コードで止まる" {
  [ "$(id -u)" != 0 ] || skip "root は権限に関係なく書き込める"
  mkdir -p "$WORKFLOW_USER_DIR/review"
  chmod 555 "$WORKFLOW_USER_DIR/review"
  add "指示" --name cannot --layer user --title "観点"
  chmod 755 "$WORKFLOW_USER_DIR/review"
  assert_failure 1
}

@test "条件を付けて作ると frontmatter に書き、review-perspectives.sh がその条件で外す" {
  add "指示" --name cond --layer repo --title "条件つき" --type fix --type perf --path '**/*.sh' --path '!docs/**' \
    --issue-required --base-ahead-required
  assert_success
  assert_equal "$(cat "$REPO/.claude/dev-workflow/review/cond.md")" "$(printf -- '%s\n' '---' 'title: 条件つき' \
    'types: [fix, perf]' 'paths: ["**/*.sh", "!docs/**"]' 'issue: required' 'base_ahead: required' '---' '' '指示')"
  base="$(git rev-parse HEAD)"
  git commit -q --allow-empty -m later
  echo x >a.sh && git add a.sh
  run_script review-perspectives.sh --base "$base" --target HEAD --type feat --issue 1
  assert_success
  assert_equal "$(jq -r '.skipped[] | select(.name == "cond") | .reason' <<<"$output")" \
    "type（feat）が types（fix、perf）のどれでもない"
  run_script review-perspectives.sh --base "$base" --target HEAD --type perf --issue 1
  assert_success
  jq -e '.perspectives | any(.name == "cond")' <<<"$output" >/dev/null || fail "$output"
}

@test "書いたとおりに読めない条件は、何も作らずに止まる" {
  add "指示" --name ok --layer user --title "観点" --type Fix
  assert_failure 64
  add "指示" --name ok --layer user --title "観点" --path 'a,b'
  assert_failure 64
  add "指示" --name ok --layer user --title "観点" --path '"a"'
  assert_failure 64
  add "指示" --name ok --layer user --title "観点" --path ' a'
  assert_failure 64
  add "指示" --name ok --layer user --title "観点" --path ''
  assert_failure 64
  add "指示" --name ok --layer user --title "観点" --path '/etc/*'
  assert_failure 64
  add "指示" --name ok --layer user --title "観点" --path '!../x'
  assert_failure 64
  add "指示" --name ok --layer user --title "観点" --path '!'
  assert_failure 64
  add "指示" --name ok --layer user --title "観点" --type
  assert_failure 64
  [ ! -e "$WORKFLOW_USER_DIR/review" ] || fail "何か作っています"
}

@test "--builtin code-review で、同梱の code-review を置き換える観点を作り、builtin の観点として使われる" {
  add $'## 指摘しないこと\n\n- tests/*.bats の grep による検査の書き方' --name code-review --layer repo \
    --title "一般的なバグ（組み込みの /code-review）" --builtin code-review --override
  assert_success
  assert_equal "$(jq -c '.overrides' <<<"$output")" "[\"$PLUGIN_REVIEW/code-review.md\"]"
  assert_equal "$(cat "$REPO/.claude/dev-workflow/review/code-review.md")" "$(printf -- '%s\n' '---' \
    'title: 一般的なバグ（組み込みの /code-review）' 'builtin: code-review' '---' '' '## 指摘しないこと' '' \
    '- tests/*.bats の grep による検査の書き方')"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c '.perspectives[] | select(.name == "code-review") | [.layer, .builtin]' <<<"$output")" \
    '["repo","code-review"]'
  assert_equal "$(jq -c '.invalid' <<<"$output")" "[]"
}

@test "--builtin は code-review だけを受け付け、何も作らずに止まる" {
  add "指示" --name ok --layer user --title "観点" --builtin other
  assert_failure 64
  assert_output --partial "--builtin は code-review にしてください"
  add "指示" --name ok --layer user --title "観点" --builtin
  assert_failure 64
  # 別の名前では、/code-review が2回動き、除外の決まりも読まれない
  add "指示" --name code-review-mine --layer user --title "観点" --builtin code-review
  assert_failure 64
  assert_output --partial "--builtin code-review は --name code-review のときだけ使えます"
  [ ! -e "$WORKFLOW_USER_DIR/review" ] || fail "何か作っています"
}

@test "導入していないリポジトリで user の層に作ると、ここでは使われないことを警告する" {
  add "指示" --name mine --layer user --title "自分の観点"
  assert_success
  assert_output --partial "warn: このリポジトリにはプラグインを導入していない"
  [ -f "$WORKFLOW_USER_DIR/review/mine.md" ]
  mark_set_up
  add "指示" --name mine2 --layer user --title "自分の観点"
  assert_success
  refute_output --partial "warn:"
}

@test "導入していないリポジトリの repo の層に作るときは、使われないユーザーの層の同じ名前の観点を数えない" {
  mkdir -p "$WORKFLOW_USER_DIR/review"
  printf -- '---\ntitle: 自分の版\n---\n\n指示\n' >"$WORKFLOW_USER_DIR/review/mine.md"
  add "指示" --name mine --layer repo --title "リポジトリの版"
  assert_success
  assert_equal "$(jq -c '[.overrides, .shadowed_by]' <<<"$output")" '[[],[]]'
  # 導入したリポジトリでは、置き換えるか確かめる
  mark_set_up
  add "指示" --name mine --layer repo --title "リポジトリの版" 2>&1
  assert_failure 3
  rm "$REPO/.claude/dev-workflow/review/mine.md"
  add "指示" --name mine --layer repo --title "リポジトリの版"
  assert_failure 4
  assert_output --partial "$WORKFLOW_USER_DIR/review/mine.md"
}

@test "リポジトリの外で user の層に作るときは、導入していないという警告を出さない" {
  cd "$TMP"
  add "指示" --name mine --layer user --title "自分の観点"
  assert_success
  refute_output --partial "warn:"
  [ -f "$WORKFLOW_USER_DIR/review/mine.md" ]
}
