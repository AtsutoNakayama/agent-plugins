#!/usr/bin/env bash
# 開いている Issue が無いリポジトリ。起票の依頼に、下書きを見せて承認を求めて止まるか（起票しないか）を見る
set -euo pipefail
# shellcheck source=../lib/scaffold.bash
. "$(dirname "$0")/../lib/scaffold.bash"
eval_repo
fake_gh_defaults
