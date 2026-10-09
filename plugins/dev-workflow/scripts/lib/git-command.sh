# shellcheck shell=bash
# コマンドの文字列（Claude Code の Bash の tool_input.command）を解析し、git の呼び出しごとに、
# どのサブコマンドを、どのディレクトリ・どのリポジトリに対して実行するかを渡す。フック（guard-git.sh・pr-link.sh）が共有する。
# common.sh の後に source する。
#
# 引用符・エスケープ・$( )・ヒアドキュメント・リダイレクトを考え、; & | 改行 ( ) でコマンドを区切る。
# cd で移った先、pushd・popd で積んだ・戻った場所（シェルと同じく、dirs のスタックを追う）、git -C・env -C で指した先を追う
# （( ) の中で移った・積んだ分は外に効かない）。case の枝はすべて順に動いたものとして、関数の定義の本体はその場で
# 動いたものとして読む。cd - の後は、移った先を不明とする。前に付くコマンド（builtin・command・exec・time・nohup・
# env・timeout・nice・sudo・stdbuf・setsid・ionice・chrt・taskset・flock）は、そのオプションと位置引数（timeout の時間、
# chrt の優先度、taskset のマスク、flock のファイル）とともに飛ばす（env -S の値は env と同じく語に分ける。env -C・sudo -D は
# git -C と同じに扱う）。$( ) の中のコマンドは調べない。
# sh -c・xargs などや git の別名（alias）を通すと見逃す。パイプラインの各コマンドと、& でバックグラウンドで動かす並びも、
# ( ) と同じくサブシェルとして扱う（gc_restore の前のコメント）。読み方は bash の振る舞い（版で違うところは 4.3 以降）に合わせる
# （zsh などでは、パイプラインの最後のコマンドが今のシェルで動くなど、移った先を誤ることがある）。
#
# 使い方:
#   gc_scan <コールバック> <コマンドの文字列> <始めのディレクトリ（空なら不明）> [after [<戻す先>]]
#   git の呼び出しごとに「<コールバック> <サブコマンド> <残りの引数>...」を呼ぶ。呼ぶ前に、次の変数を設定する。
#     gc_git_dir  git を実行するディレクトリ（cd・pushd・popd で移った先、git -C・env -C・sudo -D で指した先。分からなければ空）
#     gc_gopts    git のグローバルオプションのうち、対象を変えるもの（--git-dir・--work-tree）。配列
#     gc_genv     先頭の代入のうち、対象を変えるもの（GIT_DIR・GIT_WORK_TREE・GIT_COMMON_DIR）。配列
#   コールバックの中では、gc_git でその対象に対して git を実行できる。
#   コールバックの中で使う変数は local で宣言する（gc_scan の作業用の変数を書き換えないため）。
#
#   after を付けると、始めのディレクトリを、コマンドを実行した「後」のディレクトリとして扱う（PostToolUse のフックの cwd）。
#   Claude Code は、外側（( ) の外）の cd で移った先を次のコマンドに引き継ぐので、cwd は既に移った先にある。
#   そのため、外側の相対パスへの cd はたどらない。絶対パス（~・$HOME を含む）への cd は、始めのディレクトリに関係なく
#   移った先が分かり、プロジェクトの外へ移って Claude Code が cwd を戻したときにも正しいので、たどる。その後の相対パスへの cd もたどる。
#   cd sub && git push && cd .. や pushd sub && git push && popd のように、後ろでまた移ると、git push を移る前の場所で
#   判断してしまう。cd - の後は、移った先を不明とする。外側の場所をまだたどっていないときに積んだ場所へ popd で戻ると、
#   たどっていない状態（cwd）に戻る（pushd から popd までは、シェルの場所を変えないので）。ただし ( ) の中でそこへ戻ったときは、
#   外側は戻っていないので、移った先を不明とする。
#   <戻す先> には、Claude Code が cwd を戻す先（プロジェクトのルート。$CLAUDE_PROJECT_DIR）を渡す。外側の相対パスへの cd が
#   プロジェクトの外へ出ると、Claude Code は cwd をそこへ戻すので、cwd が <戻す先> のときは、移った先を不明とする
#   （プロジェクトの中で <戻す先> へ移ったのと見分けられないので、間違った場所より、不明とする）。

gc_git_dir="" gc_gopts=() gc_genv=() gc_repo="" gc_root=""

# コマンドの文字列の値の先頭にある ~・$HOME・${HOME} を、シェルと同じく展開する（シェルが展開する前の文字列を見ているため）。
# ~ をシェルが展開するのは、語の先頭（cd ~/x・--git-dir ~/x）と代入の値（GIT_DIR=~/x）だけで、--git-dir=~/x のような
# オプションの値には展開しないので、そのときは no-tilde を渡す。ほかの変数は展開しない（対象が分からなければ、呼び出し側が安全な側に倒す）
# 使い方: gc_expand_home <値> [no-tilde]
gc_expand_home() {
  local v="$1"
  # ~ と $HOME はシェルが展開する前の文字として比べる
  # shellcheck disable=SC2088,SC2016
  if [ "${2:-}" != no-tilde ]; then
    case "$v" in
      '~') v="$HOME" ;;
      '~/'*) v="$HOME/${v#\~/}" ;;
    esac
  fi
  # shellcheck disable=SC2016
  case "$v" in
    '$HOME' | '${HOME}') v="$HOME" ;;
    '$HOME/'*) v="$HOME/${v#\$HOME/}" ;;
    '${HOME}/'*) v="$HOME/${v#\$\{HOME\}/}" ;;
  esac
  printf '%s\n' "$v"
}

# 基準のディレクトリからの相対パスを絶対パスにする（先頭の ~・$HOME は gc_expand_home で展開する）。分からなければ空を出力する。
# まだ無いディレクトリ（同じコマンドの中で git init・git clone・mkdir で作るもの）は、あるところまでを実体にし、
# 残りを文字のまま（. と .. は、シェルの cd と同じく文字の上で）つないだパスにする（gc_lexical_dir）。
# そのパスでは git がリポジトリを見つけられないので、対象が分からないときと同じに扱われる（gc_new_repo で見分けるときを除く）
# 使い方: gc_resolve_dir <基準のディレクトリ（空なら不明）> <パス> [no-tilde]
gc_resolve_dir() {
  local p
  p="$(gc_expand_home "$2" "${3:-}")"
  case "$p" in
    /*) ;;
    *)
      [ -n "$1" ] || return 0
      p="$1/$p"
      ;;
  esac
  dw_abs_dir / "$p" || gc_lexical_dir "$p" || true
}

# 絶対パスの . と .. を文字の上で解き、あるディレクトリまでを実体にして、残り（まだ無いところ）をつないで出力する
# 使い方: gc_lexical_dir <絶対パス>
gc_lexical_dir() {
  local rest="${1#/}" out="" c head tail=""
  while [ -n "$rest" ]; do
    c="${rest%%/*}"
    if [ "$c" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$c" in
      '' | .) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$c" ;;
    esac
  done
  head="$out"
  while [ -n "$head" ] && [ ! -d "$head" ]; do
    tail="/${head##*/}$tail"
    head="${head%/*}"
  done
  head="$(dw_abs_dir / "${head:-/}")" || return 1
  printf '%s\n' "${head%/}$tail"
}

# git の操作の対象（ディレクトリと、git のグローバルオプション・対象を変える環境変数）で git を実行する。
# 使い方: gc_git <コマンド>...   （gc_git_dir と gc_gopts と gc_genv を参照する）
gc_git() {
  [ -n "$gc_git_dir" ] || return 1
  # まだ無いディレクトリ（gc_resolve_dir）では、cd が失敗する。そのエラーは出さない
  (CDPATH='' cd "$gc_git_dir" 2>/dev/null && env ${gc_genv[@]+"${gc_genv[@]}"} git ${gc_gopts[@]+"${gc_gopts[@]}"} "$@" 2>/dev/null)
}

# 操作の対象（gc_git_dir・gc_gopts・gc_genv）のリポジトリを求めて、gc_repo と gc_root に入れる。コールバックの中で呼ぶ。
# 導入したかの判定と、設定（base_branch・branch.pattern など）を読むリポジトリの、どちらにも使う。git は rev-parse を1回だけ起動する。
#   gc_repo  対象のリポジトリ（--git-common-dir の実体の絶対パス。ワークツリーなら元のリポジトリ）。git が見つけられなければ空
#   gc_root  対象の作業ツリーの一番上。確かめられなければ空
# オプションも環境変数も無ければ、--show-toplevel（git がそのコマンドで使う作業ツリー）がそのままルート。
# --git-dir・GIT_DIR などがあると、--show-toplevel は今のディレクトリを返すことがある（作業ツリーを指定しないとき）ので、
# その場所の git のディレクトリが対象のものと同じかで確かめる（dw_root_if_repo。同じリポジトリの別のワークツリーとも見分ける）。
# 違えば、対象がメインのリポジトリならメインのワークツリー（dw_repo_main_root）、ワークツリー（git worktree add）の git の
# ディレクトリなら、その gitdir ファイルが記録するワークツリー（dw_worktree_root）。.git の中など、--show-toplevel が答えないときも同じ
# shellcheck disable=SC2034 # gc_root は呼び出し側（フック）が読む
gc_target() {
  local gd c top
  gc_repo="" gc_root=""
  [ -n "$gc_git_dir" ] || return 0
  { IFS= read -r gd; IFS= read -r c; IFS= read -r top; } <<<"$(dw_parse_repo_paths "$gc_git_dir" \
    "$(gc_git rev-parse --git-dir --git-common-dir --show-toplevel || true)" || true)" || true
  [ -n "${c:-}" ] || return 0
  gc_repo="$c"
  if [ "${#gc_gopts[@]}" -eq 0 ] && [ "${#gc_genv[@]}" -eq 0 ] && [ -n "${top:-}" ]; then
    gc_root="$top"
    return 0
  fi
  if [ "$gd" = "$gc_repo" ]; then
    gc_root="$(dw_root_if_repo "${top:-}" "$gd" || dw_repo_main_root "$gc_repo" || true)"
  else
    gc_root="$(dw_root_if_repo "${top:-}" "$gd" || dw_worktree_root "$gd" || true)"
  fi
}

