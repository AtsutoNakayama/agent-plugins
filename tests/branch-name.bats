#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

@test "type ラベルと短い説明からブランチ名を作る" {
  setup_fake_gh
  run_script branch-name.sh --issue 17 --slug "Add Login Page"
  assert_success
  assert_equal "$(jq -c . <<<"$output")" '{"branch":"feat/17-add-login-page","type":"feat","issue":17,"slug":"add-login-page"}'
}

@test "短い説明は英数字以外を - にまとめ、40 文字までにする" {
  setup_fake_gh
  run_script branch-name.sh --issue 17 --type fix --slug "  Fix: CI!! --- flaky テスト $(printf 'a%.0s' {1..50})"
  assert_success
  slug="$(jq -r .slug <<<"$output")"
  assert_regex "$slug" '^fix-ci-flaky-a+$'
  [ "${#slug}" -le 40 ]
}

@test "--slug が無い、または英数字が無い（日本語や記号だけ）ときはエラーになり、Issue を読まない" {
  setup_fake_gh
  run_script branch-name.sh --issue 99
  assert_failure 64
  assert_output --partial "--slug は必須です"
  run_script branch-name.sh --issue 99 --slug "ログイン画面"
  assert_failure 64
  assert_output --partial "短い説明に英数字がありません"
  run_script branch-name.sh --issue 99 --slug " - ! "
  assert_failure 64
  assert_output --partial "短い説明に英数字がありません"
}

@test "type 以外のラベルは無視する" {
  setup_fake_gh
  fake_issue 17 '["fix", "priority: high"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_equal "$(jq -r .branch <<<"$output")" fix/17-x
}

@test "設定の branch.pattern に従う" {
  setup_fake_gh
  echo '{"branch": {"pattern": "{issue_number}/{type}-{slug}"}}' >.claude/dev-workflow/config.json
  run_script branch-name.sh --issue 17 --slug x
  assert_equal "$(jq -r .branch <<<"$output")" 17/feat-x
}

@test "type ラベルが無い、または複数あればエラーになる" {
  setup_fake_gh
  fake_issue 17 '["priority: high"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_failure 2
  assert_output --partial "Issue #17 に type ラベルがありません"
  fake_issue 17 '["feat", "fix"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_failure 2
  assert_output --partial "type ラベルが複数あります（feat, fix）"
}

@test "--type を指定すれば Issue を読まない" {
  setup_fake_gh
  run_script branch-name.sh --issue 99 --type docs --slug readme
  assert_success
  assert_equal "$(jq -r .branch <<<"$output")" docs/99-readme
}

@test "--check は規約に合えば valid: true で終了コード 0" {
  run_script branch-name.sh --check feat/17-add-login
  assert_success
  assert_equal "$(jq -c '[.valid, .reason]' <<<"$output")" '[true,null]'
}

@test "--check は規約に合わなければ理由を出して終了コード 1" {
  for name in Feat/17-x feat/ログイン feat//17 feat/17- -feat/17 feat/17-x.lock "feat/17 x"; do
    run_script branch-name.sh --check "$name"
    assert_failure 1
    assert_equal "$(jq -r .valid <<<"$output")" false
  done
}

@test "--check は branch.pattern の形に合わなければ理由を出して終了コード 1" {
  for name in foo wip/17-x feat/x-y feat/17 feat/17-a--b feat/17-x/y; do
    run_script branch-name.sh --check "$name"
    assert_failure 1
    assert_equal "$(jq -r .reason <<<"$output")" "branch.pattern（{type}/{issue_number}-{slug}）の形になっていません"
  done
}

@test "--check は設定の branch.pattern と labels.types に従う" {
  echo '{"branch": {"pattern": "{type}-{issue_number}/{slug}"}, "labels": {"types": ["feat", "wip"]}}' >.claude/dev-workflow/config.json
  run_script branch-name.sh --check wip-17/add-login
  assert_success
  for name in feat/17-add-login fix-17/add-login wip-x/add-login; do
    run_script branch-name.sh --check "$name"
    assert_failure 1
  done
}

