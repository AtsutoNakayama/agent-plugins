#!/usr/bin/env bats
# タスクの進め方を渡すフック（hooks/task-flow.sh）。
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

HOOKS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/hooks"

# フックは導入したリポジトリでだけ動くので、テストのリポジトリを導入したことにする
setup() {
  test_helper_setup
  mark_set_up
}
DEFAULT="$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/task-flow.md"

# フックの入力（JSON）を作って渡す。cwd は既定で今のディレクトリ
# 使い方: run_hook [cwd]
run_hook() {
  jq -n --arg d "${1:-$PWD}" '{hook_event_name: "SessionStart", source: "startup", cwd: $d}' >"$TMP/input.json"
  run "${TEST_BASH:-bash}" "$HOOKS/task-flow.sh" <"$TMP/input.json"
}

# 文字列の中で、ある文字列が最初に現れる位置（バイト）。無ければ -1
# 使い方: pos <文字列> <探す文字列>
pos() {
  local rest="${1%%"$2"*}"
  if [ "$rest" = "$1" ]; then echo -1; else echo "${#rest}"; fi
}

@test "追記が無ければ、既定の流れだけを出す" {
  run_hook
  assert_success
  assert_output "$(cat "$DEFAULT")"
}

@test "既定の流れに、どの段階でどのスキルを使うかが書いてある" {
  for skill in task-create task-start commit review pr-create task-finish task-cancel; do
    grep -q "/dev-workflow:${skill}\`" "$DEFAULT" || fail "${skill} が書かれていません"
  done
}

@test "個人とチームの追記を、既定の流れのあとに、個人 → チームの順に出す" {
  echo "個人の追記です" >"$WORKFLOW_USER_DIR/task-flow.md"
  echo "チームの追記です" >"$REPO/.claude/dev-workflow/task-flow.md"
  run_hook
  assert_success
  assert_output --partial "$(cat "$DEFAULT")"
  assert_output --partial "以下は $WORKFLOW_USER_DIR/task-flow.md の追記です"
  assert_output --partial "以下は $REPO/.claude/dev-workflow/task-flow.md の追記です"
  d="$(pos "$output" "# タスクの進め方")"
  u="$(pos "$output" "個人の追記です")"
  t="$(pos "$output" "チームの追記です")"
  [ "$d" -ge 0 ] && [ "$d" -lt "$u" ] && [ "$u" -lt "$t" ] || fail "順が違います: 既定 $d / 個人 $u / チーム $t"
}

@test "ワークツリーの中では、そのワークツリーのチームの追記を出す" {
  git -C "$REPO" worktree add -q -b feat/1-x "$TMP/wt"
  mkdir -p "$TMP/wt/.claude/dev-workflow"
  echo "ワークツリーの追記です" >"$TMP/wt/.claude/dev-workflow/task-flow.md"
  run_hook "$TMP/wt"
  assert_success
  assert_output --partial "ワークツリーの追記です"
}

@test "空の追記は出さない" {
  : >"$WORKFLOW_USER_DIR/task-flow.md"
  run_hook
  assert_success
  assert_output "$(cat "$DEFAULT")"
}

@test "リポジトリの外では、何も出さない（個人の追記も出さない）" {
  mkdir -p "$TMP/outside"
  echo "個人の追記です" >"$WORKFLOW_USER_DIR/task-flow.md"
  run_hook "$TMP/outside"
  assert_success
  assert_output ""
}

@test "導入していないリポジトリでは、何も出さない（個人の追記も出さない）" {
  git init -q "$TMP/other"
  echo "個人の追記です" >"$WORKFLOW_USER_DIR/task-flow.md"
  run_hook "$TMP/other"
  assert_success
  assert_output ""
  # 追記の置き場所（.claude/dev-workflow/）があっても、チームの設定が無ければ導入していない
  mkdir -p "$TMP/other/.claude/dev-workflow"
  echo "チームの追記です" >"$TMP/other/.claude/dev-workflow/task-flow.md"
  run_hook "$TMP/other"
  assert_success
  assert_output ""
}

@test "ワークツリーにチームの設定が無くても、メインのワークツリーにあれば導入したとみなす" {
  # 初期設定をコミットする前に作ったワークツリーには、チームの設定が無い
  git worktree add -q "$TMP/wt" -b feat/1-x
  [ ! -f "$TMP/wt/.claude/dev-workflow/config.json" ]
  run_hook "$TMP/wt"
  assert_success
  assert_output --partial "$(cat "$DEFAULT")"
}

@test "cwd が読めない入力では今のディレクトリで判断し、cwd が無いディレクトリなら何も出さない" {
  run "${TEST_BASH:-bash}" "$HOOKS/task-flow.sh" <<<'not json'
  assert_success
  assert_output --partial "$(cat "$DEFAULT")"
  run_hook "$TMP/no-such-dir"
  assert_success
  assert_output ""
}