# 操作の対象の今のブランチを出力する（detached HEAD や分からないときは空）
gc_branch() { gc_git symbolic-ref --short -q HEAD || true; }

# --- オプションの読み方 -------------------------------------------------------------

# 1語のオプションを読む。git や getopt と同じく、短いオプションはまとめて書け（-qc name）、値をくっつけても書ける
# （-cname）。長いオプションは --name=value とも書け、略して書ける（--cre name）。略さない名前と同じものを先に、
# 無ければ頭が同じものを、<長いオプション> の並びの順に探す（曖昧な略し方では、コマンドが失敗して何もしないので、どれでもよい）。
# <長いオプション> には、値を取るものを末尾に = を付けて並べる。値を取らないものは、略した形を読みたいときと、
# 値を取るものの頭と同じ名前（switch の --force と --force-create）を見分けたいときに並べる。
# オプションなら 0、オプションでない語（- を含む）なら 1、-- なら 2 を返す（引数の並びは gc_args で読む）。
# 使い方: gc_opt <語> <値を取る短いオプションの文字> <長いオプション（空白区切り）>
#   gc_on    オプションの名前（-c・--create。略した長いオプションは略さない名前、知らない長いオプションは書いたまま）の配列
#   gc_ov    オプションの値（値を取らない、または次の語が値なら空）の配列
#   gc_oa    値をくっつけて書いたか（-C~/x・--chdir=~/x なら true）の配列
#   gc_onext 次の語が値になるオプションの名前（無ければ空）
gc_on=() gc_ov=() gc_oa=() gc_onext=""
gc_opt() {
  local w="$1" shorts="$2" longs="$3" k c l name long=""
  gc_on=() gc_ov=() gc_oa=() gc_onext=""
  case "$w" in
    -) return 1 ;;
    --) return 2 ;;
    --*)
      name="${w%%=*}"
      # 長いオプションの名前は空白も * なども含まないので、分けて並べる
      # shellcheck disable=SC2086
      for l in $longs; do
        if [ "${l%=}" = "$name" ]; then
          long="$l"
          break
        fi
      done
      if [ -z "$long" ]; then
        # shellcheck disable=SC2086
        for l in $longs; do
          case "${l%=}" in
            "$name"*)
              long="$l"
              break
              ;;
          esac
        done
      fi
      [ -n "$long" ] || long="$name"
      case "$long" in
        *=)
          case "$w" in
            *=*) gc_on+=("${long%=}") gc_ov+=("${w#*=}") gc_oa+=(true) ;;
            *) gc_onext="${long%=}" ;;
          esac
          ;;
        *) gc_on+=("$long") gc_ov+=("") gc_oa+=(false) ;;
      esac
      ;;
    -*)
      # 値を取る文字の後ろが残っていれば、それが値（-cname）。残っていなければ次の語が値
      k=1
      while [ "$k" -lt "${#w}" ]; do
        c="${w:k:1}"
        case "$shorts" in
          *"$c"*)
            if [ "$((k + 1))" -lt "${#w}" ]; then
              gc_on+=("-$c") gc_ov+=("${w:k+1}") gc_oa+=(true)
            else
              gc_onext="-$c"
            fi
            return 0
            ;;
        esac
        gc_on+=("-$c") gc_ov+=("") gc_oa+=(false)
        k=$((k + 1))
      done
      ;;
    *) return 1 ;;
  esac
}

# 引数の並びを、git や getopt と同じく読み（1語ずつの読み方は gc_opt）、語ごとに「<コールバック> <種類> …」を呼ぶ。
#   opt <名前> <値> <値の書き方>  オプション。値の書き方は、値を取らなければ none、くっつけて書けば（-cname・--create=name）
#                                 attached、次の語が値なら next、値を取るのに値が無いまま終われば missing（値は空）
#   arg <語>                      オプションでない語（- と、-- の後ろの語を含む）
#   dd                            --（この後ろの語は、すべて arg になる）
# コールバックは、読むのをやめるときに gc_stop=true とする。gc_argn に、読み終えた語の数（やめた語を含まない）を入れる。
# コールバックは普通の文として呼ぶので、その中でも set -e が効き、終了コードは見ない（0 以外ならフックが止まる）。
# コールバックは、呼び出し元の local の変数を読み書きできる（呼び出し元の中から呼ばれるため）。
# gc_stop は、入るときの値を覚えて、出るときに戻す（コールバックの中で gc_args を呼んでも、外側の読み取りを止めない）。
# 使い方: gc_args <コールバック> <値を取る短いオプションの文字> <長いオプション（gc_opt と同じ）> <引数>...
gc_argn=0 gc_stop=false
gc_args() {
  # コールバックが呼び出し元の変数（cb など）を読めるよう、作業用の変数は ga_ で始める
  # gc_opt の結果（gc_on など）と読んだ語の数は、コールバックの中の gc_args・gc_opt が書き換えるので、ga_ の変数に写して使う
  local ga_cb="$1" ga_shorts="$2" ga_longs="$3" ga_w ga_k ga_dd=false ga_next="" ga_rc ga_stop="$gc_stop" ga_n=0
  local ga_on=() ga_ov=() ga_oa=()
  shift 3
  gc_stop=false
  for ga_w in "$@"; do
    if [ -n "$ga_next" ]; then
      "$ga_cb" opt "$ga_next" "$ga_w" next
      ga_next=""
    elif $ga_dd; then
      "$ga_cb" arg "$ga_w"
    else
      ga_rc=0
      gc_opt "$ga_w" "$ga_shorts" "$ga_longs" || ga_rc=$?
      case "$ga_rc" in
        0)
          ga_on=(${gc_on[@]+"${gc_on[@]}"}) ga_ov=(${gc_ov[@]+"${gc_ov[@]}"}) ga_oa=(${gc_oa[@]+"${gc_oa[@]}"})
          ga_next="$gc_onext"
          ga_k=0
          while [ "$ga_k" -lt "${#ga_on[@]}" ] && ! $gc_stop; do
            if "${ga_oa[ga_k]}"; then
              "$ga_cb" opt "${ga_on[ga_k]}" "${ga_ov[ga_k]}" attached
            else
              "$ga_cb" opt "${ga_on[ga_k]}" "" none
            fi
            ga_k=$((ga_k + 1))
          done
          ;;
        1) "$ga_cb" arg "$ga_w" ;;
        2)
          "$ga_cb" dd
          ga_dd=true
          ;;
      esac
    fi
    if $gc_stop; then
      gc_stop="$ga_stop" gc_argn=$ga_n
      return 0
    fi
    ga_n=$((ga_n + 1))
  done
  [ -z "$ga_next" ] || "$ga_cb" opt "$ga_next" "" missing
  gc_stop="$ga_stop" gc_argn=$ga_n
}

# 前に付くコマンド（timeout・nice・env など）のオプションを読む（gc_args）。最初のオプションでない語で止まる
# （-- は数え、その次の語で止まる）。
# 使い方: gc_skip_opts <値を取る短いオプションの文字> <長いオプション（gc_opt と同じ）> <引数>...
#   gc_nopt  オプションの語の数（-- を含む）
#   gc_optn・gc_optv・gc_optk  オプションの名前・値・値の書き方（gc_args の none・attached・next・missing）
gc_nopt=0 gc_optn=() gc_optv=() gc_optk=()
gc_skip_opts() {
  gc_optn=() gc_optv=() gc_optk=()
  gc_args gc_skip_opts_on "$@"
  gc_nopt=$gc_argn
}
gc_skip_opts_on() {
  case "$1" in
    opt) gc_optn+=("$2") gc_optv+=("$3") gc_optk+=("$4") ;;
    arg) gc_stop=true ;;
  esac
}