# --check の valid と、dw_parse_branch が取り出す「<type>|<番号>」が、同じ名前で一致することを確かめる
# 受け入れる名前は期待する「<type>|<番号>」を、拒否する名前は「|」を渡す
# 使い方: assert_check_matches_parse <ブランチ名> <期待する type|番号>
assert_check_matches_parse() {
  local config parsed valid=true
  [ "$2" = "|" ] && valid=false
  run_script branch-name.sh --check "$1"
  assert_equal "$(jq -r .valid <<<"$output")" "$valid"
  # config.sh の失敗を見逃さないよう run で呼ぶ（--check の確認は済んでいるので、$output を上書きしてよい）
  run "${TEST_BASH:-bash}" "$SCRIPTS/config.sh"
  assert_success
  config="$output"
  # shellcheck disable=SC2016 # $1〜$3 は bash -c の中で展開する
  parsed="$("${TEST_BASH:-bash}" -c '. "$1/common.sh"; dw_parse_branch "$2" "$3"' _ "$SCRIPTS/lib" "$config" "$1")"
  assert_equal "$parsed" "$2"
}

@test "--check と dw_parse_branch は、既定の branch.pattern で同じ名前を受け入れ・拒否する" {
  assert_check_matches_parse feat/17-add-login "feat|17"
  assert_check_matches_parse fix/3-a "fix|3"
  # 設定に無い type
  assert_check_matches_parse wip/17-add-login "|"
  # 番号が数字でない
  assert_check_matches_parse feat/x-add-login "|"
  # 末尾がハイフンの slug
  assert_check_matches_parse feat/17-add- "|"
  assert_check_matches_parse feat/17-add-login- "|"
}

@test "--check と dw_parse_branch は、独自の branch.pattern と labels.types でも同じ名前を受け入れ・拒否する" {
  echo '{"branch": {"pattern": "{type}-{issue_number}/{slug}"}, "labels": {"types": ["feat", "wip"]}}' >.claude/dev-workflow/config.json
  assert_check_matches_parse wip-17/add-login "wip|17"
  assert_check_matches_parse feat-3/a "feat|3"
  # 設定に無い type（既定の type でも、設定に無ければ拒否する）
  assert_check_matches_parse fix-17/add-login "|"
  # 番号が数字でない
  assert_check_matches_parse wip-x/add-login "|"
  # 末尾がハイフンの slug
  assert_check_matches_parse wip-17/add-login- "|"
  # 既定の pattern の形は拒否する
  assert_check_matches_parse feat/17-add-login "|"
}

@test "--check と dw_parse_branch は、problem() が拒否せず正規表現だけが拒否する名前・先頭が 0 の番号・スラッシュが多い名前でも一致する" {
  # problem() は通し、branch.pattern の正規表現だけが拒否する（slug の中の連続したハイフン）
  assert_check_matches_parse feat/17-add--login "|"
  # problem() も拒否する名前（大文字・末尾のハイフン）でも、dw_parse_branch は取り出さない
  assert_check_matches_parse feat/17-Add "|"
  assert_check_matches_parse feat/17- "|"
  # 先頭が 0 の番号は、そのまま取り出す（番号をそろえるのは使う側）
  assert_check_matches_parse feat/017-x "feat|017"
  # スラッシュが多い名前
  assert_check_matches_parse feat/17-a/b "|"
  assert_check_matches_parse wip/feat/17-a "|"
  assert_check_matches_parse feat/x/17-a "|"
}

@test "--check と dw_parse_branch は、別の type の接頭辞になる type（feat と feature）でも一致する" {
  echo '{"labels": {"types": ["feat", "feature"]}}' >.claude/dev-workflow/config.json
  assert_check_matches_parse feature/17-add-login "feature|17"
  assert_check_matches_parse feat/17-add-login "feat|17"
  assert_check_matches_parse featur/17-add-login "|"
  assert_check_matches_parse features/17-add-login "|"
}

