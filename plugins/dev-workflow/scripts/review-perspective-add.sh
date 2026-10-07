#!/usr/bin/env bash
# レビューの観点ファイルを1つ作り、JSON で出力する。本文（レビューの指示）は標準入力から読む。
#
# 使い方: review-perspective-add.sh --name <名前> --layer user|repo --title <title> [条件...] [--override] [--builtin code-review] <本文
#
#   --name      観点の名前（ファイル名から .md を除いたもの）。小文字の英数字と - だけ
#   --layer     置く層。user は ~/.claude/dev-workflow/review/、repo は <repo>/.claude/dev-workflow/review/
#   --title     一覧に出す1行の説明
#   --override  ほかの層にある同じ名前の観点を、作る観点で置き換えてよい
#   --builtin   本文の代わりに組み込みのコマンドを実行する観点にする（code-review だけで、--name も code-review。
#               同梱の観点 code-review を上位の層で置き換えるときに使う）。本文には、
#               そのコマンドの指摘のうち出さないものを「## 指摘しないこと」の節に書く（review スキルが照らして外す）
#
# 実行する条件（任意。書かなければ毎回実行する。複数書けば、すべてに当てはまるときだけ実行する）:
#   --type <type>          変更の type がこのどれかのとき（繰り返して複数書ける）。小文字の英数字と - だけ
#   --path <パターン>      差分のファイルがこのパターンに当たるとき（繰り返して複数書ける）。.gitignore と同じ書き方で、
#                          ! で始めると除外（書き方は review-perspectives.sh --help）。, と引用符は使えない
#   --issue-required       Issue があるときだけ
#   --base-ahead-required  マージ先が基点より進んでいる（ブランチを作った後にコミットが入った）ときだけ
#
# --title は全体を引用符で囲まない（読むときに外れる）。
#
# 同じ層に同じ名前のファイルがあれば、上書きせずに終了コード 3 で止まる。
# ほかの層に同じ名前のファイルがあれば、--override が無いかぎり何も作らずに止まる。
#   終了コード 5  上位の層にある（作っても、このリポジトリでは上位の層の観点が使われる）
#   終了コード 4  下位の層にだけある（作った観点で置き換わる）
# 書き込めないときは終了コード 1 で止まる。
# 観点ファイルの形式は review-perspectives.sh --help を参照。
# 導入していないリポジトリ（dw_user_dir_for）では、ユーザーの層の観点は使われない（設計書 §1）。user の層に作るときは
# 警告し（リポジトリの外では警告しない）、repo の層に作るときは、このリポジトリで使われないユーザーの層の同じ名前の観点を数えない。
#
# 出力:
#   name・layer・path  作った観点
#   overrides          作った観点で置き換えた下位の層のファイル
#   shadowed_by        作った観点より優先される上位の層のファイル（あればこの観点は使われない）
#   branch             repo の層に作ったときの、そのリポジトリ（ワークツリー）のブランチ。detached HEAD や
#                      user の層なら null
#   work_branch        repo の層に作ったとき、作業用のブランチ（base_branch 以外のブランチ）の上なら true。
#                      false なら、そのままではタスクの PR に含められない。user の層や、設定を読めないか
#                      base_branch が使えない値で、base_branch が分からないとき（警告を出す）は null
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