# ブランチを作る git のコマンドから、作るブランチの名前を探し、名前ごとに「<コールバック> <名前>」を呼ぶ。
# 対象は git switch -c/-C/--create/--force-create/--orphan、git checkout -b/-B/--orphan、git worktree add -b/-B、git branch <名前>、
# と、commit-ish を書かない git worktree add <パス>（パスの最後の名前でブランチを作る。--orphan も同じ。--detach のときは作らない）。
# 手元に無いブランチへの git switch・checkout が作る追跡ブランチは、リモートを見ないと分からないので、gc_tracking_branches で拾う。
# オプションの読み方は gc_opt（-qc name・-cname・--cre name）。
# 使い方: gc_new_branches <コールバック> <サブコマンド> <引数>...
gc_new_branches() {
  local cb="$1" sub="$2"
  shift 2
  case "$sub" in
    switch) gc_create_opts "$cb" cC "--create= --force-create= --orphan= --force" "$@" ;;
    checkout) gc_create_opts "$cb" bB "--orphan=" "$@" ;;
    branch) gc_branch_create "$cb" "$@" ;;
    worktree)
      if [ "${1:-}" = add ]; then
        shift
        gc_worktree_add "$cb" "$@"
      fi
      ;;
  esac
}

# git worktree add の引数から、作るブランチの名前を探す。-b・-B があればその名前。無くて、--detach も無く、
# 位置引数が <パス> だけなら（--orphan も同じ）、git はパスの最後の名前でブランチを作る
# 使い方: gc_worktree_add <コールバック> <add の後の引数>...
gc_worktree_add() {
  local cb="$1" explicit=false detach=false npos=0 path="" name
  shift
  gc_args gc_worktree_add_on bB "--reason= --orphan --detach" "$@"
  if $explicit; then
    gc_create_opts "$cb" bB "" "$@"
  elif ! $detach && [ "$npos" -eq 1 ]; then
    path="${path%"${path##*[!/]}"}"
    name="${path##*/}"
    case "$name" in
      '' | . | ..) ;;
      *) "$cb" "$name" ;;
    esac
  fi
}
gc_worktree_add_on() {
  case "$1" in
    opt)
      case "$2" in
        -b | -B) explicit=true ;;
        --detach | -d) detach=true ;;
      esac
      ;;
    arg)
      npos=$((npos + 1))
      path="$2"
      ;;
  esac
}

# git switch・git checkout が、手元に無いブランチを、リモートの同じ名前のブランチから追跡ブランチとして作るときの、
# 作るブランチの名前の候補を、「<コールバック> <名前>」に渡す。ブランチがあるかは見ない（呼び出し側が、手元に無く、
# リモートにあるかを確かめる）。対象は、位置引数がブランチの名前の 1 つだけの git switch <名前>・git checkout <名前>と、
# -t・--track を付けた git switch -t <リモート>/<名前>・git checkout -t <リモート>/<名前>（名前はリモートの後ろ）。
# -c・-b などで作る・--detach・-p・-- を使うときは、gc_new_branches の扱いなので渡さない
# 使い方: gc_tracking_branches <コールバック> <サブコマンド> <引数>...
gc_tracking_branches() {
  local cb="$1" sub="$2" shorts track=false skip=false npos=0 first=""
  shift 2
  case "$sub" in
    switch) shorts=cC ;;
    checkout) shorts=bB ;;
    *) return 0 ;;
  esac
  gc_args gc_tracking_on "$shorts" "--create= --force-create= --orphan= --conflict= --pathspec-from-file= --detach --patch --track" "$@"
  if $skip || [ "$npos" -ne 1 ]; then
    return 0
  fi
  case "$first" in
    '' | -*) return 0 ;;
  esac
  if $track; then
    case "$first" in
      */*) first="${first#*/}" ;;
    esac
  fi
  "$cb" "$first"
}
gc_tracking_on() {
  case "$1" in
    opt)
      case "$2" in
        -t | --track) track=true ;;
        -c | -C | -b | -B | --create | --force-create | --orphan | -d | --detach | -p | --patch | --pathspec-from-file) skip=true ;;
      esac
      ;;
    arg)
      npos=$((npos + 1))
      [ "$npos" -gt 1 ] || first="$2"
      ;;
    dd) skip=true ;;
  esac
}

# git switch・git checkout・git worktree add の引数から、作るブランチの名前を探す。<値を取る…> には、ブランチを作る
# オプションだけを並べる（ほかのオプションは値を取らないものとして読む。値はオプションの形でなければ読み飛ばされる）。
# オプションは名前の後ろにも書けるので、-- までのすべての語を見る。
# 使い方: gc_create_opts <コールバック> <値を取る短いオプションの文字> <長いオプション（gc_opt と同じ）> <引数>...
gc_create_opts() {
  local cb="$1"
  shift
  gc_args gc_create_opts_on "$@"
}
gc_create_opts_on() {
  case "$1" in
    # 値が無いまま終わった（git switch -c）ときは、作るブランチの名前が無い
    opt)
      case "$4" in
        attached | next) "$cb" "$3" ;;
      esac
      ;;
    dd) gc_stop=true ;;
  esac
}

# git branch の引数を調べる。ブランチを作るとき（一覧・削除・名前の変更などのオプションが無く、名前がある）だけ名前を渡す。
# オプションは名前の後ろにも書けるので（git branch bar -d）、すべての引数を見てから判断する。
# 作るときに使えるオプション（略した形も。gc_opt）だけなら続ける
# 使い方: gc_branch_create <コールバック> <引数>...
gc_branch_create() {
  local cb="$1" name="" create=" --force --track --no-track --quiet --create-reflog --recurse-submodules --color --no-color "
  shift
  gc_args gc_branch_create_on "" "$create" "$@"
  [ -z "$name" ] || "$cb" "$name"
}
gc_branch_create_on() {
  case "$1" in
    opt)
      case "$create -f -t -q " in
        *" $2 "*) ;;
        *)
          name=""
          gc_stop=true
          ;;
      esac
      ;;
    arg)
      if [ "$2" = - ]; then
        name=""
        gc_stop=true
      elif [ -z "$name" ]; then
        name="$2"
      fi
      ;;
  esac
}

# git worktree add <パス> <ブランチ>（-b・-B を付けない形）の、2つ目の位置引数を「<コールバック> <名前>」に渡す。
# gc_new_branches と違い、作るブランチではなく、既にあるブランチを使う書き方。値を取るオプション（--reason・-b・-B）の
# 次の語は、位置引数に数えない。-- の後ろは、すべて位置引数
# 使い方: gc_worktree_branch <コールバック> <add の後の引数>...
gc_worktree_branch() {
  local cb="$1" pos=0
  shift
  gc_args gc_worktree_branch_on bB "--reason=" "$@"
}
gc_worktree_branch_on() {
  [ "$1" = arg ] || return 0
  pos=$((pos + 1))
  if [ "$pos" -eq 2 ]; then
    "$cb" "$2"
    gc_stop=true
  fi
}

# リモート追跡ブランチに <名前> があるか（リモート名の後ろが完全に一致するときだけ。team/foo のリモート追跡ブランチは foo に当たらない）。
# gc_git で対象のリポジトリを調べる
# 使い方: gc_remote_has <名前>
gc_remote_has() {
  # パイプにすると、grep が先に終わって書く側が SIGPIPE で落ち、pipefail の下で「無い」と誤るので、出力を変数に取り、here-string で渡す
  local refs
  refs="$(gc_git for-each-ref --format='%(refname:lstrip=3)' refs/remotes 2>/dev/null)" || return 1
  grep -Fxq -- "$1" <<<"$refs"
}

# 手元のブランチ <名前> が、今の git switch・checkout で作られたものか（reflog が「branch: Created from …」の 1 行だけ）。
# PostToolUse のフックは、コマンドの後に動くので、追跡ブランチは、もう手元にある。前からあるブランチ（reflog が複数行）は含まない
# 使い方: gc_just_created <名前>
gc_just_created() {
  local log
  log="$(gc_git reflog show --format=%gs "refs/heads/$1" 2>/dev/null)" || return 1
  case "$log" in
    "branch: Created from "*) [[ "$log" != *$'\n'* ]] || return 1 ;;
    *) return 1 ;;
  esac
}

# git push の引数を読んで、次の変数に入れる。guard-git.sh（強制 push・push 先）と pr-link.sh（dry-run）が使う。
#   gc_push_force   強制 push（--force・-f・--mirror・+<refspec>）なら true。--force-with-lease は含めない
#   gc_push_dry     dry-run（--dry-run・-n）なら true
#   gc_push_refs    refspec の配列（リモートの後ろの引数）
# オプションの読み方は gc_opt（-fu・--mirr・--dry・--recu check）。値を取るオプション（--repo・--push-option・--receive-pack・
# --exec・--recurse-submodules・-o）の値は飛ばす。-- の後ろは、オプションとみなさない
# 使い方: gc_push_args <引数>...
gc_push_force=false gc_push_dry=false gc_push_refs=()
# shellcheck disable=SC2034 # gc_push_force・gc_push_dry は呼び出し側（フック）が読む
gc_push_args() {
  local remote=""
  gc_push_force=false gc_push_dry=false gc_push_refs=()
  gc_args gc_push_args_on o "--repo= --push-option= --receive-pack= --exec= --recurse-submodules= --force --mirror --dry-run" "$@"
}
# shellcheck disable=SC2034 # gc_push_force・gc_push_dry は呼び出し側（フック）が読む
gc_push_args_on() {
  case "$1" in
    opt)
      case "$2" in
        # --mirror はすべての ref をリモートに合わせて上書き・削除する
        -f | --force | --mirror) gc_push_force=true ;;
        -n | --dry-run) gc_push_dry=true ;;
      esac
      ;;
    arg)
      if [ -z "$remote" ]; then
        remote="$2"
      else
        gc_push_refs+=("$2")
        case "$2" in +*) gc_push_force=true ;; esac
      fi
      ;;
  esac
}

