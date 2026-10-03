#!/usr/bin/env bats
# タスクの進め方を渡すフック（hooks/task-flow.sh）。
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

HOOKS="$BATS_TEST_DIRNAME/../plugins/dev-workflow/hooks"
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

@test "リポジトリの外では、既定の流れと個人の追記だけを出す" {
  mkdir -p "$TMP/outside"
  echo "個人の追記です" >"$WORKFLOW_USER_DIR/task-flow.md"
  echo "チームの追記です" >"$REPO/.claude/dev-workflow/task-flow.md"
  run_hook "$TMP/outside"
  assert_success
  assert_output --partial "$(cat "$DEFAULT")"
  assert_output --partial "個人の追記です"
  refute_output --partial "チームの追記です"
}

@test "cwd が無い・読めない入力でも、既定の流れを出す" {
  run "${TEST_BASH:-bash}" "$HOOKS/task-flow.sh" <<<'not json'
  assert_success
  assert_output --partial "$(cat "$DEFAULT")"
  run_hook "$TMP/no-such-dir"
  assert_success
  assert_output --partial "$(cat "$DEFAULT")"
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
