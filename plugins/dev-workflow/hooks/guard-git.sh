#!/usr/bin/env bash
# Claude Code のフック（PreToolUse の Bash）。マージ先のブランチ（base_branch。既定は main）を守るため、
# 次の git の操作を止める。
#   - base_branch の上での git commit
#   - base_branch への git push（base_branch の上で push 先を書かずに push するときを含む）
#   - 強制 push（--force / -f / +<refspec>）。--force-with-lease は許可する
#
# 標準入力でフックの入力（JSON）を受け取る。止めるときは理由を標準エラーに1行で出し、終了コード 2 で終わる
# （Claude Code はコマンドを実行せず、理由を Claude に伝える）。
# コマンドの文字列を簡易に解析するだけなので、sh -c や git の別名（alias）を通すと見逃す。
# 最後の守りは GitHub のルールセット（setup-repo.sh）。
set -euo pipefail

# 日本語をバイト列として扱い、1文字ずつの読み取りを速く・確実にする
export LC_ALL=C

# shellcheck source=../scripts/lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../scripts/lib/common.sh"
dw_require jq

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
# git を含まないコマンドは解析しない（Bash を使うたびに呼ばれるので速く抜ける）
case "$cmd" in
  *git*) ;;
  *) exit 0 ;;
esac
cwd="$(jq -r '.cwd // empty' <<<"$input")"
dir="$(cd "${cwd:-.}" 2>/dev/null && pwd -P || true)"

# --- 判断 -------------------------------------------------------------------------

deny() { dw_die "$1" 2; }

# 基準のディレクトリからの相対パスを絶対パスにする。分からなければ空を出力する。
# 使い方: resolve_dir <基準のディレクトリ（空なら不明）> <パス>
resolve_dir() {
  local base="$1" p="$2"
  # ~ はシェルが展開する前の文字として比べる
  # shellcheck disable=SC2088
  case "$p" in
    '~') p="$HOME" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
    /*) ;;
    *)
      [ -n "$base" ] || return 0
      p="$base/$p"
      ;;
  esac
  (cd "$p" 2>/dev/null && pwd -P) || true
}

# git の操作の対象（ディレクトリと git のグローバルオプション）で git を実行する。
# 使い方: git_at <コマンド>...   （git_dir と gopts を参照する）
git_at() {
  [ -n "$git_dir" ] || return 1
  (cd "$git_dir" && git ${gopts[@]+"${gopts[@]}"} "$@" 2>/dev/null)
}

# 対象のリポジトリの設定から base_branch を出力する。読めなければ main
base_branch() {
  local root base
  root="$(git_at rev-parse --show-toplevel || true)"
  base="$( (cd "${git_dir:-/}" && WORKFLOW_REPO_ROOT="$root" "$BASH" "$DW_SCRIPTS_DIR/config.sh" '.base_branch // empty') 2>/dev/null || true)"
  printf '%s\n' "${base:-main}"
}

# git push の引数を調べる。使い方: check_push <引数>...
check_push() {
  local force=false remote="" nref=0 after_dd=false expect=false w k c dest current base
  local refs=()
  for w in "$@"; do
    if $expect; then
      expect=false
      continue
    fi
    if ! $after_dd; then
      case "$w" in
        --) after_dd=true; continue ;;
        --force) force=true; continue ;;
        --repo | --push-option | --receive-pack | --exec) expect=true; continue ;;
        --*) continue ;;
        -?*)
          # 短いオプションはまとめて書ける（-fu）。-o は値を取るので、その後ろは値
          k=1
          while [ "$k" -lt "${#w}" ]; do
            c="${w:k:1}"
            case "$c" in
              f) force=true ;;
              o)
                [ "$((k + 1))" -lt "${#w}" ] || expect=true
                break
                ;;
            esac
            k=$((k + 1))
          done
          continue
          ;;
      esac
    fi
    if [ -z "$remote" ]; then
      remote="$w"
    else
      refs+=("$w")
      nref=$((nref + 1))
    fi
  done

  for w in ${refs[@]+"${refs[@]}"}; do
    case "$w" in +*) force=true ;; esac
  done
  $force && deny "強制 push（--force / -f / +<refspec>）はしません。必要なら --force-with-lease を使ってください"

  current="$(git_at symbolic-ref --short -q HEAD || true)"
  base="$(base_branch)"
  if [ "$nref" -eq 0 ]; then
    [ "$current" != "$base" ] \
      || deny "${base} へは push しません。作業用のブランチ（task-start）で PR を作ってください"
    return 0
  fi
  for w in "${refs[@]}"; do
    w="${w#+}"
    case "$w" in
      *:*) dest="${w##*:}" ;;
      *) dest="$w" ;;
    esac
    case "$dest" in
      HEAD | @) dest="$current" ;;
    esac
    dest="${dest#refs/heads/}"
    [ -z "$dest" ] || [ "$dest" != "$base" ] \
      || deny "${base} へは push しません。作業用のブランチ（task-start）で PR を作ってください"
  done
}

# 1つのコマンド（単語の並び）を調べる。cd ならディレクトリを移す。
# 使い方: check_command <単語>...
check_command() {
  local target sub base
  # 先頭の環境変数の代入（FOO=1 git push）と、前に付くだけのコマンドを飛ばす
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      command | exec | time | nohup | env) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0

  case "$1" in
    cd | pushd)
      shift
      target=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -) target=-; break ;;
          -*) shift ;;
          *) target="$1"; break ;;
        esac
      done
      case "$target" in
        '') dir="$(resolve_dir "" "$HOME")" ;;
        -) dir="" ;;
        *) dir="$(resolve_dir "$dir" "$target")" ;;
      esac
      return 0
      ;;
    git | */git) shift ;;
    *) return 0 ;;
  esac

  git_dir="$dir"
  gopts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -C)
        [ $# -ge 2 ] || return 0
        git_dir="$(resolve_dir "$git_dir" "$2")"
        shift 2
        ;;
      --git-dir | --work-tree)
        [ $# -ge 2 ] || return 0
        gopts+=("$1" "$2")
        shift 2
        ;;
      -c | --namespace | --config-env)
        [ $# -ge 2 ] || return 0
        shift 2
        ;;
      --git-dir=* | --work-tree=*) gopts+=("$1"); shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  sub="$1"
  shift

  case "$sub" in
    commit)
      base="$(base_branch)"
      [ "$(git_at symbolic-ref --short -q HEAD || true)" != "$base" ] \
        || deny "${base} の上ではコミットしません。作業用のブランチを作ってください（task-start）"
      ;;
    push) check_push "$@" ;;
  esac
}