@test "jq が無くても、導入していないリポジトリでは何も出さない" {
  # jq だけを除いた PATH を作る（git・cat などは残す）
  mkdir -p "$TMP/bin"
  for c in git cat dirname mktemp rm; do
    ln -s "$(command -v "$c")" "$TMP/bin/$c"
  done
  git init -q "$TMP/other"
  bash="$(command -v "${TEST_BASH:-bash}")"
  # cwd を読めないので、今のディレクトリ（Claude Code はフックをセッションのディレクトリで動かす）で判断する
  cd "$TMP/other"
  run env PATH="$TMP/bin" "$bash" "$HOOKS/task-flow.sh" <<<'{}'
  assert_success
  assert_output ""
  cd "$REPO"
  run env PATH="$TMP/bin" "$bash" "$HOOKS/task-flow.sh" <<<'{}'
  assert_success
  assert_output "$(cat "$DEFAULT")"
}

@test "1 万文字を超えたら、上限に収めて、読み直すファイルを知らせる" {
  # 1文字が3バイトの日本語で、バイト数ではなく文字数で数えていることも確かめる
  awk 'BEGIN { for (i = 0; i < 12000; i++) printf "あ"; print "" }' >"$REPO/.claude/dev-workflow/task-flow.md"
  run_hook
  assert_success
  assert_equal "$(jq -rn --arg s "$output" '$s | length')" 10000
  assert_output --partial "$(cat "$DEFAULT")"
  assert_output --partial "続きは次のファイルを読んでください: $REPO/.claude/dev-workflow/task-flow.md）"
}

@test "hooks.json の SessionStart に、すべての始まり方（matcher なし）で登録してある" {
  run jq -r '.hooks.SessionStart[] | select(.matcher == null) | .hooks[].command' "$HOOKS/hooks.json"
  assert_success
  assert_output --partial 'hooks/task-flow.sh'
}

@test "BMP の外の文字（絵文字など）は2文字と数えて、上限に収める" {
  # Claude Code は JavaScript の文字列の長さ（UTF-16）で数えるので、絵文字は2文字になる
  awk 'BEGIN { for (i = 0; i < 12000; i++) printf "😀"; print "" }' >"$REPO/.claude/dev-workflow/task-flow.md"
  run_hook
  assert_success
  n="$(jq -rn --arg s "$output" '$s | explode | map(if . > 65535 then 2 else 1 end) | add')"
  [ "$n" -le 10000 ] || fail "UTF-16 で ${n} 文字あります"
  [ "$n" -ge 9999 ] || fail "切りすぎています（UTF-16 で ${n} 文字）"
  assert_output --partial "続きは次のファイルを読んでください: "
}

@test "切ったときの知らせでは、読み直すファイルを「、」で区切る（空白を含むパスでも切れ目が分かる）" {
  export WORKFLOW_USER_DIR="$TMP/John Smith"
  mkdir -p "$WORKFLOW_USER_DIR"
  echo "個人の追記です" >"$WORKFLOW_USER_DIR/task-flow.md"
  awk 'BEGIN { for (i = 0; i < 12000; i++) printf "あ"; print "" }' >"$REPO/.claude/dev-workflow/task-flow.md"
  run_hook
  assert_success
  assert_output --partial "続きは次のファイルを読んでください: $WORKFLOW_USER_DIR/task-flow.md、$REPO/.claude/dev-workflow/task-flow.md）"
}

@test "追記が大きくても（引数の上限の 128 KiB を超えても）、切って流れを出す" {
  awk 'BEGIN { for (i = 0; i < 50000; i++) printf "あ"; print "" }' >"$WORKFLOW_USER_DIR/task-flow.md"
  run_hook
  assert_success
  assert_equal "$(jq -rn --arg s "$output" '$s | length')" 10000
  assert_output --partial "$(cat "$DEFAULT")"
  assert_output --partial "続きは次のファイルを読んでください: $WORKFLOW_USER_DIR/task-flow.md）"
}

@test "フックの出力に、ワークツリーが要らないタスク（リポジトリを変えない）の進め方が書いてある" {
  run_hook
  assert_success
  assert_output --partial 'ワークツリーとブランチを作らずに着手できます'
  # shellcheck disable=SC2016 # バッククォートは流れの本文の文字で、展開させない
  assert_output --partial 'もう一度 `/dev-workflow:task-start` でワークツリーを作ってから変えます'
}

@test "フックの出力に、Issue の分け方を提案するときは起票の前の相談でも task-create を呼ぶことが書いてある" {
  run_hook
  assert_success
  # shellcheck disable=SC2016 # バッククォートは流れの本文の文字で、展開させない
  assert_output --partial '起票の前の相談（ファイルを変えない段階）でも、自分で案を作らずに `/dev-workflow:task-create` を呼び'
  # ファイルを変える作業の流れ（番号の付いた段階）の中ではなく、流れの外の項目にちょうど1つ書く
  run grep -cF '/dev-workflow:task-create` を呼び' "$DEFAULT"
  assert_output 1
  run grep -cE '^- .*/dev-workflow:task-create` を呼び' "$DEFAULT"
  assert_output 1
}