# git commit の引数を読んで、dry-run（--dry-run。略した形も）なら gc_commit_dry を true にする。pr-link.sh が使う。
# 値を取るオプション（-m・-F・--author など）の値は飛ばす（git commit -m --dry-run の --dry-run はメッセージ）
# 使い方: gc_commit_args <引数>...
gc_commit_dry=false
# shellcheck disable=SC2034 # gc_commit_dry は呼び出し側（フック）が読む
gc_commit_args() {
  gc_commit_dry=false
  gc_args gc_commit_args_on mFcCt "--message= --file= --reuse-message= --reedit-message= --fixup= --squash= --author= --date= --template= --cleanup= --trailer= --pathspec-from-file= --dry-run" "$@"
}
# shellcheck disable=SC2034 # gc_commit_dry は呼び出し側（フック）が読む
gc_commit_args_on() {
  case "$1" in
    opt) [ "$2" != --dry-run ] || gc_commit_dry=true ;;
    dd) gc_stop=true ;;
  esac
}

# --- コマンドごとの解析 -------------------------------------------------------------

# cd で移る。after のときの外側の相対パスの扱いは、先頭のコメント。gc_scan の中から呼ぶ。
# 引数が無ければ $HOME へ移り、空の引数（cd ""）では移らない（シェルと同じ）。
# 使い方: gc_cd [<行き先（- なら前の場所）>]
gc_cd() {
  local target="${1:-}" to
  if [ $# -eq 0 ]; then
    target="$HOME"
  elif [ -z "$target" ]; then
    return 0
  fi
  case "$target" in
    -) to="" ;;
    *)
      # 実行した後のディレクトリから始めたときは、外側の相対パスへの cd は、絶対パスへ移るまでたどらない（先頭のコメント）
      if $after && ! $anchored && [ "$dn" -eq 0 ]; then
        case "$(gc_expand_home "$target")" in
          /*) ;;
          *)
            # cwd が戻す先なら、プロジェクトの外へ出て戻されたのかもしれないので、不明とする
            [ -z "$reset_dir" ] || [ "$gc_dir" != "$reset_dir" ] || gc_dir=""
            return 0
            ;;
        esac
      fi
      to="$(gc_resolve_dir "$gc_dir" "$target")"
      ;;
  esac
  [ "$dn" -gt 0 ] || anchored=true
  gc_dir="$to"
}

# --- ディレクトリのスタック（pushd・popd・dirs）--------------------------------------
# シェルと同じく、pushd で積んだ場所を追う。gc_scan の作業用の変数を使い、gc_scan の中から呼ぶ。
# スタック（dirs -v の 1 番から後ろ。0 番は今の場所 gc_dir）は、pstack に、上から順に1行ずつ（改行で終わる）、次の形で持つ。
#   d<ディレクトリ>  その場所（空なら不明）
#   p<ディレクトリ>  after で、外側の場所をまだたどっていない（anchored でない）ときの場所（cwd）。ここへ戻ると、たどっていない状態に戻る
#   r<パス>          pushd -n で積んだパス。シェルは、ここへ移るときの場所から解決するので、移るときに cd と同じにたどる
# 失敗する使い方（積んだ場所が無い popd・範囲の外の番号・不正なオプション・多すぎる引数）は、シェルと同じく、場所もスタックも変えない。

# 今の場所を、スタックの形にして entry に入れる
gc_cur_entry() {
  if $after && ! $anchored && [ "$dn" -eq 0 ]; then
    entry="p$gc_dir"
  else
    entry="d$gc_dir"
  fi
}

# スタックの形の場所へ移る。使い方: gc_goto <スタックの形>
gc_goto() {
  case "$1" in
    p*)
      if [ "$dn" -gt 0 ]; then
        # ( ) の中で戻っても、外側は戻っていないので、cwd（外側の実行した後の場所）は戻った先ではない
        gc_dir=""
      else
        gc_dir="${1#p}"
        anchored=false
      fi
      ;;
    r*) gc_cd "${1#r}" ;;
    *)
      gc_dir="${1#d}"
      [ "$dn" -gt 0 ] || anchored=true
      ;;
  esac
}

# 今の場所とスタックを、dirs -v の順に配列 dl に並べる（dl[0] が今の場所）
gc_dirs_list() {
  local s="$pstack"
  gc_cur_entry
  dl=("$entry")
  while [ -n "$s" ]; do
    dl+=("${s%%"$nl"*}")
    s="${s#*"$nl"}"
  done
}

# dl の <番号> から後ろを、スタックにする。使い方: gc_dirs_set <番号>
gc_dirs_set() {
  local k="$1"
  pstack=""
  while [ "$k" -lt "${#dl[@]}" ]; do
    pstack+="${dl[k]}$nl"
    k=$((k + 1))
  done
}

# +N（左から）・-N（右から）を、dl の番号にして idx に入れる。範囲の外なら 1 を返す。使い方: gc_dirs_index <+N か -N>
# 語が、pushd・popd・dirs の番号（+N・-N）の形かを返す。N の頭には、符号を1つ付けられる（+-0・-+1。bash は N を
# 符号付きの数として読む）。使い方: gc_is_index <語>
gc_is_index() {
  local n="${1#[+-]}"
  [ "$n" != "$1" ] || return 1
  n="${n#[+-]}"
  case "$n" in '' | *[!0-9]*) return 1 ;; esac
}

gc_dirs_index() {
  local n="${1#[+-]}"
  gc_is_index "$1" || return 1
  # N に - を付けた負の数は、0 でなければ範囲の外
  case "$n" in
    -*) n="${n#-}"; [ -z "${n//0/}" ] || return 1 ;;
    +*) n="${n#+}" ;;
  esac
  # 先頭の 0 を 8 進数と読ませない（+08）。桁が多すぎる番号は範囲の外
  [ "${#n}" -le 9 ] || return 1
  n=$((10#$n))
  case "$1" in
    +*) idx=$n ;;
    *) idx=$((${#dl[@]} - 1 - n)) ;;
  esac
  [ "$idx" -ge 0 ] && [ "$idx" -lt "${#dl[@]}" ]
}

# pushd [-n] [+N | -N | <dir>]。-n は、今の場所を変えずにスタックだけを変える
gc_pushd() {
  local nocd=false rot=() k
  while [ $# -gt 0 ]; do
    ! gc_is_index "$1" || break
    case "$1" in
      -n) nocd=true; shift ;;
      --) shift; break ;;
      -) break ;;
      -*) return 0 ;;
      *) break ;;
    esac
  done
  [ $# -le 1 ] || return 0
  # 引数の無い pushd -n は、何もしない（シェルと同じ）
  [ $# -eq 1 ] || ! $nocd || return 0
  if [ $# -eq 1 ] && ! gc_is_index "$1"; then
    if $nocd; then
      # パスのまま積む（改行を含むパスは、1行に収まらないので不明とする）
      case "$1" in
        *"$nl"*) pstack="d$nl$pstack" ;;
        *) pstack="r$1$nl$pstack" ;;
      esac
    else
      # pushd "" は失敗する
      [ -n "$1" ] || return 0
      gc_cur_entry
      pstack="$entry$nl$pstack"
      gc_cd "$1"
    fi
    return 0
  fi
  gc_dirs_list
  if [ $# -eq 0 ]; then
    # 上の2つを入れ替える（積んだ場所が無ければ失敗する。$HOME へは移らない）
    [ "${#dl[@]}" -ge 2 ] || return 0
    entry="${dl[0]}"
    dl[0]="${dl[1]}"
    dl[1]="$entry"
  else
    # idx の場所が先頭に来るよう回す
    gc_dirs_index "$1" || return 0
    k=$idx
    while [ "$k" -lt "${#dl[@]}" ]; do
      rot+=("${dl[k]}")
      k=$((k + 1))
    done
    k=0
    while [ "$k" -lt "$idx" ]; do
      rot+=("${dl[k]}")
      k=$((k + 1))
    done
    dl=("${rot[@]}")
  fi
  # -n では、今の場所はそのままで、回した後の 1 番から後ろがスタックになる（シェルと同じ）
  gc_dirs_set 1
  $nocd || gc_goto "${dl[0]}"
}

# popd [-n] [+N | -N]。今の場所（0 番）を取り除くときだけ、次の場所へ移る（-n なら移らずに 1 番を取り除く）
gc_popd() {
  local nocd=false k idx=0
  while [ $# -gt 0 ]; do
    ! gc_is_index "$1" || break
    case "$1" in
      -n) nocd=true; shift ;;
      --) shift; break ;;
      *) return 0 ;;
    esac
  done
  [ $# -le 1 ] || return 0
  gc_dirs_list
  [ "${#dl[@]}" -ge 2 ] || return 0
  if [ $# -eq 1 ]; then
    gc_dirs_index "$1" || return 0
  fi
  if [ "$idx" -eq 0 ]; then
    entry="${dl[1]}"
    gc_dirs_set 2
    $nocd || gc_goto "$entry"
  else
    pstack=""
    k=1
    while [ "$k" -lt "${#dl[@]}" ]; do
      [ "$k" -eq "$idx" ] || pstack+="${dl[k]}$nl"
      k=$((k + 1))
    done
  fi
}

# dirs -c はスタックを空にする。bash の dirs は、オプションを1語ずつ（-c・-l・-p・-v）と +N・-N だけ受け付け、
# まとめ書き（-cl）・ほかのオプション・-- の後ろの語があると失敗して、スタックを変えない
gc_dirs() {
  local w clear=false
  for w in "$@"; do
    case "$w" in
      -c) clear=true ;;
      -l | -p | -v) ;;
      # +N・-N（gc_is_index。+1x は失敗する）
      *) gc_is_index "$w" || return 0 ;;
    esac
  done
  ! $clear || pstack=""
}

# env -S の値を、env と同じく語に分けて、配列 gc_split に入れる。空白で区切り、'…' の中は \\ と \' だけを解き、
# "…" の中と外では、\ の次の文字をそのまま読む（\_ は "…" の外では区切り、中では空白。\t はタブ、\n は改行）。
# ${VAR} などは展開しない
# 使い方: gc_split_s <文字列>
gc_split=()
gc_split_s() {
  local s="$1" i=0 c q="" w="" inw=false
  gc_split=()
  while [ "$i" -lt "${#s}" ]; do
    c="${s:i:1}"
    if [ "$q" = "'" ]; then
      case "$c${s:i+1:1}" in
        "\\\\" | "\\'")
          i=$((i + 1))
          w+="${s:i:1}"
          ;;
        "'"*) q="" ;;
        *) w+="$c" ;;
      esac
    elif [ "$c" = \\ ]; then
      i=$((i + 1))
      case "${s:i:1}" in
        _)
          # "…" の外の \_ は区切り、中では空白
          if [ -n "$q" ]; then
            w+=" "
          elif $inw; then
            gc_split+=("$w")
            w="" inw=false
          fi
          i=$((i + 1))
          continue
          ;;
        t) w+="$tab" ;;
        n) w+="$nl" ;;
        *) w+="${s:i:1}" ;;
      esac
      inw=true
    elif [ -n "$q" ]; then
      if [ "$c" = '"' ]; then q=""; else w+="$c"; fi
    else
      case "$c" in
        ' ' | "$tab" | "$nl")
          if $inw; then
            gc_split+=("$w")
            w="" inw=false
          fi
          ;;
        "'" | '"')
          q="$c"
          inw=true
          ;;
        *)
          w+="$c"
          inw=true
          ;;
      esac
    fi
    i=$((i + 1))
  done
  ! $inw || gc_split+=("$w")
}

# 操作の対象を変える環境変数（gc_genv）から、<名前> の変数を除く（env -u <名前>）
# 使い方: gc_unset_genv <名前>
gc_unset_genv() {
  local e kept=()
  for e in ${gc_genv[@]+"${gc_genv[@]}"}; do
    [ "${e%%=*}" = "$1" ] || kept+=("$e")
  done
  gc_genv=(${kept[@]+"${kept[@]}"})
}

# env -C・sudo -D の値（gc_skip_opts で読んだ <番号> のオプション）を、<基準のディレクトリ> から解決して、呼び出し元（gc_command）の
# cdir に入れる。値をくっつけて書いたとき（-C~/x・--chdir=~/x）は、シェルは ~ を展開しない
# 使い方: gc_set_cdir <基準のディレクトリ> <番号>
gc_set_cdir() {
  if [ "${gc_optk[$2]}" = attached ]; then
    cdir="$(gc_resolve_dir "$1" "${gc_optv[$2]}" no-tilde)"
  else
    cdir="$(gc_resolve_dir "$1" "${gc_optv[$2]}")"
  fi
  has_cdir=true
}

# 1つのコマンド（単語の並び）を調べる。cd・pushd・popd・dirs なら場所とスタックを変え、git ならコールバックを呼ぶ。
# gc_scan の中から呼ぶ。
# 使い方: gc_command <単語>...
gc_command() {
  local cdir="" has_cdir=false envbase ext=false k split=()
  # 先頭の環境変数の代入（FOO=1 git push）、前に付くコマンドとそのオプション、予約語（then git push）を飛ばす。
  # 操作の対象を変える代入（GIT_DIR など）は、対象のリポジトリを求めるときに使う。
  # 外部のコマンド（env・nohup・timeout・nice・exec）として実行する cd などは、シェルの場所を変えない（ext）。
  # builtin・command・time の後ろの cd などは、シェルの組み込みのコマンドとして実行する
  gc_genv=()
  while [ $# -gt 0 ]; do
    case "$1" in
      GIT_DIR=* | GIT_WORK_TREE=* | GIT_COMMON_DIR=*) gc_genv+=("${1%%=*}=$(gc_expand_home "${1#*=}")"); shift ;;
      [A-Za-z_]*=*) shift ;;
      if | then | elif | else | while | until | do | '{' | '!') shift ;;
      # function f { git …; } の本体の git も調べる
      function)
        shift
        [ $# -eq 0 ] || shift
        ;;
      time)
        # time -p（シェルの予約語なので、組み込みのコマンドもシェルの中で実行する）
        shift
        gc_skip_opts "" "" "$@"
        shift "$gc_nopt"
        ;;
      builtin)
        # builtin -- cd も、組み込みの cd を実行する。builtin はオプションを取らないので、-- 以外があれば失敗する
        shift
        gc_skip_opts "" "" "$@"
        shift "$gc_nopt"
        [ "${#gc_optn[@]}" -eq 0 ] || return 0
        ;;
      command)
        shift
        gc_skip_opts "" "" "$@"
        shift "$gc_nopt"
        # command -v・-V は、コマンドを実行せず、その在りかを出すだけ
        for k in ${gc_optn[@]+"${gc_optn[@]}"}; do
          case "$k" in -v | -V) return 0 ;; esac
        done
        ;;
      nohup)
        # nohup -- git push も、git を実行する。nohup は --help・--version しか取らず、そのときはコマンドを実行しない
        ext=true
        shift
        gc_skip_opts "" "" "$@"
        shift "$gc_nopt"
        [ "${#gc_optn[@]}" -eq 0 ] || return 0
        ;;
      exec)
        ext=true
        shift
        gc_skip_opts a "" "$@"
        shift "$gc_nopt"
        ;;
      timeout)
        # timeout [オプション] <時間> <コマンド>
        ext=true
        shift
        gc_skip_opts ks "--kill-after= --signal=" "$@"
        shift "$gc_nopt"
        [ $# -eq 0 ] || shift
        ;;
      nice)
        # nice -n 5・nice -5・nice --adjustment=5
        ext=true
        shift
        gc_skip_opts n --adjustment= "$@"
        shift "$gc_nopt"
        ;;
      sudo)
        # sudo [オプション] [代入] <コマンド>。-D <dir>（--chdir）は、env -C と同じく、このコマンドだけをその場所で実行する。
        # -h は、値をくっつけたときだけ値（ホスト）を取るので、値を取らないものとして読む（-hx の x などは、オプションとして飛ぶ）。
        # -e（sudoedit）・-l・-v・-K・-V は、コマンドを実行しない（-e の後ろはファイル）
        ext=true
        shift
        gc_skip_opts aCcDgpRrTtUu "--close-from= --login-class= --chdir= --group= --host= --prompt= --chroot= --role= --type= --command-timeout= --other-user= --user= --edit --list --validate --remove-timestamp --version" "$@"
        shift "$gc_nopt"
        if $has_cdir; then envbase="$cdir"; else envbase="$gc_dir"; fi
        k=0
        while [ "$k" -lt "${#gc_optn[@]}" ]; do
          case "${gc_optn[k]}" in
            -e | --edit | -l | --list | -v | --validate | -K | --remove-timestamp | -V | --version) return 0 ;;
            -D | --chdir) gc_set_cdir "$envbase" "$k" ;;
          esac
          k=$((k + 1))
        done
        ;;
      stdbuf)
        # stdbuf -i <モード>・-o <モード>・-e <モード>
        ext=true
        shift
        gc_skip_opts ioe "--input= --output= --error=" "$@"
        shift "$gc_nopt"
        ;;
      setsid)
        # setsid -c・-f・-w（値を取らない）
        ext=true
        shift
        gc_skip_opts "" "" "$@"
        shift "$gc_nopt"
        ;;
      ionice)
        # ionice -c <クラス>・-n <レベル>・-t。-p・-P・-u は、動いているプロセスを変えるだけで、コマンドを実行しない
        ext=true
        shift
        gc_skip_opts cnpPu "--class= --classdata= --pid= --pgid= --uid= --ignore" "$@"
        shift "$gc_nopt"
        for k in ${gc_optn[@]+"${gc_optn[@]}"}; do
          case "$k" in -p | -P | -u | --pid | --pgid | --uid) return 0 ;; esac
        done
        ;;
      chrt)
        # chrt [オプション] <優先度> <コマンド>。-T・-P・-D は値（ナノ秒）を取る。-p・-m は、コマンドを実行しない。
        # 優先度を省ける版もあるので、優先度は数のときだけ飛ばす
        ext=true
        shift
        gc_skip_opts TPD "--sched-runtime= --sched-period= --sched-deadline= --pid --max" "$@"
        shift "$gc_nopt"
        for k in ${gc_optn[@]+"${gc_optn[@]}"}; do
          case "$k" in -p | --pid | -m | --max) return 0 ;; esac
        done
        case "${1:-}" in '' | *[!0-9]*) ;; *) shift ;; esac
        ;;
      taskset)
        # taskset [オプション] <マスク> <コマンド>。-p は、動いているプロセスを変えるだけで、コマンドを実行しない
        ext=true
        shift
        gc_skip_opts "" "--all-tasks --cpu-list --pid" "$@"
        shift "$gc_nopt"
        for k in ${gc_optn[@]+"${gc_optn[@]}"}; do
          case "$k" in -p | --pid) return 0 ;; esac
        done
        [ $# -eq 0 ] || shift
        ;;
      flock)
        # flock [オプション] <ファイル> <コマンド>。-w・-E は値を取る。ファイルの後ろの -c <文字列> は sh -c と同じで、中は調べない
        ext=true
        shift
        gc_skip_opts wEc "--timeout= --conflict-exit-code= --command=" "$@"
        shift "$gc_nopt"
        [ $# -eq 0 ] || shift
        case "${1:-}" in -c | --command | --command=*) return 0 ;; esac
        ;;
      env)
        ext=true
        shift
        gc_skip_opts uCSa "--unset= --chdir= --split-string= --argv0= --ignore-environment" "$@"
        shift "$gc_nopt"
        # env の後ろの - は -i と同じ
        if [ "${1:-}" = - ]; then
          gc_genv=()
          shift
        fi
        if $has_cdir; then envbase="$cdir"; else envbase="$gc_dir"; fi
        split=()
        k=0
        while [ "$k" -lt "${#gc_optn[@]}" ]; do
          case "${gc_optn[k]}" in
            # -C <dir> は、このコマンドだけを、その場所で実行する（git -C と同じに扱う）。
            # 値をくっつけて書いたとき（-C~/x・--chdir=~/x）は、シェルは ~ を展開しない
            -C | --chdir) gc_set_cdir "$envbase" "$k" ;;
            # -S <文字列> は、値を env と同じく語に分けて、続きの引数の前に置く
            -S | --split-string)
              gc_split_s "${gc_optv[k]}"
              split+=(${gc_split[@]+"${gc_split[@]}"})
              ;;
            # -i は環境変数をすべて消し、-u <名前> はその変数を消すので、前の代入（GIT_DIR=x env -i git）は効かない
            -i | --ignore-environment) gc_genv=() ;;
            -u | --unset) gc_unset_genv "${gc_optv[k]}" ;;
          esac
          k=$((k + 1))
        done
        # 分けた語にも env のオプションがありうるので、もう一度 env として読む（値は短くなっていくので、いずれ終わる）
        [ "${#split[@]}" -eq 0 ] || set -- env "${split[@]}" "$@"
        ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0

  case "$1" in
    cd | pushd | popd | dirs)
      ! $ext || return 0
      ;;
  esac
  case "$1" in
    cd)
      # cd のオプション（-L・-P・-e）を飛ばす（- は前の場所、-- の後ろは - で始まっても行き先）。ほかのオプションがあれば、
      # cd は失敗して移らない（-e は bash 4.3 から。-@ は拡張属性に対応したシステムだけなので、失敗するものとして扱う）
      shift
      gc_skip_opts "" "" "$@"
      shift "$gc_nopt"
      for k in ${gc_optn[@]+"${gc_optn[@]}"}; do
        case "$k" in
          -L | -P | -e) ;;
          *) return 0 ;;
        esac
      done
      if [ $# -gt 0 ]; then gc_cd "$1"; else gc_cd; fi
      return 0
      ;;
    pushd)
      shift
      gc_pushd "$@"
      return 0
      ;;
    popd)
      shift
      gc_popd "$@"
      return 0
      ;;
    dirs)
      shift
      gc_dirs "$@"
      return 0
      ;;
    git | */git) shift ;;
    *) return 0 ;;
  esac

  if $has_cdir; then gc_git_dir="$cdir"; else gc_git_dir="$gc_dir"; fi
  gc_gopts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -C)
        [ $# -ge 2 ] || return 0
        gc_git_dir="$(gc_resolve_dir "$gc_git_dir" "$2")"
        shift 2
        ;;
      --git-dir | --work-tree)
        [ $# -ge 2 ] || return 0
        gc_gopts+=("$1" "$(gc_expand_home "$2")")
        shift 2
        ;;
      -c | --namespace | --config-env | --attr-source | --shallow-file)
        [ $# -ge 2 ] || return 0
        shift 2
        ;;
      --git-dir=* | --work-tree=*) gc_gopts+=("${1%%=*}=$(gc_expand_home "${1#*=}" no-tilde)"); shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  # 同じコマンドの中で作るリポジトリを覚える（gc_new_repo）。--git-dir・GIT_DIR などがあると、作る場所が変わるので覚えない。
  # after（コマンドの後）では、作ったリポジトリは既にあり、git が見つけられるので要らない
  if ! $after && [ "${#gc_gopts[@]}" -eq 0 ] && [ "${#gc_genv[@]}" -eq 0 ]; then
    case "$1" in
      init | clone) gc_note_new_repo "$@" ;;
    esac
  fi
  "$callback" "$@"
}

