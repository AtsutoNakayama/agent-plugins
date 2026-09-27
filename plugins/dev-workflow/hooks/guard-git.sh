#!/usr/bin/env bash
# Claude Code のフック（PreToolUse の Bash）。マージ先のブランチ（base_branch。既定は main）を守るため、
# 次の git の操作を止める。
#   - base_branch の上での git commit
#   - base_branch への git push（base_branch の上で push 先を書かずに push するときを含む）
#   - 強制 push（--force / -f / +<refspec> / --mirror）。--force-with-lease は許可する
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
        # --mirror はすべての ref をリモートに合わせて上書き・削除する
        --force | --mirror) force=true; continue ;;
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
  $force && deny "強制 push（--force / -f / +<refspec> / --mirror）はしません。必要なら --force-with-lease を使ってください"

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
  # 先頭の環境変数の代入（FOO=1 git push）、前に付くだけのコマンド、予約語（then git push）を飛ばす
  while [ $# -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=*) shift ;;
      command | exec | time | nohup | env) shift ;;
      if | then | elif | else | while | until | do | '{' | '!') shift ;;
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
# bash では ${cmd:i} などが文字列の長さに比例して遅いので、1文字ずつではなく、特別な文字の手前までをまとめて読む。
# また $cmd を展開するたびに全体が写されるので、先の wsize 文字を wbuf に写しておき、そこから win 文字ずつ見る。

len=${#cmd}
# bash 3.2 では "${...}" の中の $'\n' の扱いが新しい bash と違うので、変数にしておく
nl=$'\n' tab=$'\t'
# 特別な文字（ここで区切ってまとめて読む）。外側・"..." の中・$( ) の中。
# パターンとして使うので、${rest%%$top_stop*} のように引用符で囲まずに展開する（SC2295 は意図どおり）
top_stop='[\\ '"$tab$nl"';&|()<>#'"'"'"`$]'
dq_stop='[\\"$`]'
# shellcheck disable=SC1003
sub_stop='[\\'"'"'"`()<'"$nl"']'
win=512 wsize=4096 wbase=0 wbuf=""
i=0
word="" in_word=false skip_word=false
words=() nwords=0
hd_delims=() hd_strip=() hd_n=0
# ( ) の中の cd は外に効かないので、( の時点のディレクトリを積んでおき、) で戻す
dstack=() dn=0
# case の中の深さ（case の時点の dn を積む）
case_dn=() cn=0
arith_i=0
git_dir="" gopts=()

# 残りの文字列の先頭（最大 win 文字）を rest に入れる。wbuf を使い切りそうなら写し直す
window() {
  local off=$((i - wbase))
  if [ "$off" -lt 0 ] || { [ $((off + win)) -gt "${#wbuf}" ] && [ $((wbase + ${#wbuf})) -lt "$len" ]; }; then
    wbase=$i
    wbuf="${cmd:i:wsize}"
    off=0
  fi
  rest="${wbuf:off:win}"
}

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

# (( が算術式なら、閉じる )) の次の位置を arith_i に入れて 0 を返す。
# (( の後ろで最初に閉じる括弧の次が ) でなければ、((cmd) ...) のような入れ子のサブシェル
arith_end() {
  local seg k=2 depth=2 c
  # 算術式は短いので、先の wsize 文字の中だけを見る（見つからなければサブシェルとして調べる）
  seg="${cmd:i:wsize}"
  while [ "$k" -lt "${#seg}" ]; do
    c="${seg:k:1}"
    case "$c" in
      '(') depth=$((depth + 1)) ;;
      ')')
        depth=$((depth - 1))
        if [ "$depth" -eq 1 ]; then
          [ "${seg:k+1:1}" = ')' ] || return 1
          arith_i=$((i + k + 2))
          return 0
        fi
        ;;
    esac
    k=$((k + 1))
  done
  return 1
}

# case と esac を数える。case の時点の括弧の深さを積み、パターンの ) で括弧を閉じないようにする
track_case() {
  local w
  for w in "$@"; do
    case "$w" in
      if | then | elif | else | while | until | do | '{' | '!') ;;
      'case')
        case_dn[cn]=$dn
        cn=$((cn + 1))
        return 0
        ;;
      'esac')
        [ "$cn" -eq 0 ] || cn=$((cn - 1))
        return 0
        ;;
      *) return 0 ;;
    esac
  done
}

