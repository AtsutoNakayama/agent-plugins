#!/usr/bin/env bash
# メインのワークツリーの場所を JSON で出力する。task-finish・task-cancel が、削除するワークツリーの外へ移る先を求めるのに使う。
# サブモジュール（とそのワークツリー）や、bare リポジトリ＋ワークツリーの配置でも、git が記録している場所から確かめて求める
# （cd "$(git rev-parse --git-common-dir)/.." は、.git/modules や、作業ツリーの無い場所に移ってしまう）。
# 求められないとき（--separate-git-dir のワークツリーなど）は、終了コード 1 と1行のメッセージで失敗する。
#
# 使い方: main-root.sh
# 出力: {"main_root": "<メインのワークツリー>"}
#   bare リポジトリ＋ワークツリーの配置では、.git ファイルを置いたディレクトリになる（作業ツリーは無いが、cleanup.sh を実行できる）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require git jq

case "${1:-}" in
  -h | --help) LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
  "") ;;
  *) dw_die "不明な引数です: $1" 64 ;;
esac

root="$(dw_main_root "${WORKFLOW_REPO_ROOT:-$PWD}")" \
  || dw_die "メインのワークツリーが分かりません（リポジトリの外か、--separate-git-dir で作ったワークツリーです）"
jq -n --arg r "$root" '{main_root: $r}'