# --- 同じコマンドの中で作るリポジトリ ------------------------------------------------------
# フック（PreToolUse）はコマンドを実行する前に動くので、同じコマンドの中で git init・git clone で作るリポジトリは、まだ無く、
# git が見つけられない。そこで、作る場所を gc_scan の作業用の変数 new_repos に、1行ずつ「<種類><場所>」（i は init、c は clone）で覚え、
# その場所（とその下）で動く git を gc_new_repo で見分ける。

# git init・git clone の引数から、作るリポジトリの場所を覚える。gc_command から呼ぶ。
# git init [<ディレクトリ>] は、ディレクトリ（無ければ git を実行する場所）に作る。ただし、既にリポジトリのルート（bare なら
# git のディレクトリ）なら、作り直すだけで中身は変わらないので覚えない（今までどおり、そのリポジトリで判断する）。
# git clone <リポジトリ> [<ディレクトリ>] は、ディレクトリ（無ければ、リポジトリの名前の最後の部分。--bare・--mirror なら .git を足す）に作る
# 使い方: gc_note_new_repo <init か clone> <引数>...
gc_note_new_repo() {
  local sub="$1" npos=0 first="" second="" bare=false d gd c top
  shift
  case "$sub" in
    init) gc_args gc_note_new_repo_on b "--template= --separate-git-dir= --object-format= --ref-format= --initial-branch= --bare --quiet --shared" "$@" ;;
    clone) gc_args gc_note_new_repo_on objuc "--origin= --branch= --upload-pack= --reference= --reference-if-able= --separate-git-dir= --depth= --shallow-since= --shallow-exclude= --config= --template= --jobs= --filter= --server-option= --bundle-uri= --ref-format= --revision= --bare --mirror" "$@" ;;
  esac
  if [ "$sub" = init ]; then
    if [ "$npos" -eq 0 ]; then d="$gc_git_dir"; else d="$(gc_resolve_dir "$gc_git_dir" "$first")"; fi
    [ -n "$d" ] || return 0
    if [ -d "$d" ]; then
      { IFS= read -r gd; IFS= read -r c; IFS= read -r top; } <<<"$(dw_repo_paths "$d" || true)" || true
      [ "${top:-}" != "$d" ] && [ "${gd:-}" != "$d" ] || return 0
    fi
    new_repos+="i$d$nl"
  else
    [ "$npos" -ge 1 ] || return 0
    if [ "$npos" -ge 2 ]; then
      d="$second"
    else
      # git と同じく、末尾の / と /.git を除き、最後の / か : の後ろから .git・.bundle を除いた名前にする
      d="${first%"${first##*[!/]}"}"
      d="${d%/.git}"
      d="${d%"${d##*[!/]}"}"
      d="${d##*/}"
      d="${d##*:}"
      d="${d%.git}"
      d="${d%.bundle}"
      [ -n "$d" ] || return 0
      ! $bare || d="$d.git"
    fi
    d="$(gc_resolve_dir "$gc_git_dir" "$d")"
    [ -z "$d" ] || new_repos+="c$d$nl"
  fi
}
gc_note_new_repo_on() {
  case "$1" in
    opt)
      case "$2" in --bare | --mirror) bare=true ;; esac
      ;;
    arg)
      npos=$((npos + 1))
      case "$npos" in
        1) first="$2" ;;
        2) second="$2" ;;
      esac
      ;;
  esac
}

