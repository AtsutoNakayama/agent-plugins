#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

PLUGIN_REVIEW="$(cd "$BATS_TEST_DIRNAME/../plugins/dev-workflow/review" && pwd)"

# 使い方: perspective <ディレクトリ> <名前> <title> [本文]
perspective() {
  mkdir -p "$1"
  printf -- '---\ntitle: %s\n---\n\n%s\n' "$3" "${4:-指示を書く}" >"$1/$2.md"
}

# 使い方: names <jq のパス> → 名前を1行ずつ
names() { jq -r "$1[].name" <<<"$output"; }

@test "同梱の観点はどれも形式に合う" {
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq '.invalid' <<<"$output")" "[]"
  for f in "$PLUGIN_REVIEW"/*.md; do
    jq -e --arg n "$(basename "$f" .md)" '.perspectives | any(.name == $n and .layer == "plugin")' <<<"$output" >/dev/null \
      || fail "$f が perspectives にありません"
  done
}

@test "3つの層の観点を合わせ、名前の順に出力する" {
  perspective "$WORKFLOW_USER_DIR/review" zz-user "ユーザーの観点"
  perspective "$REPO/.claude/dev-workflow/review" aa-repo "リポジトリの観点"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c '.perspectives[] | select(.name == "zz-user") | [.title, .layer, .path, .overrides]' <<<"$output")" \
    "[\"ユーザーの観点\",\"user\",\"$WORKFLOW_USER_DIR/review/zz-user.md\",[]]"
  assert_equal "$(jq -r '.perspectives[] | select(.name == "aa-repo") | .layer' <<<"$output")" repo
  assert_equal "$(names .perspectives)" "$(names .perspectives | LC_ALL=C sort)"
}

@test "同じ名前の観点は上位の層のファイルを使い、上書きしたパスを残す" {
  perspective "$WORKFLOW_USER_DIR/review" docs-sync "ユーザーの版"
  perspective "$REPO/.claude/dev-workflow/review" docs-sync "リポジトリの版"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c '[.perspectives[] | select(.name == "docs-sync")] | length' <<<"$output")" 1
  assert_equal "$(jq -c '.perspectives[] | select(.name == "docs-sync") | [.title, .layer, .overrides]' <<<"$output")" \
    "[\"リポジトリの版\",\"repo\",[\"$PLUGIN_REVIEW/docs-sync.md\",\"$WORKFLOW_USER_DIR/review/docs-sync.md\"]]"
}

@test "enabled: false で下位の層の観点を止める（本文と title は省ける）" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\nenabled: false\n---\n' >"$REPO/.claude/dev-workflow/review/docs-sync.md"
  run_script review-perspectives.sh
  assert_success
  jq -e '.perspectives | all(.name != "docs-sync")' <<<"$output" >/dev/null || fail "docs-sync が止まっていません"
  assert_equal "$(jq -c '.disabled' <<<"$output")" \
    "[{\"name\":\"docs-sync\",\"layer\":\"repo\",\"path\":\"$REPO/.claude/dev-workflow/review/docs-sync.md\",\"overrides\":[\"$PLUGIN_REVIEW/docs-sync.md\"]}]"
}

@test "上位の層で enabled: true にすると、止めた観点を戻せる" {
  mkdir -p "$WORKFLOW_USER_DIR/review"
  printf -- '---\nenabled: false\n---\n' >"$WORKFLOW_USER_DIR/review/docs-sync.md"
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\ntitle: "戻す"\nenabled: true\n---\n本文\n' >"$REPO/.claude/dev-workflow/review/docs-sync.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "docs-sync") | .title' <<<"$output")" "戻す"
  assert_equal "$(jq -c '.disabled' <<<"$output")" "[]"
}

@test "形式の誤ったファイルは警告して invalid に入れ、ほかの観点は使う" {
  d="$REPO/.claude/dev-workflow/review"
  perspective "$d" ok "使う"
  perspective "$d" Bad_Name "名前の誤り"
  printf 'frontmatter が無い\n' >"$d/no-fm.md"
  printf -- '---\ntitle: 閉じていない\n' >"$d/unclosed.md"
  printf -- '---\nenabled: no\ntitle: x\n---\n本文\n' >"$d/bad-enabled.md"
  printf -- '---\ntitle:\n---\n本文\n' >"$d/no-title.md"
  printf -- '---\ntitle: 本文が無い\n---\n\n  \n' >"$d/no-body.md"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' 2>'$TMP/err'"
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.layer == "repo") | .name' <<<"$output")" ok
  assert_equal "$(jq -r '.invalid[] | "\(.path | split("/") | last) \(.reason)"' <<<"$output" | LC_ALL=C sort)" "$(LC_ALL=C sort <<'EOF'
Bad_Name.md ファイル名は小文字の英数字と - だけにしてください
bad-enabled.md enabled は true か false にしてください
no-body.md 本文（レビューの指示）がありません
no-fm.md 先頭に --- で囲んだ frontmatter がありません
no-title.md title がありません
unclosed.md 先頭に --- で囲んだ frontmatter がありません
EOF
)"
  assert_equal "$(grep -c '^warn: 観点ファイルを使いません' "$TMP/err")" 6
}

@test "CRLF の改行と引用符で囲んだ title を読める" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- "---\r\ntitle: 'CRLF の観点'\r\n---\r\n本文\r\n" >"$REPO/.claude/dev-workflow/review/crlf.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "crlf") | .title' <<<"$output")" "CRLF の観点"
}

@test "上位の層のファイルが形式の誤りで使えないときは、下位の層の同じ名前の観点も使わない" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\nenabled: no\n---\n' >"$REPO/.claude/dev-workflow/review/docs-sync.md"
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' 2>'$TMP/err'"
  assert_success
  jq -e '.perspectives | all(.name != "docs-sync")' <<<"$output" >/dev/null || fail "下位の層の docs-sync が使われています"
  assert_equal "$(jq -c '.invalid[] | select(.path | endswith("/docs-sync.md")) | .overrides' <<<"$output")" \
    "[\"$PLUGIN_REVIEW/docs-sync.md\"]"
  grep -q "同じ名前の下位の層の観点も使いません: docs-sync" "$TMP/err" || fail "$(cat "$TMP/err")"
}

@test "先頭に BOM がある観点ファイルを読める" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf '\357\273\277---\ntitle: BOM の観点\n---\n本文\n' >"$REPO/.claude/dev-workflow/review/bom.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "bom") | .title' <<<"$output")" "BOM の観点"
}

@test "リポジトリの外でも、プラグインとユーザーの観点を出力する" {
  perspective "$WORKFLOW_USER_DIR/review" mine "ユーザーの観点"
  cd "$TMP"
  run_script review-perspectives.sh
  assert_success
  jq -e '.perspectives | any(.name == "mine") and any(.layer == "plugin")' <<<"$output" >/dev/null || fail "$output"
}

@test "不明な引数は使い方の誤りにする" {
  run_script review-perspectives.sh --foo
  assert_failure 64
  assert_output --partial "不明な引数です: --foo"
}

# 条件で絞り込むテストの準備。基点（init）の後に main へ1つコミットし、work ブランチで <ファイル> を変える
# 使い方: branch_changing <ファイル>...
branch_changing() {
  BASE="$(git rev-parse HEAD)"
  git checkout -q -b work
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    echo x >"$f"
  done
  git add -A
  git commit -q -m change
}

# 使い方: perspective_when <名前> <frontmatter に足す行>
perspective_when() {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\ntitle: %s\n%b\n---\n本文\n' "$1" "$2" >"$REPO/.claude/dev-workflow/review/$1.md"
}

# 使い方: skipped_reason <名前> → 外した理由（外していなければ空）
skipped_reason() { jq -r --arg n "$1" '.skipped[] | select(.name == $n) | .reason' <<<"$output"; }
used() { jq -e --arg n "$1" '.perspectives | any(.name == $n)' <<<"$output" >/dev/null; }

@test "types に当てはまる観点だけを使い、当てはまらない観点は理由とともに skipped に出す" {
  branch_changing a.txt
  perspective_when only-fix 'types: [fix, perf]'
  perspective_when only-feat 'types: feat'
  run_script review-perspectives.sh --base "$BASE" --target main --type feat
  assert_success
  used only-feat || fail "only-feat が使われていません: $output"
  used only-fix && fail "only-fix が外れていません: $output"
  assert_equal "$(skipped_reason only-fix)" "type（feat）が types（fix、perf）のどれでもない"
  assert_equal "$(jq -r '.skipped[] | select(.name == "only-fix") | .layer' <<<"$output")" repo
}

@test "type が分からなければ、types の条件では外さない" {
  branch_changing a.txt
  perspective_when only-fix 'types: [fix]'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used only-fix || fail "$output"
}

@test "paths は差分のファイルのどれかが当たるときだけ使い、* は / にも当たる" {
  branch_changing src/lib/a.sh docs/b.md
  perspective_when shell 'paths: ["*.sh"]'
  perspective_when ci 'paths: [".github/*", "*.yml"]'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used shell || fail "$output"
  assert_equal "$(skipped_reason ci)" "差分のファイルが paths（.github/*、*.yml）のどれにも当たらない"
}

@test "名前を変えたファイルは、元の名前も paths に当てる" {
  mkdir -p old
  echo x >old/a.txt
  git add -A && git commit -q -m add
  BASE="$(git rev-parse HEAD)"
  git checkout -q -b work
  git mv old new
  git commit -q -m rename
  perspective_when old-dir 'paths: old/*'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used old-dir || fail "$output"
}

@test "issue: required は Issue があるときだけ使う" {
  branch_changing a.txt
  perspective_when needs-issue 'issue: required'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  assert_equal "$(skipped_reason needs-issue)" "Issue が無い（issue: required）"
  run_script review-perspectives.sh --base "$BASE" --target main --issue 12
  assert_success
  used needs-issue || fail "$output"
}

@test "base_ahead: required はマージ先が基点より進んでいるときだけ使う" {
  branch_changing a.txt
  perspective_when drift 'base_ahead: required'
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  assert_equal "$(skipped_reason drift)" "マージ先（main）が基点より進んでいない（base_ahead: required）"
  git checkout -q main
  git commit -q --allow-empty -m later
  git checkout -q work
  run_script review-perspectives.sh --base "$BASE" --target main
  assert_success
  used drift || fail "$output"
}

@test "条件を複数書くと、すべてに当てはまるときだけ使う" {
  branch_changing a.sh
  perspective_when both 'types: fix\npaths: "*.md"'
  run_script review-perspectives.sh --base "$BASE" --target main --type fix
  assert_success
  assert_equal "$(skipped_reason both)" "差分のファイルが paths（*.md）のどれにも当たらない"
}

@test "条件を書いていない観点と、--base を渡さないときは、条件で外さない" {
  branch_changing a.txt
  perspective_when plain ''
  perspective_when only-fix 'types: fix\nissue: required'
  run_script review-perspectives.sh --base "$BASE" --target main --type feat
  assert_success
  used plain || fail "$output"
  run_script review-perspectives.sh
  assert_success
  used only-fix || fail "$output"
  assert_equal "$(jq -c .skipped <<<"$output")" "[]"
}

@test "条件の書き方が誤っていれば invalid に入れる" {
  perspective_when bad-types 'types: [Fix]'
  perspective_when empty-types 'types: []'
  perspective_when empty-paths 'paths:'
  perspective_when bad-issue 'issue: yes'
  perspective_when bad-ahead 'base_ahead: true'
  perspective_when bad-builtin 'builtin: lint'
  run bash -c "${TEST_BASH:-bash} '$SCRIPTS/review-perspectives.sh' 2>/dev/null"
  assert_success
  assert_equal "$(jq -r '.invalid[] | "\(.path | split("/") | last) \(.reason)"' <<<"$output" | LC_ALL=C sort)" "$(LC_ALL=C sort <<'EOF2'
bad-ahead.md base_ahead は required にしてください
bad-builtin.md builtin は code-review にしてください
bad-issue.md issue は required にしてください
bad-types.md types は type の名前（小文字の英数字と -）の一覧にしてください
empty-paths.md paths にパターンがありません
empty-types.md types に type がありません
EOF2
)"
}

@test "builtin の観点は本文を省け、perspectives に builtin を出す" {
  mkdir -p "$REPO/.claude/dev-workflow/review"
  printf -- '---\ntitle: 組み込み\nbuiltin: code-review\n---\n' >"$REPO/.claude/dev-workflow/review/mine.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "mine") | .builtin' <<<"$output")" code-review
  assert_equal "$(jq -r '.perspectives[] | select(.name == "docs-sync") | .builtin' <<<"$output")" null
}

@test "条件で絞り込む引数の誤りは使い方の誤りにし、無い ref は止める" {
  run_script review-perspectives.sh --type fix
  assert_failure 64
  assert_output --partial "--base と --target の両方を渡してください"
  run_script review-perspectives.sh --base HEAD --target HEAD --issue abc
  assert_failure 64
  run_script review-perspectives.sh --base nothing --target HEAD
  assert_failure 2
  assert_output --partial "基点のコミットが見つかりません: nothing"
  run_script review-perspectives.sh --base HEAD --target origin/main
  assert_failure 2
  assert_output --partial "マージ先が見つかりません: origin/main"
}

@test "同梱の観点の条件：regression-test は fix、issue-requirements は Issue、main-drift はマージ先が進んだときだけ使う" {
  branch_changing a.txt
  run_script review-perspectives.sh --base "$BASE" --target main --type feat
  assert_success
  for n in regression-test issue-requirements main-drift; do
    [ -n "$(skipped_reason "$n")" ] || fail "$n が外れていません: $output"
  done
  used docs-sync || fail "$output"
  git checkout -q main
  git commit -q --allow-empty -m later
  git checkout -q work
  run_script review-perspectives.sh --base "$BASE" --target main --type fix --issue 1
  assert_success
  for n in regression-test issue-requirements main-drift; do
    used "$n" || fail "$n が使われていません: $output"
  done
}