@test "--check と dw_parse_branch は、正規表現の特殊文字を含む branch.pattern でも一致する" {
  # . はどの1文字にも合い、(…)? は省略できる
  echo '{"branch": {"pattern": "{type}.(wip-)?{issue_number}-{slug}"}}' >.claude/dev-workflow/config.json
  assert_check_matches_parse feat/17-add-login "feat|17"
  assert_check_matches_parse featx17-add-login "feat|17"
  assert_check_matches_parse feat/wip-17-add-login "feat|17"
  # . も1文字に合うので、feat17-add-login は「feat|7」になる（--check も受け入れる）
  assert_check_matches_parse feat17-add-login "feat|7"
  assert_check_matches_parse feat-add-login "|"
  assert_check_matches_parse feat/wip17-add-login "|"
}

@test "--check は branch.pattern の形に合わない名前で、終了コード 1 で終わる（設定の誤りの 2 にしない）" {
  for name in feat/17-add--login feat/17-a/b wip/17-add-login; do
    run_script branch-name.sh --check "$name"
    assert_failure 1
    assert_equal "$(jq -r .valid <<<"$output")" false
  done
}

@test "--check は設定を読めなければ終了コード 2" {
  echo '{' >.claude/dev-workflow/config.json
  run_script branch-name.sh --check feat/17-add-login
  assert_failure 2
}

@test "PR の番号は Issue として受け取らず、PR のラベルでブランチ名を作らない" {
  setup_fake_gh
  echo '{"url": "https://github.com/me/demo/pull/21", "number": 21, "labels": [{"name": "feat"}]}' >"$FIX/issue-21.json"
  run_script branch-name.sh --issue 21 --slug x
  assert_failure 2
  assert_output --partial "#21 は PR です。Issue の番号を指定してください"
}

@test "type ラベルは大文字と小文字を区別せずに照合し、設定の書き方の type にする（Fix と fix は1つと数える）" {
  setup_fake_gh
  fake_issue 17 '["Fix"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_success
  assert_equal "$(jq -r .branch <<<"$output")" fix/17-x
  fake_issue 17 '["fix", "FIX"]'
  run_script branch-name.sh --issue 17 --slug x
  assert_success
  assert_equal "$(jq -r .type <<<"$output")" fix
}

@test "--check は branch.pattern が正規表現として正しくなければ、設定の誤りとして終了コード 2" {
  echo '{"branch": {"pattern": "{type}/{issue_number}-{slug}("}}' >.claude/dev-workflow/config.json
  run_script branch-name.sh --check feat/17-add-login
  assert_failure 2
  assert_output --partial "正規表現として正しくありません"
}

@test "--check は branch.pattern に改行を含んでいても、設定の誤りを1行のメッセージで報告する" {
  printf '%s\n' '{"branch": {"pattern": "{type}/{issue_number}-{slug}(\n)("}}' >.claude/dev-workflow/config.json
  run_script branch-name.sh --check feat/17-add-login
  assert_failure 2
  assert_output --partial "正規表現として正しくありません"
  assert_equal "${#lines[@]}" 1
}

@test "dw_parse_branch は branch.pattern が正規表現として正しくなければ、取り出せないのではなく設定の誤りで終了コード 2" {
  # shellcheck disable=SC2016 # bash -c の中で展開させる
  run "${TEST_BASH:-bash}" -c '. "$1/lib/common.sh"; dw_parse_branch "$2" feat/17-x' _ "$SCRIPTS" \
    '{"labels":{"types":["feat"]},"branch":{"pattern":"{type}/{issue_number}-{slug}("}}'
  assert_failure 2
  assert_output --partial "正規表現として正しくありません"
  # shellcheck disable=SC2016 # bash -c の中で展開させる
  run "${TEST_BASH:-bash}" -c '. "$1/lib/common.sh"; dw_parse_branch "$2" feat/17-x' _ "$SCRIPTS" \
    '{"labels":{"types":["feat"]},"branch":{"pattern":"{type}/{issue_number}-{slug}"}}'
  assert_success
  assert_output "feat|17"
}

