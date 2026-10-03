#!/usr/bin/env bats

load test_helper

# 作業用のブランチを作り、ファイルを1つステージしておく
setup_branch() {
  git checkout -q -b feat/18-x
  echo a >a.txt
  git add a.txt
}

# 使い方: commit_with <メッセージ> [オプション]...
commit_with() {
  local message="$1"
  shift
  printf '%s\n' "$message" >"$TMP/msg"
  run_script commit.sh --message-file "$TMP/msg" "$@"
}

@test "規約に合うメッセージでコミットし、sha を返す" {
  setup_branch
  commit_with "$(printf 'feat(cli): ログインを追加する\n\n理由を書く。')"
  assert_success
  assert_equal "$(git log -1 --format=%B | head -n 1)" "feat(cli): ログインを追加する"
  assert_equal "$(jq -r .sha <<<"$output")" "$(git rev-parse HEAD)"
}

@test "メッセージは標準入力からも渡せる" {
  setup_branch
  run bash -c "printf 'docs: 説明を直す\n' | ${TEST_BASH:-bash} '$SCRIPTS/commit.sh' --message-file -"
  assert_success
  assert_equal "$(git log -1 --format=%s)" "docs: 説明を直す"
}

@test "1行目が規約に合わなければコミットしない" {
  setup_branch
  for m in "ログインを追加する" "feature: x" "Feat: x" "feat:x" "feat(CLI): x"; do
    commit_with "$m"
    assert_failure 2
    assert_output --partial "1行目が規約に合いません"
  done
  assert_equal "$(git rev-list --count HEAD)" 1
}

@test "scope_required ならスコープが必要" {
  setup_branch
  echo '{"commit": {"scope_required": true}}' >.claude/dev-workflow/config.json
  commit_with "feat: x"
  assert_failure 2
  assert_output --partial "スコープが必要です"
  commit_with "feat(api): x"
  assert_success
}

@test "Refs を付けたらコミットしない" {
  setup_branch
  commit_with "$(printf 'fix: x\n\nRefs: #18')"
  assert_failure 2
  assert_output --partial "Refs は付けないでください"
  commit_with "$(printf 'fix: x\n\nrefs #18')"
  assert_failure 2
}

@test "1行目の次が空行でなければコミットしない" {
  setup_branch
  commit_with "$(printf 'fix: x\n本文')"
  assert_failure 2
  assert_output --partial "1行目（要約）の次は空行にしてください"
}

@test "base_branch（main）の上ではコミットしない" {
  echo a >a.txt
  git add a.txt
  commit_with "feat: x"
  assert_failure 2
  assert_output --partial "main の上ではコミットしません"
}

@test "ステージした変更が無ければコミットしない" {
  git checkout -q -b feat/18-x
  commit_with "feat: x"
  assert_failure 2
  assert_output --partial "ステージした変更がありません"
}

@test "dry-run では検証だけ行い、コミットしない" {
  setup_branch
  commit_with "feat: x" --dry-run
  assert_success
  assert_equal "$(jq -c '[.dry_run, .sha]' <<<"$output")" '[true,null]'
  assert_equal "$(git rev-list --count HEAD)" 1
}
