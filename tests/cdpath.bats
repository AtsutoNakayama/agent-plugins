#!/usr/bin/env bats
# CDPATH を export した環境でも、スクリプトとフックが共通の処理（lib/common.sh）を読み込めることを確かめる。
# 相対パスで実行すると dirname が相対パスを返し、CDPATH があると cd がパスを出力して、置き場所が2行になっていた。

load test_helper

setup() {
  test_helper_setup
  mark_set_up
  ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
}

@test "CDPATH を export して相対パスで実行しても、すべてのスクリプトとフックが共通の処理を読み込める" {
  # 作業ツリーに触れないよう、一時ディレクトリにプラグインへのシンボリックリンクを置き、そこから相対パスで実行する
  mkdir -p "$TMP/work" "$TMP/bin"
  ln -s "$ROOT/plugins" "$TMP/work/plugins"
  # GitHub に触れず、待たされないよう、gh は失敗するだけの偽物にする
  printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/gh"
  chmod +x "$TMP/bin/gh"
  cd "$TMP/work"
  local f out failed=""
  for f in plugins/dev-workflow/scripts/*.sh plugins/dev-workflow/scripts/setup/*.sh plugins/dev-workflow/hooks/*.sh; do
    # 読み込みに失敗すると、source できないというエラーが出る。読み込んだ後の動作（引数が無い等）は問わない
    out="$(PATH="$TMP/bin:$PATH" CDPATH="$TMP/work" "${TEST_BASH:-bash}" "$f" </dev/null 2>&1 || true)"
    case "$out" in
      *"No such file"* | *"lib/common.sh"*) failed="$failed $f" ;;
    esac
  done
  [ -z "$failed" ] || { echo "読み込みに失敗:$failed"; return 1; }
}

@test "lib/common.sh を CDPATH 付きで source しても、DW_SCRIPTS_DIR は1行の絶対パスになる" {
  cd "$ROOT"
  # shellcheck disable=SC2016 # 起動した bash の中で展開させる
  run env CDPATH="$ROOT" "${TEST_BASH:-bash}" -c '. plugins/dev-workflow/scripts/lib/common.sh && printf "%s\n%s\n" "$DW_SCRIPTS_DIR" "$DW_PLUGIN_ROOT"'
  assert_success
  assert_output "$ROOT/plugins/dev-workflow/scripts
$ROOT/plugins/dev-workflow"
}

@test "CDPATH を export していても、gc_git は相対パスの対象で git を実行できる" {
  cd "$TMP"
  # shellcheck disable=SC2016 # 起動した bash の中で展開させる
  run env CDPATH="$TMP" "${TEST_BASH:-bash}" -c '. "$1/common.sh"; . "$1/git-command.sh"; gc_git_dir=repo; gc_git rev-parse --abbrev-ref HEAD' _ "$ROOT/plugins/dev-workflow/scripts/lib"
  assert_success
  assert_output "main"
}

@test "CDPATH を export していても、main を守るフックは相対パスの cwd のリポジトリで判断する" {
  cd "$TMP"
  jq -n '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: "git commit -m x"}, cwd: "repo"}' >"$TMP/input.json"
  run env CDPATH="$TMP" "${TEST_BASH:-bash}" "$ROOT/plugins/dev-workflow/hooks/guard-git.sh" <"$TMP/input.json"
  assert_failure 2
  assert_output --partial "main の上ではコミットしません"
}

@test "CDPATH を export していても、SessionStart のフックは相対パスの cwd のリポジトリの設定を読む" {
  cd "$TMP"
  printf 'MARKER_FROM_REPO\n' >"$REPO/.claude/dev-workflow/task-flow.md"
  jq -n '{hook_event_name: "SessionStart", source: "startup", cwd: "repo"}' >"$TMP/input.json"
  run env CDPATH="$TMP" "${TEST_BASH:-bash}" "$ROOT/plugins/dev-workflow/hooks/task-flow.sh" <"$TMP/input.json"
  assert_success
  assert_output --partial "MARKER_FROM_REPO"
}

@test "スクリプトとフックの置き場所を求める cd は、CDPATH を空にして実行する" {
  cd "$ROOT"
  # $(cd ... のように、CDPATH='' を付けずに dirname の結果へ cd する書き方が残っていないこと
  # 相対パスになりうる cwd・CLAUDE_PROJECT_DIR・gc_git_dir・here への cd も同じ
  # shellcheck disable=SC2016 # 正規表現の $ をそのまま渡す
  run git grep -nE '(\$\(|\( ?)cd "(\$\(dirname|\$DW_SCRIPTS_DIR|\$\{cwd|\$CLAUDE_PROJECT_DIR|\$gc_git_dir|\$here)' -- plugins .github/scripts tests/eval tests/test_helper.bash
  assert_failure 1
  assert_output ""
}