@test "dw_check_branch_pattern は、設定が空・部分的（branch.pattern が無い・null、labels.types が無い）でも、誤りとはしない" {
  for c in '{}' '{"labels":{"types":["feat"]}}' '{"branch":{"pattern":null},"labels":{"types":["feat"]}}' '{"branch":{"pattern":"{type}/{issue_number}"}}'; do
    # shellcheck disable=SC2016 # bash -c の中で展開させる
    run "${TEST_BASH:-bash}" -c '. "$1/lib/common.sh"; dw_check_branch_pattern "$2"' _ "$SCRIPTS" "$c"
    assert_success
  done
}

# lib/common.sh の関数を、テストの bash（TEST_BASH）で呼ぶ
# 使い方: run_common <関数> [引数]...
run_common() {
  # shellcheck disable=SC2016 # bash -c の中で展開させる
  run "${TEST_BASH:-bash}" -c '. "$1/lib/common.sh"; shift; "$@"' _ "$SCRIPTS" "$@"
}

# 設定 <JSON> で、dw_check_branch_pattern（終了コード 1）・dw_parse_branch・--check（終了コード 2）が、
# どれも <メッセージ> を含む1行で設定の誤りを報告し、正規表現の誤りとは報告しないことを確かめる
# 使い方: assert_config_error <設定の JSON> <メッセージ>
assert_config_error() {
  run_common dw_check_branch_pattern "$1"
  assert_failure 1
  assert_output --partial "$2"
  refute_output --partial "正規表現として正しくありません"
  assert_equal "${#lines[@]}" 1
  run_common dw_parse_branch "$1" feat/17-x
  assert_failure 2
  assert_output --partial "$2"
  refute_output --partial "正規表現として正しくありません"
  assert_equal "${#lines[@]}" 1
  printf '%s\n' "$1" >.claude/dev-workflow/config.local.json
  run_script branch-name.sh --check feat/17-add-login
  assert_failure 2
  assert_output --partial "$2"
  refute_output --partial "正規表現として正しくありません"
  assert_equal "${#lines[@]}" 1
}

@test "branch.pattern が文字列でない（数値・オブジェクト・配列・真偽値）ときは、設定の誤りとして終了コード 2 で報告する" {
  assert_config_error '{"branch":{"pattern":5},"labels":{"types":["feat"]}}' 'branch.pattern（5）が文字列ではありません'
  assert_config_error '{"branch":{"pattern":{"a":1}},"labels":{"types":["feat"]}}' 'branch.pattern（{"a":1}）が文字列ではありません'
  assert_config_error '{"branch":{"pattern":["x"]},"labels":{"types":["feat"]}}' 'branch.pattern（["x"]）が文字列ではありません'
  assert_config_error '{"branch":{"pattern":true},"labels":{"types":["feat"]}}' 'branch.pattern（true）が文字列ではありません'
}

@test "labels.types が文字列の配列でないときは、正規表現の誤りではなく labels.types の誤りとして報告する" {
  assert_config_error '{"branch":{"pattern":"{type}/{issue_number}-{slug}"},"labels":{"types":"feat"}}' 'labels.types（"feat"）が文字列の配列ではありません'
  assert_config_error '{"branch":{"pattern":"{type}/{issue_number}-{slug}"},"labels":{"types":["feat",1]}}' 'labels.types（["feat",1]）が文字列の配列ではありません'
}

@test "labels.types に正規表現の記号を含む type があれば、検査の段階で設定の誤りとして報告する（実際の labels.types で検査する）" {
  assert_config_error '{"branch":{"pattern":"{type}/{issue_number}-{slug}"},"labels":{"types":["feat","c++"]}}' 'labels.types の「c++」に正規表現の記号があります'
  assert_config_error '{"branch":{"pattern":"{type}/{issue_number}-{slug}"},"labels":{"types":["feat","fix("]}}' 'labels.types の「fix(」に正規表現の記号があります'
}

