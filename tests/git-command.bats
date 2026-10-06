#!/usr/bin/env bats
# git のコマンドの解析（lib/git-command.sh）の関数を、直接呼んで確かめる。
# フック（guard-git.sh・pr-link.sh）を通したテストは、guard-git.bats・pr-link.bats にある。
# コールバックなどの準備は、起動した bash の中で展開させるので、単引用符で渡す
# shellcheck disable=SC2016

load test_helper

# common.sh と git-command.sh を読み込んで、<準備> を実行してから、関数を1つ呼ぶ。
# <準備> では、コールバックなどの関数を定義する。使い方: run_gc <準備> <関数> [引数]...
run_gc() {
  # shellcheck disable=SC2016 # 引数は、起動した bash の中で展開させる
  run "${TEST_BASH:-bash}" -c '. "$1/common.sh"; . "$1/git-command.sh"; eval "$2"; shift 2; "$@"' _ "$SCRIPTS/lib" "$@"
}

@test "gc_args は、コールバックの終了コードを見ず、gc_stop で読むのをやめる" {
  # コールバックが 0 以外を返しても、残りの引数を読む
  run_gc 'cb() { echo "[$1]"; return 1; }' gc_create_opts cb cC "--create=" -c a -c b
  assert_success
  assert_output "$(printf '[a]\n[b]')"
}

@test "gc_args は、コールバックを普通の文として呼ぶので、その中でも set -e が効く" {
  run_gc 'set -e; cb() { false; echo after; }' gc_create_opts cb cC "--create=" -c a
  assert_failure
  refute_output --partial after
}

@test "値を取るオプションが、値の無いまま終わったときは、作るブランチの名前として渡さない" {
  run_gc 'cb() { echo "[$1]"; }' gc_create_opts cb cC "--create=" -c
  assert_success
  assert_output ""
  run_gc 'cb() { echo "[$1]"; }' gc_create_opts cb bB "" ../wt -b
  assert_success
  assert_output ""
}

@test "gc_skip_opts は、-- を数えて、その次の語で止まる" {
  run_gc '' eval 'gc_skip_opts u "--unset=" -u FOO -- -x git; echo "$gc_nopt ${gc_optn[*]}"'
  assert_success
  assert_output "3 -u"
  run_gc '' eval 'gc_skip_opts u "--unset=" -i git; echo "$gc_nopt ${gc_optn[*]}"'
  assert_output "1 -i"
}
