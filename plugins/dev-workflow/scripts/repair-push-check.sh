#!/usr/bin/env bash
# 無人で push する前に、push で origin に入る変更のパスを機械的に確かめる（ADR 000285「無人で push する条件」）。
# push の対象に .github/workflows/ か .claude/ の変更が含まれていたら、push してはいけない（ok が false）。
# 何も変えない（読むだけ。push もしない）。
#
# 使い方: repair-push-check.sh --base-branch B [--branch X]
#   --base-branch B  取り込んだ base_branch（例: main）。origin/B と同じ内容のパスは、取り込んだ main の変更なので数えない
#   --branch X       push するブランチ。省略すると今のブランチ。origin/X があれば、それとの差を見る。
#                    origin/X が無い（初回の push）ときは、origin/B との差（PR の変更の全体）を見る
#
# 出力（JSON）: {ok, forbidden（止める理由になるパス）, compared_with（差を取った相手）}
#
# 止まるとき: 引数の誤り（終了コード 64）、origin/B が無い（2）
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require git jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

base="" branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-branch | --branch)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      if [ "$1" = --base-branch ]; then base="$2"; else branch="$2"; fi
      shift 2
      ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$base" ] || dw_die "--base-branch は必須です" 64
[ -n "$branch" ] || branch="$(git rev-parse --abbrev-ref HEAD)"

git rev-parse --verify --quiet "refs/remotes/origin/${base}" >/dev/null \
  || dw_die "origin/${base} がありません（git fetch origin ${base} を先に実行してください）" 2

if git rev-parse --verify --quiet "refs/remotes/origin/${branch}" >/dev/null; then
  against="origin/${branch}"
else
  against="origin/${base}"
fi

forbidden='[]'
# パスに改行が入っていても壊れないよう -z で読む
while IFS= read -r -d '' path; do
  case "$path" in
    .github/workflows/* | .claude/*) ;;
    *) continue ;;
  esac
  # 取り込んだ base_branch と同じ内容なら、このブランチの変更ではない
  if git diff --quiet "origin/${base}" HEAD -- "$path"; then
    continue
  fi
  forbidden="$(jq -c --arg p "$path" '. + [$p]' <<<"$forbidden")"
done < <(git diff --name-only -z "$against" HEAD)

jq -n --argjson f "$forbidden" --arg c "$against" '{ok: ($f | length == 0), forbidden: $f, compared_with: $c}'