# --- コマンドの文字列を単語に分ける ------------------------------------------------
# 引用符・エスケープ・$( )・ヒアドキュメント・リダイレクトを考え、; & | 改行 ( ) でコマンドを区切る。

len=${#cmd}
# bash 3.2 では "${...}" の中の $'\n' の扱いが新しい bash と違うので、変数にしておく
nl=$'\n' tab=$'\t'
i=0
word="" in_word=false skip_word=false
words=() nwords=0
hd_delims=() hd_strip=() hd_n=0
git_dir="" gopts=()

flush_word() {
  if $in_word; then
    if $skip_word; then
      skip_word=false
    else
      words+=("$word")
      nwords=$((nwords + 1))
    fi
  fi
  word="" in_word=false
}

end_command() {
  flush_word
  skip_word=false
  [ "$nwords" -eq 0 ] || check_command "${words[@]}"
  words=() nwords=0
}

# '...' の中身を加える
scan_squote() {
  local rest q
  rest="${cmd:i+1}"
  q="${rest%%\'*}"
  word+="$q" in_word=true
  i=$((i + ${#q} + 2))
}

# `...` をそのまま加える
scan_backtick() {
  local rest q
  rest="${cmd:i+1}"
  q="${rest%%\`*}"
  word+="\`$q\`" in_word=true
  i=$((i + ${#q} + 2))
}

# "..." の中身を加える
scan_dquote() {
  local c n
  in_word=true
  i=$((i + 1))
  while [ "$i" -lt "$len" ]; do
    c="${cmd:i:1}"
    case "$c" in
      '"')
        i=$((i + 1))
        return 0
        ;;
      \\)
        n="${cmd:i+1:1}"
        case "$n" in
          '$' | '`' | '"' | \\) word+="$n" ;;
          $'\n') ;;
          *) word+="$c$n" ;;
        esac
        i=$((i + 2))
        ;;
      '$')
        if [ "${cmd:i+1:1}" = '(' ]; then
          scan_subst
        else
          word+="$c"
          i=$((i + 1))
        fi
        ;;
      '`') scan_backtick ;;
      *)
        word+="$c"
        i=$((i + 1))
        ;;
    esac
  done
}

