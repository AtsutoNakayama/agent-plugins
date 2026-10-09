#!/usr/bin/env bash
# 無人の push の回数（repair.max_pushes_per_pr と比べる値）を、PR のコメントの repair-run のマーカーから数えて JSON で出力する
# （ADR 000339「push の回数の数え方」）。判断は入力の値だけで決める（git も GitHub も使わない）。
#
# 使い方: gh pr view <PR番号> --json comments | repair-run-count.sh --head SHA [--logins L1,L2] [--since TIME]
#   標準入力  PR のコメント。`gh pr view --json comments` の出力（{comments: [...]}）か、
#             `gh api repos/{owner}/{repo}/issues/<PR番号>/comments` の出力（配列。--paginate --slurp の配列の配列も可）
#   --head SHA    今の PR の head の sha（16 進）
#   --logins L    数える投稿者のログイン名（, 区切り。repair.reply_logins）。省略すると投稿者を問わない
#   --since TIME  この時刻（ISO 8601。例: 2026-10-10T01:02:03Z）より後のコメントだけを数える（再開の起点。ADR 000285）
#
# 数え方:
#   - 本文の先頭が <!-- dev-workflow:repair-run head=<sha> --> のコメントは、<sha> が今の head と違うもの（PR の head が
#     そこから進んだもの）だけを、<sha> の値ごとに1回と数える。<sha> が今の head と同じもの（push に失敗した・push の前に
#     止まった回）は数えない。sha は大文字と小文字を区別しない
#   - 本文の先頭が <!-- dev-workflow:repair-run --> の古い形式（head が無い）は、1つを1回と数える（ADR 000285）
#
# 出力（JSON）: {count（数えた回数）, pushed_heads（数えた head の sha）, legacy（古い形式の数）,
#               not_pushed（head が今の head と同じで数えなかった数）, runs（対象の repair-run の数）}
#
# 止まるとき: --head が無い・16 進でない・--since が ISO 8601 でない・不明な引数・入力が JSON のコメントの一覧でない（64）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

head_sha="" logins="" since=""
while [ $# -gt 0 ]; do
  case "$1" in
    --head | --logins | --since)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --head) head_sha="$2" ;;
        --logins) logins="$2" ;;
        --since) since="$2" ;;
      esac
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$head_sha" ] || dw_die "--head は必須です" 64
case "$head_sha" in *[!0123456789abcdefABCDEF]*) dw_die "--head は 16 進の sha にしてください: ${head_sha}" 64 ;; esac
if [ -n "$since" ]; then
  jq -en --arg t "$since" '$t | fromdateiso8601' >/dev/null 2>&1 \
    || dw_die "--since は ISO 8601 の時刻（例: 2026-10-10T01:02:03Z）にしてください: ${since}" 64
fi

# コメントは長くなりうるので、引数ではなくファイルで jq に渡す
input_file="$(mktemp "${TMPDIR:-/tmp}/repair-run-count.XXXXXX")"
trap 'rm -f "$input_file"' EXIT
cat >"$input_file"
jq -e '(type == "object" and (.comments | type) == "array") or type == "array"' "$input_file" >/dev/null 2>&1 \
  || dw_die "入力は、gh pr view --json comments か gh api の issues/<番号>/comments の出力（JSON）にしてください" 64

jq -c --arg head "$head_sha" --arg logins "$logins" --arg since "$since" '
  (if type == "object" then .comments else . end | flatten) as $all
  | ($logins | split(",") | map(select(. != ""))) as $allowed
  | [ $all[]
      | select(type == "object")
      | (.author.login // .user.login // "") as $who
      | (.createdAt // .created_at // "") as $at
      | select(($allowed | length) == 0 or ($who | IN($allowed[])))
      | select($since == "" or (($at | fromdateiso8601? // 0) > ($since | fromdateiso8601)))
      | (.body // "") | capture("^\\s*<!-- dev-workflow:repair-run(?: head=(?<sha>[0-9A-Fa-f]+))? -->")
      | .sha
    ] as $runs
  | ($head | ascii_downcase) as $now
  | [ $runs[] | select(. != null) | ascii_downcase ] as $with_head
  | ([ $with_head[] | select(. != $now) ] | unique) as $pushed
  | ([ $runs[] | select(. == null) ] | length) as $legacy
  | {
      count: (($pushed | length) + $legacy),
      pushed_heads: $pushed,
      legacy: $legacy,
      not_pushed: ([ $with_head[] | select(. == $now) ] | length),
      runs: ($runs | length)
    }' "$input_file"
