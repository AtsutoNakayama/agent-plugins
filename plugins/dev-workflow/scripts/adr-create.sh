#!/usr/bin/env bash
# ADR（Architecture Decision Record）のファイルを、テンプレートから1つ作り、JSON で出力する。
#
# 使い方: adr-create.sh --issue N --name TEXT --template TYPE [--supersedes FILE]... [--dry-run]
#
#   --issue N          判断をした Issue の番号。ファイル名の先頭（4桁に0埋め）と front matter の issue になる
#   --name TEXT        短い名前（英語）。小文字にし、英数字以外は - にして 40 文字までに整える
#   --template TYPE    テンプレート（templates/adr/ の MADR 4.0.0 を日本語に訳したもの）
#                        full          全部の節・説明あり（adr-template.md）
#                        minimal       必須の節・説明あり（adr-template-minimal.md）
#                        bare          全部の節・説明なし（adr-template-bare.md）
#                        bare-minimal  必須の節・説明なし（adr-template-bare-minimal.md）
#   --supersedes FILE  この ADR が置き換える ADR（繰り返して複数書ける）。置き場所からの相対か、リポジトリのルートからの
#                      相対パス。置き換えられる側は、status の行だけを superseded by <この ADR> に書き換える
#   --dry-run          何も作らず書き換えず、することを JSON で出力する
#
# 置き場所は設定の adr.dir（既定: docs/adr。リポジトリのルートからの相対パス）。
# ファイル名は <adr.dir>/<Issue 番号を4桁に0埋め>-<短い名前>.md。1つの Issue から、名前を変えて2つ以上作れる。
# front matter の date は今日の日付、issue は --issue の値にする。status などは、作った後に書く。
# 同じファイル名があれば、上書きせずに終了コード 3 で止まる。置き換える ADR の status の行が読めなければ、
# 何も作らずに終了コード 4 で止まる。
#
# 出力: path（作った ADR）・template・issue・date・superseded（status を書き換えた ADR の一覧）・dry_run
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

issue="" name="" template="" dry_run=false
supersedes=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --issue | --name | --template | --supersedes)
      [ $# -ge 2 ] && [ -n "$2" ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --issue) issue="$2" ;;
        --name) name="$2" ;;
        --template) template="$2" ;;
        --supersedes) supersedes+=("$2") ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

[ -n "$issue" ] || dw_die "--issue は必須です" 64
case "$issue" in
  *[!0-9]*) dw_die "--issue には数字を指定してください: $issue" 64 ;;
esac
# 先頭の 0 を外して10進数にする（printf %04d は 08 を8進数として読んで落ちる）
issue=$((10#$issue))
[ "$issue" -le 9999 ] || dw_die "--issue は4桁までにしてください: $issue" 64
[ -n "$name" ] || dw_die "--name は必須です" 64
case "$template" in
  full) tpl="adr-template.md" ;;
  minimal) tpl="adr-template-minimal.md" ;;
  bare) tpl="adr-template-bare.md" ;;
  bare-minimal) tpl="adr-template-bare-minimal.md" ;;
  "") dw_die "--template は必須です（full / minimal / bare / bare-minimal）" 64 ;;
  *) dw_die "--template は full / minimal / bare / bare-minimal のどれかにしてください: $template" 64 ;;
esac

# 小文字にし、英数字以外（日本語を含む）を - にまとめ、前後の - を除いて 40 文字までにする
name="$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
  | LC_ALL=C sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-40 | sed 's/-$//')"
[ -n "$name" ] || dw_die "短い名前に英数字がありません。英語で指定してください" 64

repo_root="$(dw_repo_root || true)"
[ -n "$repo_root" ] || dw_die "git のリポジトリの中ではありません" 2
adr_dir="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" .adr.dir)" || dw_die "設定を読めません" 2
adr_dir="${adr_dir%/}"
case "$adr_dir" in
  "" | null | /* | .. | ../* | */.. | */../*) dw_die "adr.dir はリポジトリのルートからの相対パスにしてください（/ で始めない・.. を使わない）: ${adr_dir}" 2 ;;
esac

base="$(printf '%04d-%s' "$issue" "$name")"
rel="$adr_dir/$base.md"
path="$repo_root/$rel"
# 壊れたシンボリックリンクも、既にあるものとして扱う
{ [ -e "$path" ] || [ -L "$path" ]; } && dw_die "同じファイル名の ADR が既にあるので上書きしません: ${rel}（--name を変えてください）" 3

# 置き換える ADR を、作る前にすべて確かめる（途中で止まって中途半端に書き換えないため）
old_paths=()
for f in ${supersedes[@]+"${supersedes[@]}"}; do
  p=""
  for cand in "$repo_root/$adr_dir/$f" "$repo_root/$f"; do
    if [ -f "$cand" ]; then
      p="$cand"
      break
    fi
  done
  [ -n "$p" ] || dw_die "置き換える ADR が見つかりません: ${f}" 4
  [ "$p" != "$path" ] || dw_die "自分自身は置き換えられません: ${f}" 4
  # front matter の中の status の行を読めること
  awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { exit !found } /^status:/ { found = 1 }' "$p" \
    || dw_die "置き換える ADR の front matter に status の行がありません: ${f}" 4
  old_paths+=("$p")
done

date="$(date +%F)"
tpl_path="$DW_PLUGIN_ROOT/templates/adr/$tpl"
[ -f "$tpl_path" ] || dw_die "テンプレートがありません: ${tpl_path}" 1

superseded='[]'
for p in ${old_paths[@]+"${old_paths[@]}"}; do
  superseded="$(jq -c --arg p "${p#"$repo_root"/}" '. + [$p]' <<<"$superseded")"
done

if [ "$dry_run" = false ]; then
  mkdir -p "$repo_root/$adr_dir" 2>/dev/null || dw_die "ADR を置くディレクトリを作れません: ${adr_dir}" 1
  # front matter（先頭の --- から次の --- まで）の date と issue だけを置き換える。確かめた後に別の処理が作った
  # ファイルも上書きしないよう、noclobber で書く
  if ! (set -C; awk -v d="$date" -v i="$issue" '
      NR == 1 && $0 == "---" { fm = 1; print; next }
      fm && $0 == "---" { fm = 0 }
      fm && /^date:/ { print "date: " d; next }
      fm && /^issue:/ { print "issue: " i; next }
      { print }' "$tpl_path" >"$path") 2>/dev/null; then
    { [ -e "$path" ] || [ -L "$path" ]; } && dw_die "同じファイル名の ADR が既にあるので上書きしません: ${rel}" 3
    dw_die "ADR を書き込めません: ${rel}" 1
  fi
  tmp=""
  trap 'rm -f "$tmp"' EXIT
  for p in ${old_paths[@]+"${old_paths[@]}"}; do
    tmp="$(mktemp)"
    awk -v s="superseded by $base" '
      NR == 1 { fm = 1; print; next }
      fm && $0 == "---" { fm = 0 }
      fm && !done && /^status:/ { print "status: \"" s "\""; done = 1; next }
      { print }' "$p" >"$tmp"
    cat "$tmp" >"$p" || dw_die "置き換える ADR を書き換えられません: ${p#"$repo_root"/}（作った ADR ${rel} は残っています）" 1 # 元のファイルの権限を保つため、mv ではなく中身を書き戻す
    rm -f "$tmp"
  done
fi

jq -n --arg p "$rel" --arg t "$template" --argjson i "$issue" --arg d "$date" --argjson s "$superseded" --argjson dr "$dry_run" \
  '{path: $p, template: $t, issue: $i, date: $d, superseded: $s, dry_run: $dr}'
