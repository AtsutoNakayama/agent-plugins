#!/usr/bin/env bats
# CI（.github/workflows/lint.yml）の「non-ASCII right after $var」の検査が、bats のテストも対象にし、
# \$ でエスケープした（展開しない）$ は見逃すことを確かめる。
# 検査が *.sh・*.bash だけを見ていたので、tests/*.bats の "（$p）" が macOS の bash 3.2 で落ちるまで見つからなかった（#336）。

load test_helper

setup() {
  test_helper_setup
  mark_set_up
  ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  # 検査は GNU grep の -P を使い、lint のジョブ（ubuntu）でだけ動く。-P の無い grep（macOS）では確かめない
  local rc=0
  grep -P 'a' <<<a >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || skip "grep -P が使えません"
  # lint.yml から、この検査の run の中身を取り出す（次の「- name:」の手前まで。run: の行と字下げは外す）
  awk '
    /- name: non-ASCII right after \$var/ { on = 1; next }
    on && /^      - name:/ { exit }
    on && /^        run: \|/ { body = 1; next }
    on && body { sub(/^          /, ""); print }
  ' "$ROOT/.github/workflows/lint.yml" >"$TMP/check.sh"
  [ -s "$TMP/check.sh" ]
  mkdir -p "$TMP/work/plugins" "$TMP/work/tests" "$TMP/work/.github/scripts"
}

run_check() {
  CDPATH='' cd "$TMP/work" || return 1
  run bash "$TMP/check.sh"
}

@test "変数の直後に日本語がある行を、*.bats でも *.sh でも見つけて失敗する" {
  # 検査の対象の文字列の $ は、このファイル自身が検査に当たらないよう、変数 d から作る
  local d='$'
  printf '%s\n' "  assert_output --partial \"commit.pattern（${d}p）が文字列ではありません\"" >"$TMP/work/tests/a.bats"
  run_check
  assert_failure 1
  assert_output --partial 'tests/a.bats:1:'
  assert_output --partial '波括弧で囲んでください'

  rm "$TMP/work/tests/a.bats"
  printf '%s\n' "echo \"ブランチ（${d}b）\"" >"$TMP/work/plugins/a.sh"
  run_check
  assert_failure 1
  assert_output --partial 'plugins/a.sh:1:'
}

@test "波括弧で囲んだ変数・\\$ でエスケープした \$・コメントの行は見逃す" {
  local d='$'
  printf '%s\n' \
    "  assert_output --partial \"commit.pattern（${d}{p}）が文字列ではありません\"" \
    "@test \"展開前の \\${d}HOME・\\${d}{HOME} で指しても\" {" \
    "  # 親（${d}TMP）を返さない" >"$TMP/work/tests/a.bats"
  printf '%s\n' "echo \"展開前の \\${d}HOME・ブランチ（${d}{b}）\"" >"$TMP/work/plugins/a.sh"
  run_check
  assert_success
}

@test "バックスラッシュが偶数個の後の \$（展開される）は見つけ、奇数個の後は見逃す" {
  local d='$'
  # 二重引用符の中の \\$v は、\\ が1文字の \ になり、$v は展開される
  printf '%s\n' "echo \"パス（\\\\${d}v）\"" >"$TMP/work/plugins/a.sh"
  run_check
  assert_failure 1
  assert_output --partial 'plugins/a.sh:1:'

  printf '%s\n' "echo \"パス（\\\\\\${d}v）\"" >"$TMP/work/plugins/a.sh"
  run_check
  assert_success
}
