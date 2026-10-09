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

# CDPATH='' の無い cd の行を「<ファイル>:<行の中身（前の空白を除く）>」で出力する。コメントの行（行頭の空白の後の #）は除く。
# シェルのコマンドの位置を正規表現で列挙すると見逃しが残る（case の a) cd・builtin cd・FOO=1 cd など）ので、位置は問わず、
# 語としての cd（前が行頭か英数字・_・- 以外、後が空白・行末か ; & | < > )）をすべて見つけ、CDPATH='' cd のものだけを除く
# （CDPATH の前も変数名の境界にして、XCDPATH='' cd は除かない）。
# 文字列やメッセージの中に cd が語として現れるだけの行は、テストの許可の一覧に理由を添えて書く。
# 単語の境界は、macOS の git の ERE で働かない \b を使わずに書く
# 使い方: bare_cd <git grep の pathspec>...
bare_cd() {
  git grep -nE --full-name -e '(^|[^[:alnum:]_-])cd([[:space:];&|<>)]|$)' -- "$@" \
    | awk -F: '{
        f = $1; sub(/^[^:]*:[0-9]+:[[:space:]]*/, "")
        if ($0 ~ /^#/) next
        # 消した所は空白にして、前後の語がくっつかないようにする
        l = $0; gsub(/(^|[^[:alnum:]_])CDPATH='"''"'[[:space:]]+cd([[:space:];&|<>)]|$)/, " ", l)
        if (l ~ /(^|[^[:alnum:]_-])cd([[:space:];&|<>)]|$)/) print f ":" $0
      }'
}

@test "cd は CDPATH を空にして実行する（許可の一覧の行だけを、理由を添えて許す）" {
  cd "$ROOT"
  # 許す行と理由
  #   dw_abs_dir：相対パスなら基準のディレクトリ（絶対パス）を前に付けてから cd する
  #   dw_physical_path：相対パスなら $PWD を前に付けてから cd する
  #   test_helper_setup：REPO は mktemp -d の実体の絶対パス（pwd -P）の下
  #   git-command.sh（2行）：cd を実行せず、解析するコマンドの名前として case のパターンに書いている
  #   guard-git.sh・task-start.sh：cd を実行せず、利用者に伝えるメッセージの中に書いている
  # shellcheck disable=SC2016 # 行の中身をそのまま書く
  allowed='plugins/dev-workflow/scripts/lib/common.sh:(cd "$p" 2>/dev/null && pwd -P)
plugins/dev-workflow/scripts/lib/common.sh:d="$(cd -P "$p" 2>/dev/null && pwd -P)" || d="$p"
tests/test_helper.bash:cd "$REPO" || return 1
plugins/dev-workflow/scripts/lib/git-command.sh:cd | pushd | popd | dirs)
plugins/dev-workflow/scripts/lib/git-command.sh:cd)
plugins/dev-workflow/hooks/guard-git.sh:echo "操作の対象のリポジトリが分からないので、${1}は止めます（今のブランチが分からず、base_branch の上かを確かめられません）。cd -- <絶対パス> && git ...、または git -C <絶対パス> ... で対象を書き直してください"
plugins/dev-workflow/scripts/task-start.sh:dw_warn "サブモジュールを初期化できませんでした。ワークツリーで git submodule update --init --recursive を実行してください（cd ${path}）"'
  found="$(bare_cd "${CD_PATHS[@]}")"
  # 一覧に無い cd が残っていないこと
  run grep -vxF -e "$allowed" <<<"$found"
  assert_output ""
  # 一覧の行が、どれもまだあること（消えた・書き換えた行を、一覧に残さない）
  run grep -vxF -e "$found" <<<"$allowed"
  assert_output ""
}

@test "CDPATH='' の無い cd を足すと、どの位置でも検査で見つかる（語の一部の cd は見ない）" {
  cd "$TMP"
  git init -q -b main probe
  CDPATH='' cd probe
  # 見つかるもの
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
    'time -p cd "$dir"' \
    'case x in a) cd "$rel" ;; esac' \
    'builtin cd "$dir"' \
    'command cd "$dir"' \
    'x=`cd "$dir" && pwd`' \
    'FOO=1 cd "$dir"' \
    'x="$(CDPATH='"''"' cd "$a" && cd "$b")"' \
    'cd>"$log" "$dir"' \
    'x="$(cd)"' \
    'cd;' \
    'XCDPATH='"''"' cd "$dir"' >probe.sh
  cp probe.sh expected
  # 見つからないもの
  # shellcheck disable=SC2016 # 試す行をそのまま書く
  printf '%s\n' \
    'x="$(CDPATH='"''"' cd "$dir" && pwd)"' \
    'CDPATH='"''"' cd' \
    'CDPATH='"''"' cd>"$log" "$dir"' \
    'x=(CDPATH='"''"' cd "$dir")' \
    'ifcd x' \
    'docd x' \
    'abcd x' \
    'cd-foo x' \
    'x_cd y' \
    '  # cd "$dir" はコメント' >>probe.sh
  git add probe.sh
  run bare_cd probe.sh
  assert_success
  assert_output "$(sed 's/^/probe.sh:/' expected)"
}