# $( ... ) をそのまま加える（中のコマンドは調べない）
scan_subst() {
  local c depth=1
  # shellcheck disable=SC2016
  word+='$(' in_word=true
  i=$((i + 2))
  while [ "$i" -lt "$len" ]; do
    c="${cmd:i:1}"
    case "$c" in
      "'") scan_squote ;;
      '"') scan_dquote ;;
      '`') scan_backtick ;;
      \\)
        word+="${cmd:i:2}"
        i=$((i + 2))
        ;;
      '(')
        depth=$((depth + 1))
        word+="$c"
        i=$((i + 1))
        ;;
      ')')
        word+="$c"
        i=$((i + 1))
        depth=$((depth - 1))
        [ "$depth" -gt 0 ] || return 0
        ;;
      '<')
        if [ "${cmd:i:2}" = '<<' ] && [ "${cmd:i:3}" != '<<<' ]; then
          i=$((i + 2))
          read_heredoc_delim
        else
          word+="$c"
          i=$((i + 1))
        fi
        ;;
      $'\n')
        word+=' '
        if [ "$hd_n" -gt 0 ]; then skip_heredocs; else i=$((i + 1)); fi
        ;;
      *)
        word+="$c"
        i=$((i + 1))
        ;;
    esac
  done
}

# << の後ろの区切りの語を読み、次の改行で本文を飛ばせるように覚える（i は << の直後）
read_heredoc_delim() {
  local c strip=0 d=""
  if [ "${cmd:i:1}" = - ]; then
    strip=1
    i=$((i + 1))
  fi
  while [ "$i" -lt "$len" ]; do
    case "${cmd:i:1}" in
      ' ' | $'\t') i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  while [ "$i" -lt "$len" ]; do
    c="${cmd:i:1}"
    case "$c" in
      ' ' | $'\t' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>') break ;;
      "'" | '"' | \\) ;;
      *) d+="$c" ;;
    esac
    i=$((i + 1))
  done
  hd_delims+=("$d")
  hd_strip+=("$strip")
  hd_n=$((hd_n + 1))
}

# ヒアドキュメントの本文を飛ばす（i は本文の前の改行）
skip_heredocs() {
  local k=0 rest line
  i=$((i + 1))
  while [ "$k" -lt "$hd_n" ]; do
    while [ "$i" -lt "$len" ]; do
      rest="${cmd:i}"
      line="${rest%%"$nl"*}"
      i=$((i + ${#line} + 1))
      [ "${hd_strip[k]}" = 0 ] || line="${line#"${line%%[!"$tab"]*}"}"
      [ "$line" != "${hd_delims[k]}" ] || break
    done
    k=$((k + 1))
  done
  hd_delims=() hd_strip=() hd_n=0
}

# < や > のリダイレクト。対象の語（2>&1 の 1 やファイル名）はコマンドの引数に入れない
scan_redirect() {
  # 2>&1 の 2 のような、数字だけの語は fd の番号
  case "$word" in
    '' | *[!0-9]*) flush_word ;;
    *) word="" in_word=false ;;
  esac
  if [ "${cmd:i:3}" = '<<<' ]; then
    i=$((i + 3))
    skip_word=true
  elif [ "${cmd:i:2}" = '<<' ]; then
    i=$((i + 2))
    read_heredoc_delim
  else
    i=$((i + 1))
    case "${cmd:i:1}" in
      '>' | '&' | '|') i=$((i + 1)) ;;
    esac
    skip_word=true
  fi
}

while [ "$i" -lt "$len" ]; do
  c="${cmd:i:1}"
  case "$c" in
    ' ' | $'\t')
      flush_word
      i=$((i + 1))
      ;;
    $'\n')
      end_command
      if [ "$hd_n" -gt 0 ]; then skip_heredocs; else i=$((i + 1)); fi
      ;;
    ';' | '&' | '|' | '(' | ')')
      end_command
      i=$((i + 1))
      ;;
    '<' | '>') scan_redirect ;;
    '#')
      if $in_word; then
        word+="$c"
        i=$((i + 1))
      else
        # コメントは改行の手前まで飛ばす
        rest="${cmd:i}"
        line="${rest%%"$nl"*}"
        i=$((i + ${#line}))
      fi
      ;;
    "'") scan_squote ;;
    '"') scan_dquote ;;
    '`') scan_backtick ;;
    \\)
      if [ "${cmd:i+1:1}" != $'\n' ]; then
        word+="${cmd:i+1:1}" in_word=true
      fi
      i=$((i + 2))
      ;;
    '$')
      if [ "${cmd:i+1:1}" = '(' ]; then
        scan_subst
      else
        word+="$c" in_word=true
        i=$((i + 1))
      fi
      ;;
    *)
      word+="$c" in_word=true
      i=$((i + 1))
      ;;
  esac
done
end_command
exit 0
