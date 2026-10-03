#!/usr/bin/env bash
# Claude Code のフック（SessionStart）。タスクの進め方を標準出力に出し、Claude に読み込ませる。
# スキルは呼ばれたときにしか読み込まれず、プラグインはいつも読み込まれるルール（CLAUDE.md など）を配れないので、
# 起動・/resume・/clear・コンパクトのたびに流れを渡す。
#
# 出力する順（後ろほど優先。config.sh の guides.task-flow と同じ順）:
#   1. プラグインの既定             defaults/task-flow.md
#   2. 個人の追記                   ~/.claude/dev-workflow/task-flow.md
#   3. チームの追記                 <repo>/.claude/dev-workflow/task-flow.md
#
# 毎セッション動くので、config.sh は呼ばずに2つのファイルを直接見る。
# Claude Code はフックの出力が上限（1 万文字）を超えると先頭の一部しか渡さないので、上限に収めて、
# 切ったときは読み直すファイルを知らせる。
# 標準入力でフックの入力（JSON）を受け取る。失敗してもセッションを止めないよう、読めないものは飛ばす。
set -euo pipefail

# shellcheck source=../scripts/lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../scripts/lib/common.sh"

# Claude Code がフックの出力をそのまま渡す上限（文字数）
limit=10000
default_file="$DW_PLUGIN_ROOT/defaults/task-flow.md"

# jq が無ければ、既定の流れだけを出す（既定は上限より十分に短い）
if ! command -v jq >/dev/null 2>&1; then
  cat "$default_file"
  exit 0
fi

input="$(cat)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null || true)"
repo_root="$( (cd "${cwd:-.}" 2>/dev/null && dw_repo_root) || true)"

files=("$(dw_user_dir)/task-flow.md")
[ -n "$repo_root" ] && files+=("$repo_root/.claude/dev-workflow/task-flow.md")

out="$(cat "$default_file")"
added=()
for f in "${files[@]}"; do
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    continue
  fi
  body="$(cat "$f")"
  [ -n "$body" ] || continue
  out="${out}

---

以下は ${f} の追記です。上の内容と食い違うときは、こちらを優先します。

${body}"
  added+=("$f")
done

# 上限を超えたら、知らせの分を空けて切る。Claude Code は JavaScript の文字列の長さ（UTF-16）で数えるので、
# BMP の外の文字（絵文字など）は2文字と数える。jq は文字単位で切るので、日本語の途中で切れない。
# ファイルは空白を含むパスでも切れ目が分かるよう「、」で区切る。
# 本文は一時ファイルで渡す。引数（--arg）では 128 KiB を超えると jq を起動できず、標準入力（-R）では
# 大きな入力の BMP の外の文字が読み込みの区切りで割れることがあるので
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf '%s' "$out" >"$tmp"
jq -rn --rawfile out "$tmp" --argjson limit "$limit" '
  def width: if . > 65535 then 2 else 1 end;
  def len16: explode | map(width) | add // 0;
  # UTF-16 で $n 文字に収まる先頭の部分
  def head16($n):
    . as $s
    | reduce ($s | explode)[] as $c ({i: 0, len: 0, full: false};
        if .full then .
        elif .len + ($c | width) > $n then .full = true
        else .i += 1 | .len += ($c | width) end)
    | $s[0:.i];
  if ($out | len16) <= $limit then $out
  else
    "\n\n（上限の \($limit) 文字を超えたので、ここで切りました。続きは次のファイルを読んでください: \($ARGS.positional | join("、"))）" as $note
    | ($out | head16($limit - ($note | len16))) + $note
  end' --args ${added[@]+"${added[@]}"}
