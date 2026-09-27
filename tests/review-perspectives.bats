#!/usr/bin/env bats

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
  perspective "$WORKFLOW_USER_REVIEW_DIR" zz-user "ユーザーの観点"
  perspective "$REPO/.claude/review" aa-repo "リポジトリの観点"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c '.perspectives[] | select(.name == "zz-user") | [.title, .layer, .path, .overrides]' <<<"$output")" \
    "[\"ユーザーの観点\",\"user\",\"$WORKFLOW_USER_REVIEW_DIR/zz-user.md\",[]]"
  assert_equal "$(jq -r '.perspectives[] | select(.name == "aa-repo") | .layer' <<<"$output")" repo
  assert_equal "$(names .perspectives)" "$(names .perspectives | LC_ALL=C sort)"
}

@test "同じ名前の観点は上位の層のファイルを使い、上書きしたパスを残す" {
  perspective "$WORKFLOW_USER_REVIEW_DIR" docs-sync "ユーザーの版"
  perspective "$REPO/.claude/review" docs-sync "リポジトリの版"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -c '[.perspectives[] | select(.name == "docs-sync")] | length' <<<"$output")" 1
  assert_equal "$(jq -c '.perspectives[] | select(.name == "docs-sync") | [.title, .layer, .overrides]' <<<"$output")" \
    "[\"リポジトリの版\",\"repo\",[\"$PLUGIN_REVIEW/docs-sync.md\",\"$WORKFLOW_USER_REVIEW_DIR/docs-sync.md\"]]"
}

@test "enabled: false で下位の層の観点を止める（本文と title は省ける）" {
  mkdir -p "$REPO/.claude/review"
  printf -- '---\nenabled: false\n---\n' >"$REPO/.claude/review/docs-sync.md"
  run_script review-perspectives.sh
  assert_success
  jq -e '.perspectives | all(.name != "docs-sync")' <<<"$output" >/dev/null || fail "docs-sync が止まっていません"
  assert_equal "$(jq -c '.disabled' <<<"$output")" \
    "[{\"name\":\"docs-sync\",\"layer\":\"repo\",\"path\":\"$REPO/.claude/review/docs-sync.md\",\"overrides\":[\"$PLUGIN_REVIEW/docs-sync.md\"]}]"
}

@test "上位の層で enabled: true にすると、止めた観点を戻せる" {
  mkdir -p "$WORKFLOW_USER_REVIEW_DIR"
  printf -- '---\nenabled: false\n---\n' >"$WORKFLOW_USER_REVIEW_DIR/docs-sync.md"
  mkdir -p "$REPO/.claude/review"
  printf -- '---\ntitle: "戻す"\nenabled: true\n---\n本文\n' >"$REPO/.claude/review/docs-sync.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "docs-sync") | .title' <<<"$output")" "戻す"
  assert_equal "$(jq -c '.disabled' <<<"$output")" "[]"
}

@test "形式の誤ったファイルは警告して invalid に入れ、ほかの観点は使う" {
  d="$REPO/.claude/review"
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
  mkdir -p "$REPO/.claude/review"
  printf -- "---\r\ntitle: 'CRLF の観点'\r\n---\r\n本文\r\n" >"$REPO/.claude/review/crlf.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "crlf") | .title' <<<"$output")" "CRLF の観点"
}

@test "先頭に BOM がある観点ファイルを読める" {
  mkdir -p "$REPO/.claude/review"
  printf '\357\273\277---\ntitle: BOM の観点\n---\n本文\n' >"$REPO/.claude/review/bom.md"
  run_script review-perspectives.sh
  assert_success
  assert_equal "$(jq -r '.perspectives[] | select(.name == "bom") | .title' <<<"$output")" "BOM の観点"
}

@test "リポジトリの外でも、プラグインとユーザーの観点を出力する" {
  perspective "$WORKFLOW_USER_REVIEW_DIR" mine "ユーザーの観点"
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