@test "設定が JSON として壊れているときは、正規表現の誤りではなく、JSON を読めないと報告する" {
  for c in '{' '{"branch":' '{}{}'; do
    run_common dw_check_branch_pattern "$c"
    assert_failure 1
    assert_output --partial "設定を JSON として読めません"
    refute_output --partial "正規表現として正しくありません"
    assert_equal "${#lines[@]}" 1
    run_common dw_parse_branch "$c" feat/17-x
    assert_failure 2
    assert_output --partial "設定を JSON として読めません"
    assert_equal "${#lines[@]}" 1
  done
}

@test "設定がオブジェクトでないなど、ほかの理由で検査できないときは、正規表現の誤りではなく、検査できない理由を報告する" {
  for c in '[]' '{"branch":"x"}' '{"branch":{"pattern":"{type}"},"labels":"x"}'; do
    run_common dw_check_branch_pattern "$c"
    assert_failure 1
    assert_output --partial "branch.pattern を検査できません"
    refute_output --partial "正規表現として正しくありません"
    assert_equal "${#lines[@]}" 1
  done
}

@test "branch.pattern が無い・null の設定では、dw_parse_branch は取り出せない（|）を出力し、エラーにしない" {
  for c in '{}' '{"labels":{"types":["feat"]}}' '{"branch":{"pattern":null},"labels":{"types":["feat"]}}'; do
    run_common dw_parse_branch "$c" feat/17-x
    assert_success
    assert_output "|"
  done
}

# jq を、呼ばれるたびに $TMP/jq.log に1行を足してから本物の jq を実行するものに置き換える。
# branch.pattern の正規表現の定義（def branch_re）を含む呼び出しは「branch」、ほかは「other」と記録する
use_counting_jq() {
  local real
  real="$(command -v jq)"
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/jq" <<SH
#!/bin/sh
case "\$*" in *"def branch_re"*) echo branch >>"$TMP/jq.log" ;; *) echo other >>"$TMP/jq.log" ;; esac
exec "$real" "\$@"
SH
  chmod +x "$TMP/bin/jq"
  export PATH="$TMP/bin:$PATH"
}

@test "dw_parse_branch・--check は、設定の検査と判定を1回の jq で行う（検査をやり直さない）" {
  use_counting_jq
  for c in '{"labels":{"types":["feat"]},"branch":{"pattern":"{type}/{issue_number}-{slug}"}}' \
    '{"labels":{"types":["feat"]},"branch":{"pattern":"{type}/{issue_number}-{slug}("}}' \
    '{"labels":{"types":["feat"]},"branch":{"pattern":5}}'; do
    rm -f "$TMP/jq.log"
    run_common dw_parse_branch "$c" feat/17-x
    assert_equal "$(wc -l <"$TMP/jq.log" | tr -d ' ')" 1
    rm -f "$TMP/jq.log"
    run_common dw_check_branch_pattern "$c"
    assert_equal "$(wc -l <"$TMP/jq.log" | tr -d ' ')" 1
  done
  # --check は設定を読む（config.sh）ほかに、branch.pattern の検査と判定で jq を1回だけ起動する
  for name in feat/17-add-login wip/17-add-login; do
    rm -f "$TMP/jq.log"
    run_script branch-name.sh --check "$name"
    assert_equal "$(grep -c '^branch$' "$TMP/jq.log")" 1
  done
  echo '{"branch": {"pattern": "{type}/{issue_number}-{slug}("}}' >.claude/dev-workflow/config.json
  rm -f "$TMP/jq.log"
  run_script branch-name.sh --check feat/17-add-login
  assert_failure 2
  assert_equal "$(grep -c '^branch$' "$TMP/jq.log")" 1
}