name=""
layer=""
title=""
builtin=""
override=false
types=""
paths=""
issue_required=false
base_ahead_required=false
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --name | --layer | --title | --builtin)
      [ $# -ge 2 ] || dw_die "$1 に値がありません" 64
      case "$1" in
        --name) name="$2" ;;
        --layer) layer="$2" ;;
        --title) title="$2" ;;
        --builtin) builtin="$2" ;;
      esac
      shift 2
      ;;
    --override) override=true; shift ;;
    --type | --path)
      [ $# -ge 2 ] || dw_die "$1 に値がありません" 64
      case "$2" in
        *"
"*) dw_die "$1 は1行にしてください" 64 ;;
      esac
      if [ "$1" = --type ]; then
        printf '%s' "$2" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
          || dw_die "--type は小文字の英数字と - だけにしてください: ${2}" 64
        types="${types:+$types, }$2"
      else
        # review-perspectives.sh は , で区切り、前後の空白と引用符を外して読むので、書いたとおりに読めないものは弾く
        case "$2" in
          "" | *,* | *\"* | *\'* | [[:space:]]* | *[[:space:]]) dw_die "--path は , と引用符を含まず、前後に空白の無いパターンにしてください: ${2}" 64 ;;
        esac
        case "${2#!}" in
          "" | /* | .. | ../* | */.. | */../*) dw_die "--path はリポジトリのルートからの相対パスのパターンにしてください（/ で始めない・.. を使わない）: ${2}" 64 ;;
        esac
        paths="${paths:+$paths, }\"$2\""
      fi
      shift 2
      ;;
    --issue-required) issue_required=true; shift ;;
    --base-ahead-required) base_ahead_required=true; shift ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

# grep は行ごとに見るので、改行を含む名前は先に弾く
case "$name" in
  *"
"*) dw_die "観点の名前は小文字の英数字と - だけにしてください" 64 ;;
esac
printf '%s' "$name" | grep -Eq '^[a-z0-9][a-z0-9-]*$' \
  || dw_die "観点の名前は小文字の英数字と - だけにしてください: ${name}" 64
case "$title" in
  *"
"*) dw_die "title は1行にしてください" 64 ;;
esac
title="$(printf '%s' "$title" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[ -n "$title" ] || dw_die "--title がありません" 64
# review-perspectives.sh は値を囲む引用符を外して読むので、書いたとおりに読めない title は弾く
case "$title" in
  \"*\" | \'*\') dw_die "title の全体を引用符で囲まないでください（読むときに外れます）: ${title}" 64 ;;
esac

case "$builtin" in
  "" | code-review) ;;
  *) dw_die "--builtin は code-review にしてください: ${builtin}" 64 ;;
esac
# 別の名前で作ると /code-review が2回動き、review スキルが読む除外の決まり（code-review の観点の本文）にもならない
if [ -n "$builtin" ] && [ "$name" != "$builtin" ]; then
  dw_die "--builtin ${builtin} は --name ${builtin} のときだけ使えます（同梱の観点 ${builtin} を置き換える）: ${name}" 64
fi

repo_root="$(dw_repo_root || true)"
user_dir="$(dw_user_review_dir)"
repo_dir=""
[ -z "$repo_root" ] || repo_dir="$repo_root/.claude/dev-workflow/review"
# このリポジトリで使われるユーザーの層（導入していなければ空）
used_user_dir="$(dw_user_review_dir_for "$repo_root")"
case "$layer" in
  user)
    dir="$user_dir"
    # 同じ名前の観点は、作る層（ユーザーの層）を基準に探す
    used_user_dir="$user_dir"
    # リポジトリの外では、導入したかを問わないので警告しない
    [ -z "$repo_root" ] || [ -n "$(dw_user_dir_for "$repo_root")" ] \
      || dw_warn "このリポジトリにはプラグインを導入していない（.claude/dev-workflow/config.json が無い）ので、ここではユーザーの層の観点は使われません。導入したリポジトリでは使われます"
    ;;
  repo)
    [ -n "$repo_dir" ] || dw_die "git のリポジトリの中ではないので、repo の層には置けません" 2
    dir="$repo_dir"
    # 観点の追加はきっかけになったタスクの PR に含めるので、作業用のブランチの上かを知らせる（設計書 §7）
    # 設定を読めなくても、base_branch が使えない値でも観点は作る（作業用のブランチの上かは分からないものとして null にし、
    # config.sh か dw_base_branch が出した理由を添えて警告する）
    # 標準エラーは、成功したときの JSON に混ぜないよう、一時ファイルに受けて理由（最後の1行）にする
    errf="$(mktemp)"
    if config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" 2>"$errf")"; then
      base="$( (dw_base_branch "$config") 2>"$errf")" || base=""
    else
      base=""
    fi
    why="$(tail -n 1 "$errf")"
    rm -f "$errf"
    [ -n "$base" ] \
      || dw_warn "作業用のブランチの上かは分かりません（${why:+${why#error: }。}config.sh で確かめてください）"
    branch="$(git -C "$repo_root" symbolic-ref --short -q HEAD || true)"
    ;;
  *) dw_die "--layer は user か repo にしてください" 64 ;;
esac
path="$dir/$name.md"
branch_json=null work_branch=null
if [ "$layer" = repo ]; then
  work_branch=false
  if [ -n "$branch" ]; then
    branch_json="$(jq -n --arg b "$branch" '$b')"
    if [ -z "$base" ]; then
      work_branch=null
    elif [ "$branch" != "$base" ]; then
      work_branch=true
    fi
  fi
fi

body="$(cat)"
printf '%s' "$body" | grep -q '[^[:space:]]' || dw_die "本文（レビューの指示）が標準入力にありません" 64

# 壊れたシンボリックリンクも、既にあるものとして扱う
exists() { [ -e "$1" ] || [ -L "$1" ]; }

exists "$path" && dw_die "同じ名前の観点が既にあるので上書きしません: ${path}" 3

# 優先度の低い層から順に、同じ名前のファイルを探す
overrides='[]'
shadowed='[]'
below=true
for d in "$DW_PLUGIN_ROOT/review" "$used_user_dir" "$repo_dir"; do
  [ -n "$d" ] || continue
  if [ "$d" = "$dir" ]; then
    below=false
  elif exists "$d/$name.md"; then
    if [ "$below" = true ]; then
      overrides="$(jq -c --arg p "$d/$name.md" '. + [$p]' <<<"$overrides")"
    else
      shadowed="$(jq -c --arg p "$d/$name.md" '. + [$p]' <<<"$shadowed")"
    fi
  fi
done

# 作った観点が使われないことのほうが大事なので、上位の層を先に知らせる
if [ "$override" = false ]; then
  if [ "$shadowed" != '[]' ]; then
    # --override で作り直すと下位の層の観点も置き換わるので、それも一緒に知らせる
    also=""
    [ "$overrides" = '[]' ] || also="。下位の層の $(jq -r 'join("、")' <<<"$overrides") も置き換わります"
    dw_die "上位の層に同じ名前の観点があるので、このリポジトリでは作った観点が使われません（それでも作るなら --override${also}）: $(jq -r '.[0]' <<<"$shadowed")" 5
  fi
  if [ "$overrides" != '[]' ]; then
    dw_die "下位の層に同じ名前の観点があります（置き換えるなら --override）: $(jq -r '.[0]' <<<"$overrides")" 4
  fi
fi

mkdir -p "$dir" 2>/dev/null || dw_die "観点ファイルを置くディレクトリを作れません: ${dir}" 1
# frontmatter の builtin と条件の行（review-perspectives.sh --help の形式）
when=""
[ -z "$builtin" ] || when="builtin: ${builtin}
"
[ -z "$types" ] || when="${when}types: [${types}]
"
[ -z "$paths" ] || when="${when}paths: [${paths}]
"
[ "$issue_required" = false ] || when="${when}issue: required
"
[ "$base_ahead_required" = false ] || when="${when}base_ahead: required
"
# 確かめた後に別の処理が作ったファイルも上書きしないよう、noclobber で書く
if ! (set -C; printf -- '---\ntitle: %s\n%s---\n\n%s\n' "$title" "$when" "$body" >"$path") 2>/dev/null; then
  exists "$path" && dw_die "同じ名前の観点が既にあるので上書きしません: ${path}" 3
  dw_die "観点ファイルを書き込めません: ${path}" 1
fi

jq -n --arg n "$name" --arg l "$layer" --arg p "$path" --argjson o "$overrides" --argjson s "$shadowed" \
  --argjson b "$branch_json" --argjson w "$work_branch" \
  '{name: $n, layer: $l, path: $p, overrides: $o, shadowed_by: $s, branch: $b, work_branch: $w}'
