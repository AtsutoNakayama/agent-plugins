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
# 止まるとき: 引数の誤り・detached HEAD で --branch が無い（終了コード 64）、origin/B が無い・git diff に失敗した（2）
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
if [ -z "$branch" ]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
  # detached HEAD では push するブランチが決まらない
  [ "$branch" != HEAD ] || dw_die "detached HEAD です。--branch で push するブランチを指定してください" 64
fi

git rev-parse --verify --quiet "refs/remotes/origin/${base}" >/dev/null \
  || dw_die "origin/${base} がありません（git fetch origin ${base} を先に実行してください）" 2

if git rev-parse --verify --quiet "refs/remotes/origin/${branch}" >/dev/null; then
  against="origin/${branch}"
else
  against="origin/${base}"
fi

forbidden='[]'
# プロセス置換の中の git diff の失敗は while に伝わらず、空入力（禁止パスなし）と読まれるので、先にファイルへ取って確かめる
diff_file="$(mktemp "${TMPDIR:-/tmp}/repair-push-check.XXXXXX")"
trap 'rm -f "$diff_file"' EXIT
git diff --name-only --no-renames -z "$against" HEAD >"$diff_file" \
  || dw_die "git diff に失敗しました（${against} と HEAD の差を取れません）" 2
# パスに改行が入っていても壊れないよう -z で読む
while IFS= read -r -d '' path; do
  case "$path" in
    .github/workflows/* | .claude/*) ;;
    *) continue ;;
  esac
  # 取り込んだ base_branch と同じ内容なら、このブランチの変更ではない
  if git --literal-pathspecs diff --quiet --no-renames "origin/${base}" HEAD -- "$path"; then
    continue
  fi
  forbidden="$(jq -c --arg p "$path" '. + [$p]' <<<"$forbidden")"
done <"$diff_file"

jq -n --argjson f "$forbidden" --arg c "$against" '{ok: ($f | length == 0), forbidden: $f, compared_with: $c}'
