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

# CDPATH='' の無い cd を探す範囲（プラグインのスクリプトとフック、CI と eval のスクリプト、テストの共通の準備）
CD_PATHS=(plugins .github/scripts tests/eval tests/test_helper.bash ':!*.md' ':!*.json')

# CDPATH='' の無い cd の行を「<ファイル>:<行の中身（前の空白を除く）>」で出力する。コメントの行は除く。
# cd はコマンドの位置（行頭、( $( { ; & | ! の後、if・elif・then・else・while・until・do・time の後）にあるものだけを見る（case のパターンの cd | や、文の中の cd は見ない）。
# CDPATH='' cd は、cd の前が CDPATH='' なので当たらない。単語の境界は、macOS の git の ERE で働かない \b を使わずに書く
# 使い方: bare_cd <git grep の pathspec>...
bare_cd() {
  # shellcheck disable=SC2016 # 正規表現の $ をそのまま渡す
  git grep -nE --full-name -e '(^|[;&|({!]|\$\(|(^|[^[:alnum:]_])(if|elif|then|else|while|until|do|time))[[:space:]]*cd([[:space:]]+[^|[:space:]]|$)' -- "$@" \
    | awk -F: '{ f = $1; sub(/^[^:]*:[0-9]+:[[:space:]]*/, ""); if ($0 !~ /^#/) print f ":" $0 }'
}

@test "cd は CDPATH を空にして実行する（絶対パスだと保証した cd だけを、一覧で許す）" {
  cd "$ROOT"
  # 許す cd。どれも、cd の前で絶対パスにしている
  #   dw_abs_dir：相対パスなら基準のディレクトリ（絶対パス）を前に付けてから cd する
  #   dw_physical_path：相対パスなら $PWD を前に付けてから cd する
  #   test_helper_setup：REPO は mktemp -d の実体の絶対パス（pwd -P）の下
  # shellcheck disable=SC2016 # 行の中身をそのまま書く
  allowed='plugins/dev-workflow/scripts/lib/common.sh:(cd "$p" 2>/dev/null && pwd -P)
plugins/dev-workflow/scripts/lib/common.sh:d="$(cd -P "$p" 2>/dev/null && pwd -P)" || d="$p"
tests/test_helper.bash:cd "$REPO" || return 1'
  found="$(bare_cd "${CD_PATHS[@]}")"
  # 一覧に無い cd が残っていないこと
  run grep -vxF -e "$allowed" <<<"$found"
  assert_output ""
  # 一覧の cd が、どれもまだあること（消えた・書き換えた cd を、一覧に残さない）
  run grep -vxF -e "$found" <<<"$allowed"
  assert_output ""
}

@test "CDPATH='' の無い cd を足すと、検査で見つかる（コマンドの位置の cd だけを見る）" {
  cd "$TMP"
  git init -q -b main probe
  cd probe
  # shellcheck disable=SC2016 # 試す行をそのまま書く
  printf '%s\n' \
    'cd "$dir"' \
    'x="$(cd "$dir" && pwd)"' \
    '( cd "$dir" ) && { cd "$dir"; }' \
    'if true; then cd -P "$dir"; fi' \
    'true && cd "$dir"' \
    'for d in a; do cd "$d"; done' \
    'if false; then :; else cd "$dir"; fi' \
    'if cd "$dir"; then :; fi' \
    'if false; then :; elif cd "$dir"; then :; fi' \
    'while cd "$dir"; do break; done' \
    'until cd "$dir"; do :; done' \
    '! cd "$dir"' \
    'time cd "$dir"' \
    'undo cd "$dir"' \
    'notif cd "$dir"' \
    'runtime cd "$dir"' \
    'x != cd' \
    'x="$(CDPATH='"''"' cd "$dir" && pwd)"' \
    '  # cd "$dir" はコメント' \
    '  cd | pushd) ;;' \
    'echo "（cd ${p} で移る）"' >probe.sh
  git add probe.sh
  run bare_cd probe.sh
  assert_success
  # shellcheck disable=SC2016 # 期待する行をそのまま書く
  assert_output 'probe.sh:cd "$dir"
probe.sh:x="$(cd "$dir" && pwd)"
probe.sh:( cd "$dir" ) && { cd "$dir"; }
probe.sh:if true; then cd -P "$dir"; fi
probe.sh:true && cd "$dir"
probe.sh:for d in a; do cd "$d"; done
probe.sh:if false; then :; else cd "$dir"; fi
probe.sh:if cd "$dir"; then :; fi
probe.sh:if false; then :; elif cd "$dir"; then :; fi
probe.sh:while cd "$dir"; do break; done
probe.sh:until cd "$dir"; do :; done
probe.sh:! cd "$dir"
probe.sh:time cd "$dir"'
}