end_command() {
  flush_word
  skip_word=false
  [ "$nwords" -eq 0 ] || track_case "${words[@]}"
  [ "$nwords" -eq 0 ] || check_command "${words[@]}"
  words=() nwords=0
}

# i から <区切り> の手前までを cut に入れる（区切りが無ければ最後まで）。
# 窓の中で見つからないときだけ、残り全体から探す
# 使い方: cut_until <区切りの文字>
cut_until() {
  local rest
  window
  cut="${rest%%"$1"*}"
  if [ "$cut" = "$rest" ] && [ $((i + ${#rest})) -lt "$len" ]; then
    rest="${cmd:i}"
    cut="${rest%%"$1"*}"
  fi
}

# '...' の中身を加える
scan_squote() {
  local cut q
  i=$((i + 1))
  cut_until "'"
  q="$cut"
  i=$((i - 1))
  word+="$q" in_word=true
  i=$((i + ${#q} + 2))
}

# `...` をそのまま加える
scan_backtick() {
  local cut q
  i=$((i + 1))
  cut_until '`'
  q="$cut"
  i=$((i - 1))
  word+="\`$q\`" in_word=true
  i=$((i + ${#q} + 2))
}

# "..." の中身を加える
scan_dquote() {
  local rest chunk c n
  in_word=true
  i=$((i + 1))
  while [ "$i" -lt "$len" ]; do
    window
    # shellcheck disable=SC2295
    chunk="${rest%%$dq_stop*}"
    if [ -n "$chunk" ]; then
      word+="$chunk"
      i=$((i + ${#chunk}))
      continue
    fi
    c="${rest:0:1}"
    case "$c" in
      '"')
        i=$((i + 1))
        return 0
        ;;
      \\)
        n="${rest:1:1}"
        case "$n" in
          '$' | '`' | '"' | \\) word+="$n" ;;
          "$nl") ;;
          *) word+="$c$n" ;;
        esac
        i=$((i + 2))
        ;;
      '$')
        if [ "${rest:1:1}" = '(' ]; then
          scan_subst
        else
          word+="$c"
          i=$((i + 1))
        fi
        ;;
      '`') scan_backtick ;;
    esac
  done
}

# $( ... ) と $(( ... )) をそのまま加える（中のコマンドは調べない）
scan_subst() {
  local rest chunk c depth=1 arith=false
  window
  # $(( ... )) の << はシフト演算で、ヒアドキュメントではない
  # shellcheck disable=SC2016
  [ "${rest:0:3}" != '$((' ] || arith=true
  # shellcheck disable=SC2016
  word+='$(' in_word=true
  i=$((i + 2))
  while [ "$i" -lt "$len" ]; do
    window
    # shellcheck disable=SC2295
    chunk="${rest%%$sub_stop*}"
    if [ -n "$chunk" ]; then
      word+="$chunk"
      i=$((i + ${#chunk}))
      continue
    fi
    c="${rest:0:1}"
    case "$c" in
      "'") scan_squote ;;
      '"') scan_dquote ;;
      '`') scan_backtick ;;
      \\)
        word+="${rest:0:2}"
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
        if ! $arith && [ "${rest:0:2}" = '<<' ] && [ "${rest:0:3}" != '<<<' ]; then
          i=$((i + 2))
          read_heredoc_delim
        else
          word+="$c"
          i=$((i + 1))
        fi
        ;;
      "$nl")
        word+=' '
        if [ "$hd_n" -gt 0 ]; then skip_heredocs; else i=$((i + 1)); fi
        ;;
    esac
  done
}

# << の後ろの区切りの語を読み、次の改行で本文を飛ばせるように覚える（i は << の直後）
read_heredoc_delim() {
  local rest c strip=0 d=""
  window
  if [ "${rest:0:1}" = - ]; then
    strip=1
    i=$((i + 1))
  fi
  while [ "$i" -lt "$len" ]; do
    window
    case "${rest:0:1}" in
      ' ' | "$tab") i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  while [ "$i" -lt "$len" ]; do
    window
    c="${rest:0:1}"
    case "$c" in
      ' ' | "$tab" | "$nl" | ';' | '&' | '|' | '(' | ')' | '<' | '>') break ;;
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
  local k=0 d rest body line cut
  i=$((i + 1))
  while [ "$k" -lt "$hd_n" ]; do
    d="${hd_delims[k]}"
    rest="${cmd:i}"
    if [ "${hd_strip[k]}" = 0 ]; then
      # 区切りの行を探して、その次の行へ一度に進む
      if [ "$rest" = "$d" ] || [ "${rest:0:${#d}+1}" = "$d$nl" ]; then
        i=$((i + ${#d} + 1))
      else
        body="${rest%%"$nl$d$nl"*}"
        if [ "$body" != "$rest" ]; then
          i=$((i + ${#body} + ${#d} + 2))
        else
          i=$len
        fi
      fi
    else
      # <<- は行頭のタブを除いて比べるので、1行ずつ見る
      while [ "$i" -lt "$len" ]; do
        cut_until "$nl"
        line="$cut"
        i=$((i + ${#line} + 1))
        line="${line#"${line%%[!"$tab"]*}"}"
        [ "$line" != "$d" ] || break
      done
    fi
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
  local rest
  window
  if [ "${rest:0:3}" = '<<<' ]; then
    i=$((i + 3))
    skip_word=true
  elif [ "${rest:0:2}" = '<<' ]; then
    i=$((i + 2))
    read_heredoc_delim
  else
    i=$((i + 1))
    case "${rest:1:1}" in
      '>' | '&' | '|') i=$((i + 1)) ;;
    esac
    skip_word=true
  fi
}

while [ "$i" -lt "$len" ]; do
  window
  # shellcheck disable=SC2295
  chunk="${rest%%$top_stop*}"
  if [ -n "$chunk" ]; then
    word+="$chunk" in_word=true
    i=$((i + ${#chunk}))
    continue
  fi
  c="${rest:0:1}"
  case "$c" in
    ' ' | "$tab")
      flush_word
      i=$((i + 1))
      ;;
    "$nl")
      end_command
      if [ "$hd_n" -gt 0 ]; then skip_heredocs; else i=$((i + 1)); fi
      ;;
    ';' | '&' | '|')
      end_command
      i=$((i + 1))
      ;;
    '(')
      end_command
      if [ "${rest:1:1}" = '(' ] && arith_end; then
        # (( ... )) は算術式なので、コマンドとして調べない（中の << もシフト演算）
        i=$arith_i
      else
        dstack[dn]="$dir"
        dn=$((dn + 1))
        i=$((i + 1))
      fi
      ;;
    ')')
      end_command
      # case のパターンの ) （a) など）は括弧を閉じない
      if [ "$cn" -gt 0 ] && [ "$dn" -eq "${case_dn[cn - 1]}" ]; then
        :
      elif [ "$dn" -gt 0 ]; then
        dn=$((dn - 1))
        dir="${dstack[dn]}"
      fi
      i=$((i + 1))
      ;;
    '<' | '>') scan_redirect ;;
    '#')
      if $in_word; then
        word+="$c"
        i=$((i + 1))
      else
        # コメントは改行の手前まで飛ばす
        cut_until "$nl"
        i=$((i + ${#cut}))
      fi
      ;;
    "'") scan_squote ;;
    '"') scan_dquote ;;
    '`') scan_backtick ;;
    \\)
      if [ "${rest:1:1}" != "$nl" ]; then
        word+="${rest:1:1}" in_word=true
      fi
      i=$((i + 2))
      ;;
    '$')
      if [ "${rest:1:1}" = '(' ]; then
        scan_subst
      else
        word+="$c" in_word=true
        i=$((i + 1))
      fi
      ;;
  esac
done
end_command
exit 0
