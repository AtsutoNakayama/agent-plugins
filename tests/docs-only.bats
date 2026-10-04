#!/usr/bin/env bats

load test_helper

# 指定したファイルを足して1コミットにする。使い方: commit_files <パス>...
commit_files() {
  local f
  for f in "$@"; do
    mkdir -p "$(dirname "$f")"
    echo "$f" >"$f"
    git add "$f"
  done
  git -c user.name=t -c user.email=t@example.com commit -q -m change
}

docs_only() {
  run "${TEST_BASH:-bash}" "$BATS_TEST_DIRNAME/../.github/scripts/docs-only.sh"
}

@test "README・docs・テンプレートだけの変更は true" {
  commit_files README.md docs/design.md .github/ISSUE_TEMPLATE/bug.yml .github/pull_request_template.md
  docs_only
  assert_success
  assert_output '{"docs_only": true}'
}

@test "プラグインの中の .md を含む変更は false" {
  commit_files README.md plugins/dev-workflow/skills/commit/SKILL.md
  docs_only
  assert_success
  assert_output '{"docs_only": false}'
}

@test "ワークフローの変更は false（actionlint を動かすため）" {
  commit_files .github/workflows/lint.yml
  docs_only
  assert_output '{"docs_only": false}'
}

@test "スクリプトを含む変更は false" {
  commit_files docs/a.md tests/a.bats
  docs_only
  assert_output '{"docs_only": false}'
}

@test "変更の無い（空の）コミットは false" {
  git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m empty
  docs_only
  assert_output '{"docs_only": false}'
}

@test "親の無いコミット（調べられないとき）は false にして CI を動かす" {
  git checkout -q --orphan fresh
  git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m root
  docs_only
  assert_success
  assert_output '{"docs_only": false}'
}

@test "ファイル名に空白があっても正しく判定する" {
  commit_files "docs/a b.md"
  docs_only
  assert_output '{"docs_only": true}'
}

@test "日本語のファイル名でも判定する" {
  commit_files "docs/設計.md"
  docs_only
  assert_output '{"docs_only": true}'
  commit_files "tests/テスト.bats"
  docs_only
  assert_output '{"docs_only": false}'
}

@test "ファイルの移動は、移動元も見る（tests/ から docs/ へ移したら false）" {
  commit_files tests/a.bats
  # 内容が同じままの移動は、既定のリネーム検出では移動先だけが出る
  mkdir -p docs
  git mv tests/a.bats docs/a.bats
  git -c user.name=t -c user.email=t@example.com commit -q -m move
  docs_only
  assert_output '{"docs_only": false}'
}
