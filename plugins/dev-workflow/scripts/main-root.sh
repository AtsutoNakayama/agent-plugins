#!/usr/bin/env bash
# 今いるリポジトリ（ワークツリー）の、メインのワークツリーのルートを JSON で出力する。何も変更しない。
# task-finish・task-cancel が、削除するワークツリーの外へ移る先を知るのに使う。
# git rev-parse --git-common-dir の親は、サブモジュールなどではメインのワークツリーではないので、lib/common.sh の dw_main_root で求める。
#
# 使い方: main-root.sh
#
# 出力（JSON）:
#   main_root   メインのワークツリーのルート（bare リポジトリ＋ワークツリーの配置では、.git ファイルを置いたディレクトリ）
#
# リポジトリの外では終了コード 64、メインのワークツリーが分からない（--separate-git-dir で作ったリポジトリのワークツリーなど）ときは
# 終了コード 2 で止まる。
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq git

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
main_root="$(dw_main_root "$repo_root")" || dw_die "メインのワークツリーが分かりません" 2
jq -n --arg m "$main_root" '{main_root: $m}'