# 操作の対象（gc_git_dir）が、同じコマンドの中で前に作ったリポジトリ（gc_note_new_repo）の場所かその下なら、
# gc_new_kind に、作った方法（init・clone）を入れる。違えば空にする。後で覚えたものほど優先する。コールバックの中で呼ぶ
gc_new_kind=""
# shellcheck disable=SC2034 # gc_new_kind は呼び出し側（フック）が読む
gc_new_repo() {
  local s="$new_repos" e p
  gc_new_kind=""
  [ -n "$gc_git_dir" ] || return 0
  while [ -n "$s" ]; do
    e="${s%%"$nl"*}"
    s="${s#*"$nl"}"
    p="${e#?}"
    case "$gc_git_dir" in
      "$p" | "${p%/}"/*)
        case "$e" in
          i*) gc_new_kind=init ;;
          *) gc_new_kind=clone ;;
        esac
        ;;
    esac
  done
}

# --- コマンドの文字列を単語に分ける ------------------------------------------------
# bash では ${cmd:i} などが文字列の長さに比例して遅いので、1文字ずつではなく、特別な文字の手前までをまとめて読む。
# また $cmd を展開するたびに全体が写されるので、先の wsize 文字を wbuf に写しておき、そこから win 文字ずつ見る。
# 下の関数は、gc_scan の作業用の変数（local）を使う。gc_scan の中から呼ぶ。

# 残りの文字列の先頭（最大 win 文字）を rest に入れる。wbuf を使い切りそうなら写し直す
gc_window() {
  local off=$((i - wbase))
  if [ "$off" -lt 0 ] || { [ $((off + win)) -gt "${#wbuf}" ] && [ $((wbase + ${#wbuf})) -lt "$len" ]; }; then
    wbase=$i
    wbuf="${cmd:i:wsize}"
    off=0
  fi
  rest="${wbuf:off:win}"
}

gc_flush_word() {
  if $in_word; then
    if $skip_word; then
      skip_word=false
    else
      words+=("$word")
      nwords=$((nwords + 1))
      joined=false
    fi
  fi
  word="" in_word=false
}

# (( が算術式なら、閉じる )) の次の位置を arith_i に入れて 0 を返す。
# (( の後ろで最初に閉じる括弧の次が ) でなければ、((cmd) ...) のような入れ子のサブシェル
gc_arith_end() {
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

# ( の前の語が関数の名前で、( の後ろが ) なら（f()・function f()）、関数の定義として、名前（と function）を除いた語の予約語で
# 段を上げ下げし、( ) を読み飛ばす（名前をコマンドとして調べない。cd() { … } の cd は移動ではない）。続く本体は、その場で動いた
# 複合コマンドとして読む（定義を覚えて、呼んだ時に本体を読むことはしない）。関数の定義でなければ 1 を返す。gc_scan の ( で呼ぶ
gc_func_def() {
  local t k
  gc_flush_word
  [ "$nwords" -gt 0 ] || return 1
  t="${rest#?}"
  t="${t#"${t%%[! "$tab"]*}"}"
  [ "${t:0:1}" = ')' ] || return 1
  k=$((nwords - 1))
  # x=() は、空の配列の代入
  case "${words[k]}" in *=*) return 1 ;; esac
  [ "$k" -eq 0 ] || [ "${words[k - 1]}" != function ] || k=$((k - 1))
  local run_cmd=false
  [ "$k" -eq 0 ] || gc_track_words "${words[@]:0:k}"
  words=() nwords=0
  i=$((i + ${#rest} - ${#t} + 1))
}

# 読んだ語を1つのコマンドとして終え、先頭の予約語で入れ子の段を上げ下げしてから調べる（gc_command）。
# case のパターンを読んでいる間の語（a|b) の a・b）は、コマンドではないので調べない。語が無ければ何もしない
gc_end_command() {
  local run_cmd=true
  gc_flush_word
  skip_word=false
  if [ "$nwords" -gt 0 ]; then
    gc_track_words "${words[@]}"
    ! $run_cmd || gc_command "${words[@]}"
  fi
  words=() nwords=0
}

# --- 入れ子の段、パイプラインと & ---------------------------------------------------------
# 入れ子の段（lvl。0 が一番外）は、( )・複合コマンド（{ }・if〜fi・while/until/for/select〜done）・case〜esac で
# 1つ深くなる。段ごとに、次のものを持つ（添え字が段）。
#   lv_kind        top・paren（( )）・group（複合コマンド。関数の定義の本体を含む）・case
#   lv_pat         case の段で、パターンを読んでいるか（case … in の後と ;;・;&・;;& の後から、) まで）。
#                  パターンの中の |・(・) は、パイプやサブシェルではない
#   lv_sd・lv_sp   ( の時点の場所とスタック（( ) の中で移った・積んだ分は外に効かないので、) で戻す）
#   lv_e*・lv_l*   今のコマンドの始まりと、並び（&&・|| でつないだもの）の始まりの、場所・スタック・anchored
#   lv_pipe        パイプラインの2つ目以降のコマンドか
# dn は、開いている ( ) の数（after の決まりで、( ) の中かを見る）。
# パイプラインの各コマンド（2つ以上つないだとき）と、& でバックグラウンドで動かす並びは、シェル（bash）ではサブシェルで
# 動くので、その中で移った場所と積んだスタックは外に効かない。それが分かるのは | や & を読んだ時なので、覚えておいた
# 始まりへ戻す。区切りは、語の有無ではなく区切りの記号で判断する（(( )) のように語の無いコマンドもあるため）。
# after では、( ) と違い、パイプラインや & の中も外側と同じ規則でたどる（終わるまでサブシェルと分からないため）。

# 場所・スタック・anchored を戻す。使い方: gc_restore <場所> <スタック> <anchored>
gc_restore() { gc_dir="$1" pstack="$2" anchored="$3"; }
# 今の段の、コマンドの始まりを覚える
gc_mark_elem() { lv_ed[lvl]="$gc_dir" lv_ep[lvl]="$pstack" lv_ea[lvl]="$anchored"; }
# 今の段の、並び（とコマンド）の始まりを覚える
gc_mark_list() {
  gc_mark_elem
  lv_ld[lvl]="$gc_dir" lv_lp[lvl]="$pstack" lv_la[lvl]="$anchored"
}
# パイプラインを終える。2つ以上つないだときは、最後のコマンドもサブシェルなので、その始まりへ戻す
gc_end_pipe() {
  if "${lv_pipe[lvl]}"; then
    gc_restore "${lv_ed[lvl]}" "${lv_ep[lvl]}" "${lv_ea[lvl]}"
    lv_pipe[lvl]=false
  fi
}
# 今の段が、case のパターンを読んでいるところか
gc_in_pattern() { [ "${lv_kind[lvl]}" = case ] && "${lv_pat[lvl]}"; }
# 段を1つ深くする。使い方: gc_level_push <paren・group・case>
gc_level_push() {
  lvl=$((lvl + 1))
  lv_kind[lvl]="$1" lv_pipe[lvl]=false lv_pat[lvl]=false
  case "$1" in
    paren)
      lv_sd[lvl]="$gc_dir" lv_sp[lvl]="$pstack"
      dn=$((dn + 1))
      ;;
    case) lv_pat[lvl]=true ;;
  esac
  gc_mark_list
}
# 段を1つ浅くする。中の最後のパイプラインを終え、( ) なら ( の時点の場所とスタックに戻す
gc_level_pop() {
  [ "$lvl" -gt 0 ] || return 0
  gc_end_pipe
  if [ "${lv_kind[lvl]}" = paren ]; then
    gc_dir="${lv_sd[lvl]}" pstack="${lv_sp[lvl]}"
    dn=$((dn - 1))
  fi
  lvl=$((lvl - 1))
}
# コマンドの先頭の予約語から、複合コマンドと case の始まり（段を深くする）と終わり（浅くする）を読む。
# case のパターンを読んでいる間は、esac のほかは語をコマンドとして調べない（run_cmd を false にする。gc_end_command が読む）
gc_track_words() {
  local w
  if gc_in_pattern; then
    run_cmd=false
    [ "$1" != 'esac' ] || gc_level_pop
    return 0
  fi
  while [ $# -gt 0 ]; do
    w="$1"
    shift
    case "$w" in
      # 予約語は、bash 3.2 が case のパターンとして読めるよう、引用符で囲む
      '{' | 'if' | 'while' | 'until' | 'for' | 'select') gc_level_push group ;;
      # case の後ろは、調べる語・in・パターン。1行の空の case（case x in esac）は、すぐに閉じる
      'case')
        gc_level_push case
        [ "${2:-}" != in ] || [ "${3:-}" != 'esac' ] || gc_level_pop
        return 0
        ;;
      '}' | 'fi' | 'done') [ "${lv_kind[lvl]}" != group ] || gc_level_pop ;;
      'esac') [ "${lv_kind[lvl]}" != case ] || gc_level_pop ;;
      # function <名前> の名前を飛ばす
      'function') [ $# -eq 0 ] || shift ;;
      # time のオプション（-p・--）も飛ばす（gc_command と同じ）
      'time')
        gc_skip_opts "" "" "$@"
        shift "$gc_nopt"
        ;;
      'then' | 'elif' | 'else' | 'do' | '!') ;;
      *) return 0 ;;
    esac
  done
}

# i から <区切り> の手前までを cut に入れる（区切りが無ければ最後まで）。
# 窓の中で見つからないときだけ、残り全体から探す
# 使い方: gc_cut_until <区切りの文字>
gc_cut_until() {
  local rest
  gc_window
  cut="${rest%%"$1"*}"
  if [ "$cut" = "$rest" ] && [ $((i + ${#rest})) -lt "$len" ]; then
    rest="${cmd:i}"
    cut="${rest%%"$1"*}"
  fi
}

# '...' の中身を加える
gc_scan_squote() {
  local cut q
  i=$((i + 1))
  gc_cut_until "'"
  q="$cut"
  i=$((i - 1))
  word+="$q" in_word=true
  i=$((i + ${#q} + 2))
}

# `...` をそのまま加える
gc_scan_backtick() {
  local cut q
  i=$((i + 1))
  gc_cut_until '`'
  q="$cut"
  i=$((i - 1))
  word+="\`$q\`" in_word=true
  i=$((i + ${#q} + 2))
}

# "..." の中身を加える
gc_scan_dquote() {
  local rest chunk c n
  in_word=true
  i=$((i + 1))
  while [ "$i" -lt "$len" ]; do
    gc_window
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
          gc_scan_subst
        else
          word+="$c"
          i=$((i + 1))
        fi
        ;;
      '`') gc_scan_backtick ;;
    esac
  done
}

# $( ... ) と $(( ... )) をそのまま加える（中のコマンドは調べない）
gc_scan_subst() {
  local rest chunk c depth=1 arith=false
  gc_window
  # $(( ... )) の << はシフト演算で、ヒアドキュメントではない
  # shellcheck disable=SC2016
  [ "${rest:0:3}" != '$((' ] || arith=true
  # shellcheck disable=SC2016
  word+='$(' in_word=true
  i=$((i + 2))
  while [ "$i" -lt "$len" ]; do
    gc_window
    # shellcheck disable=SC2295
    chunk="${rest%%$sub_stop*}"
    if [ -n "$chunk" ]; then
      word+="$chunk"
      i=$((i + ${#chunk}))
      continue
    fi
    c="${rest:0:1}"
    case "$c" in
      "'") gc_scan_squote ;;
      '"') gc_scan_dquote ;;
      '`') gc_scan_backtick ;;
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
          gc_read_heredoc_delim
        else
          word+="$c"
          i=$((i + 1))
        fi
        ;;
      "$nl")
        word+=' '
        if [ "$hd_n" -gt 0 ]; then gc_skip_heredocs; else i=$((i + 1)); fi
        ;;
    esac
  done
}

# << の後ろの区切りの語を読み、次の改行で本文を飛ばせるように覚える（i は << の直後）
gc_read_heredoc_delim() {
  local rest c strip=0 d=""
  gc_window
  if [ "${rest:0:1}" = - ]; then
    strip=1
    i=$((i + 1))
  fi
  while [ "$i" -lt "$len" ]; do
    gc_window
    case "${rest:0:1}" in
      ' ' | "$tab") i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  while [ "$i" -lt "$len" ]; do
    gc_window
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
gc_skip_heredocs() {
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
        gc_cut_until "$nl"
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
gc_scan_redirect() {
  # 2>&1 の 2 のような、数字だけの語は fd の番号
  case "$word" in
    '' | *[!0-9]*) gc_flush_word ;;
    *) word="" in_word=false ;;
  esac
  local rest
  gc_window
  if [ "${rest:0:3}" = '<<<' ]; then
    i=$((i + 3))
    skip_word=true
  elif [ "${rest:0:2}" = '<<' ]; then
    i=$((i + 2))
    gc_read_heredoc_delim
  else
    i=$((i + 1))
    case "${rest:1:1}" in
      '>' | '&' | '|') i=$((i + 1)) ;;
    esac
    skip_word=true
  fi
}

# 使い方は先頭のコメント
gc_scan() {
  local callback="$1" cmd="$2" gc_dir="$3" after=false anchored=false reset_dir="${5:-}"
  [ "${4:-}" != after ] || after=true
  # bash 3.2 は、関数を呼ぶたびに呼び出し元の引数を写すので、長いコマンドの文字列を引数に残すと、
  # 下の関数を呼ぶたびに文字列の長さに比例して遅くなる。読んだら空にする
  set --
  local len=${#cmd}
  # bash 3.2 では "${...}" の中の $'\n' の扱いが新しい bash と違うので、変数にしておく
  local nl=$'\n' tab=$'\t'
  # 特別な文字（ここで区切ってまとめて読む）。外側・"..." の中・$( ) の中。
  # パターンとして使うので、${rest%%$top_stop*} のように引用符で囲まずに展開する（SC2295 は意図どおり）
  local top_stop='[\\ '"$tab$nl"';&|()<>#'"'"'"`$]'
  local dq_stop='[\\"$`]'
  # shellcheck disable=SC1003
  local sub_stop='[\\'"'"'"`()<'"$nl"']'
  local win=512 wsize=4096 wbase=0 wbuf="" rest="" chunk c cut=""
  local i=0
  local word="" in_word=false skip_word=false
  local words=() nwords=0
  local hd_delims=() hd_strip=() hd_n=0
  # pushd で積んだ場所（gc_pushd の前のコメント）
  local pstack="" dl=() entry="" idx=0
  # 同じコマンドの中で作るリポジトリ（gc_note_new_repo）
  local new_repos=""
  local arith_i=0
  # 入れ子の段と、段ごとの情報（gc_restore の前のコメント）。dn は開いている ( ) の数。&&・||・| の後ろか（joined）
  local lvl=0 dn=0 lv_kind=(top) lv_pat=(false) lv_pipe=(false) lv_sd=() lv_sp=() joined=false
  local lv_ed=() lv_ep=() lv_ea=() lv_ld=() lv_lp=() lv_la=()
  gc_mark_list

  while [ "$i" -lt "$len" ]; do
    gc_window
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
        gc_flush_word
        i=$((i + 1))
        ;;
      "$nl")
        gc_end_command
        # &&・||・| の後ろの改行では、並びが続く
        if ! $joined; then
          gc_end_pipe
          gc_mark_list
        fi
        if [ "$hd_n" -gt 0 ]; then gc_skip_heredocs; else i=$((i + 1)); fi
        ;;
      ';')
        gc_end_command
        gc_end_pipe
        gc_mark_list
        joined=false
        case "${rest:1:1}" in
          ';' | '&')
            # case の ;;・;&・;;& の後ろは、次のパターン（;& と ;;& の & は、バックグラウンドではない）
            [ "${lv_kind[lvl]}" != case ] || lv_pat[lvl]=true
            if [ "${rest:1:2}" = ';&' ]; then i=$((i + 3)); else i=$((i + 2)); fi
            ;;
          *) i=$((i + 1)) ;;
        esac
        ;;
      '&')
        case "${rest:1:1}" in
          '&')
            gc_end_command
            gc_end_pipe
            gc_mark_elem
            joined=true
            i=$((i + 2))
            ;;
          # &> と &>> は、リダイレクト
          '>') i=$((i + 1)) ;;
          *)
            # 並びごとバックグラウンド（サブシェル）で動くので、並びの始まりへ戻す
            gc_end_command
            gc_end_pipe
            gc_restore "${lv_ld[lvl]}" "${lv_lp[lvl]}" "${lv_la[lvl]}"
            gc_mark_list
            joined=false
            i=$((i + 1))
            ;;
        esac
        ;;
      '|')
        gc_end_command
        if gc_in_pattern; then
          # case のパターンの a|b) の | は、パイプではない
          i=$((i + 1))
        elif [ "${rest:1:1}" = '|' ]; then
          gc_end_pipe
          gc_mark_elem
          joined=true
          i=$((i + 2))
        else
          # パイプラインのコマンドはサブシェルで動くので、今のコマンドの始まりへ戻す。|& は標準エラーもつなぐパイプ
          gc_restore "${lv_ed[lvl]}" "${lv_ep[lvl]}" "${lv_ea[lvl]}"
          lv_pipe[lvl]=true
          joined=true
          if [ "${rest:1:1}" = '&' ]; then i=$((i + 2)); else i=$((i + 1)); fi
        fi
        ;;
      '(')
        if ! gc_in_pattern && gc_func_def; then
          # 関数の定義（f() …・function f() …）。名前はコマンドではない。続く { } が本体
          :
        elif gc_end_command && gc_in_pattern; then
          # case のパターンの前に付ける ( （(a) …）は、サブシェルではない
          i=$((i + 1))
        elif [ "${rest:1:1}" = '(' ] && gc_arith_end; then
          # (( ... )) は算術式なので、コマンドとして調べない（中の << もシフト演算）
          i=$arith_i
          joined=false
        else
          gc_level_push paren
          i=$((i + 1))
        fi
        ;;
      ')')
        gc_end_command
        if gc_in_pattern; then
          # case のパターンの終わり。ここから枝のコマンド
          lv_pat[lvl]=false
          gc_mark_list
        elif [ "${lv_kind[lvl]}" = paren ]; then
          gc_level_pop
        fi
        i=$((i + 1))
        ;;
      '<' | '>') gc_scan_redirect ;;
      '#')
        if $in_word; then
          word+="$c"
          i=$((i + 1))
        else
          # コメントは改行の手前まで飛ばす
          gc_cut_until "$nl"
          i=$((i + ${#cut}))
        fi
        ;;
      "'") gc_scan_squote ;;
      '"') gc_scan_dquote ;;
      '`') gc_scan_backtick ;;
      \\)
        if [ "${rest:1:1}" != "$nl" ]; then
          word+="${rest:1:1}" in_word=true
        fi
        i=$((i + 2))
        ;;
      '$')
        if [ "${rest:1:1}" = '(' ]; then
          gc_scan_subst
        else
          word+="$c" in_word=true
          i=$((i + 1))
        fi
        ;;
    esac
  done
  gc_end_command
}
