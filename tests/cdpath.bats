#!/usr/bin/env bats
# CDPATH を export した環境でも、スクリプトとフックが共通の処理（lib/common.sh）を読み込めることを確かめる。
# 相対パスで実行すると dirname が相対パスを返し、CDPATH があると cd がパスを出力して、置き場所が2行になっていた。

load test_helper

setup() {
  test_helper_setup
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
    out="$(PATH="$TMP/bin:$PATH" CDPATH="$TMP/work" timeout 30 "${TEST_BASH:-bash}" "$f" </dev/null 2>&1 || true)"
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

@test "スクリプトとフックの置き場所を求める cd は、CDPATH を空にして実行する" {
  cd "$ROOT"
  # $(cd ... のように、CDPATH='' を付けずに dirname の結果へ cd する書き方が残っていないこと
  # shellcheck disable=SC2016 # 正規表現の $ をそのまま渡す
  run git grep -nE '\$\(cd "\$\(dirname|\$\(cd "\$DW_SCRIPTS_DIR' -- plugins .github/scripts tests/eval tests/test_helper.bash
  assert_failure 1
  assert_output ""
}
