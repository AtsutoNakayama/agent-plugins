#!/usr/bin/env bash
# プラグインの eval（plugins/dev-workflow/evals/）を、偽の gh（tests/eval/bin/gh）を PATH の先頭に足して実行する。
# ケースの準備のスクリプト（--scaffold）と、Bash・Edit・Write の使用を許す。ほかのオプションはそのまま claude plugin eval に渡す。
#
# 使い方: tests/eval/run.sh [claude plugin eval のオプション]...
#   例: tests/eval/run.sh --model sonnet --tag task-create --runs 1 --ablation none
set -euo pipefail

here="$(CDPATH='' cd "$(dirname "$0")" && pwd)"
plugin="$(cd "$here/../../plugins/dev-workflow" && pwd)"

command -v claude >/dev/null 2>&1 || { echo "error: claude（Claude Code）が見つかりません" >&2; exit 1; }

# 対象（プラグインのディレクトリ）は、リストを取るオプション（--allow-tools など）より前に置く
PATH="$here/bin:$PATH" exec claude plugin eval "$plugin" --scaffold --allow-tools Bash Edit Write "$@"
