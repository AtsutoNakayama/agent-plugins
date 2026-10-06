# shellcheck shell=bash
# コマンドの文字列（Claude Code の Bash の tool_input.command）を解析し、git の呼び出しごとに、
# どのサブコマンドを、どのディレクトリ・どのリポジトリに対して実行するかを渡す。フック（guard-git.sh・pr-link.sh）が共有する。
# common.sh の後に source する。
#
# 引用符・エスケープ・$( )・ヒアドキュメント・リダイレクトを考え、; & | 改行 ( ) でコマンドを区切る。
# cd で移った先、pushd・popd で積んだ・戻った場所（シェルと同じく、dirs のスタックを追う）、git -C・env -C で指した先を追う
# （( ) の中で移った・積んだ分は外に効かない）。cd - の後は、移った先を不明とする。前に付くコマンド（command・exec・time・nohup・
# env・timeout・nice）は、そのオプションとともに飛ばす（env -S の値は空白で分けて読む）。$( ) の中のコマンドは調べない。
# sh -c・xargs などや git の別名（alias）を通すと見逃す。
#
# 使い方:
#   gc_scan <コールバック> <コマンドの文字列> <始めのディレクトリ（空なら不明）> [after [<戻す先>]]
#   git の呼び出しごとに「<コールバック> <サブコマンド> <残りの引数>...」を呼ぶ。呼ぶ前に、次の変数を設定する。
#     gc_git_dir  git を実行するディレクトリ（cd・git -C で移った先。分からなければ空）
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
#   たどっていない状態（cwd）に戻る（pushd から popd までは、シェルの場所を変えないので）。
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
# 使い方: gc_resolve_dir <基準のディレクトリ（空なら不明）> <パス>
gc_resolve_dir() {
  local p
  p="$(gc_expand_home "$2")"
  case "$p" in
    /*) dw_abs_dir / "$p" || true ;;
    *) [ -z "$1" ] || dw_abs_dir "$1" "$p" || true ;;
  esac
}

# git の操作の対象（ディレクトリと、git のグローバルオプション・対象を変える環境変数）で git を実行する。
# 使い方: gc_git <コマンド>...   （gc_git_dir と gc_gopts と gc_genv を参照する）
gc_git() {
  [ -n "$gc_git_dir" ] || return 1
  (cd "$gc_git_dir" && env ${gc_genv[@]+"${gc_genv[@]}"} git ${gc_gopts[@]+"${gc_gopts[@]}"} "$@" 2>/dev/null)
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

# ブランチを作る git のコマンドから、作るブランチの名前を探し、名前ごとに「<コールバック> <名前>」を呼ぶ。
# 対象は git switch -c/-C/--create/--force-create/--orphan、git checkout -b/-B/--orphan、git worktree add -b/-B、git branch <名前>。
# 短いオプションはまとめて書け（-qc name）、名前をくっつけても書ける（-cname）。
# 使い方: gc_new_branches <コールバック> <サブコマンド> <引数>...
gc_new_branches() {
  local cb="$1" sub="$2"
  shift 2
  case "$sub" in
    switch) gc_create_opts "$cb" cC "--create --force-create --orphan" "$@" ;;
    checkout) gc_create_opts "$cb" bB "--orphan" "$@" ;;
    branch) gc_branch_create "$cb" "$@" ;;
    worktree)
      if [ "${1:-}" = add ]; then
        shift
        gc_create_opts "$cb" bB "" "$@"
      fi
      ;;
  esac
}

# git switch・git checkout・git worktree add の引数から、作るブランチの名前を探す。
# 使い方: gc_create_opts <コールバック> <値を取る短いオプションの文字> <値を取る長いオプション（空白区切り）> <引数>...
gc_create_opts() {
  local cb="$1" shorts="$2" longs=" $3 " expect=false w k c
  shift 3
  for w in "$@"; do
    if $expect; then
      expect=false
      "$cb" "$w"
      continue
    fi
    case "$w" in
      --) return 0 ;;
      --*=*)
        case "$longs" in *" ${w%%=*} "*) "$cb" "${w#*=}" ;; esac
        ;;
      --*)
        case "$longs" in *" $w "*) expect=true ;; esac
        ;;
      -?*)
        # 短いオプションはまとめて書ける（-qc name）。値を取る文字の後ろが残っていれば、それが値（-cname）
        k=1
        while [ "$k" -lt "${#w}" ]; do
          c="${w:k:1}"
          case "$shorts" in
            *"$c"*)
              if [ "$((k + 1))" -lt "${#w}" ]; then
                "$cb" "${w:k+1}"
              else
                expect=true
              fi
              break
              ;;
          esac
          k=$((k + 1))
        done
        ;;
    esac
  done
}

# git branch の引数を調べる。ブランチを作るとき（一覧・削除・名前の変更などのオプションが無く、名前がある）だけ名前を渡す。
# オプションは名前の後ろにも書けるので（git branch bar -d）、すべての引数を見てから判断する
# 使い方: gc_branch_create <コールバック> <引数>...
gc_branch_create() {
  local cb="$1" w after_dd=false name=""
  shift
  for w in "$@"; do
    if ! $after_dd; then
      case "$w" in
        --) after_dd=true; continue ;;
        --force | --track | --track=* | --no-track | --quiet | --create-reflog | --recurse-submodules | --color | --color=* | --no-color) continue ;;
        # 短いオプションはまとめて書ける（-ft）。作るときに使う f・t・q だけなら続ける
        -*[!ftq]*) return 0 ;;
        -?*) continue ;;
        -*) return 0 ;;
      esac
    fi
    [ -n "$name" ] || name="$w"
  done
  [ -z "$name" ] || "$cb" "$name"
}

# git worktree add <パス> <ブランチ>（-b・-B を付けない形）の、2つ目の位置引数を「<コールバック> <名前>」に渡す。
# gc_new_branches と違い、作るブランチではなく、既にあるブランチを使う書き方。値を取るオプション（--reason・-b・-B）の次の語は、
# 位置引数に数えない
# 使い方: gc_worktree_branch <コールバック> <add の後の引数>...
gc_worktree_branch() {
  local cb="$1" w pos=0 skip=false
  shift
  for w in "$@"; do
    if $skip; then
      skip=false
      continue
    fi
    case "$w" in
      --reason | -b | -B) skip=true ;;
      -*) ;;
      *)
        pos=$((pos + 1))
        if [ "$pos" -eq 2 ]; then
          "$cb" "$w"
          return 0
        fi
        ;;
    esac
  done
}

# git push の引数を読んで、次の変数に入れる。guard-git.sh（強制 push・push 先）と pr-link.sh（dry-run）が使う。
#   gc_push_force   強制 push（--force・-f・--mirror・+<refspec>）なら true。--force-with-lease は含めない
#   gc_push_dry     dry-run（--dry-run・-n）なら true
#   gc_push_refs    refspec の配列（リモートの後ろの引数）
# 短いオプションはまとめて書ける（-fu・-nu）。値を取るオプション（--repo・--push-option・--receive-pack・--exec・
# --recurse-submodules・-o）の値（次の語）は飛ばす。長いオプションは、git と同じく略して書ける（--mirr・--dry・--recu）。
# 略した形が曖昧なとき（--forc）は、git が失敗して push しないので、どう読んでもよい。-- の後ろは、オプションとみなさない
# 使い方: gc_push_args <引数>...
gc_push_force=false gc_push_dry=false gc_push_refs=()
# shellcheck disable=SC2034 # gc_push_force・gc_push_dry は呼び出し側（フック）が読む
gc_push_args() {
  local after_dd=false expect=false w k c remote=""
  # 略した形を、略さない名前の頭と比べる
  local mirror=--mirror dry=--dry-run with_value=" --repo --push-option --receive-pack --exec --recurse-submodules"
  gc_push_force=false gc_push_dry=false gc_push_refs=()
  for w in "$@"; do
    if $expect; then
      expect=false
      continue
    fi
    if ! $after_dd; then
      case "$w" in
        --) after_dd=true; continue ;;
        --force) gc_push_force=true; continue ;;
        --*=*) continue ;;
        --*)
          # 略した形も読む（"$w" は文字として比べる）。--mirror はすべての ref をリモートに合わせて上書き・削除する
          case "$mirror" in "$w"*) gc_push_force=true; continue ;; esac
          case "$dry" in "$w"*) gc_push_dry=true; continue ;; esac
          case "$with_value" in *" $w"*) expect=true ;; esac
          continue
          ;;
        -?*)
          # -o は値を取るので、その後ろは値
          k=1
          while [ "$k" -lt "${#w}" ]; do
            c="${w:k:1}"
            case "$c" in
              f) gc_push_force=true ;;
              n) gc_push_dry=true ;;
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
      gc_push_refs+=("$w")
      case "$w" in +*) gc_push_force=true ;; esac
    fi
  done
}

# --- コマンドごとの解析 -------------------------------------------------------------

# 前に付くコマンド（timeout・nice・env など）のオプションを読む。最初のオプションでない語か -- で止まる（-- も数える）。
# 短いオプションはまとめて書け（-iu FOO）、値をくっつけても書ける（-uFOO）。長いオプションは --name=value とも書け、
# getopt と同じく略して書ける（--sig KILL）。
# 使い方: gc_skip_opts <値を取る短いオプションの文字> <値を取る長いオプション（空白区切り）> <引数>...
#   gc_nopt  オプションの語の数
#   gc_optn  オプションの名前（-C・--chdir。略した長いオプションは、略さない名前）の配列
#   gc_optv  オプションの値（値を取らなければ空）の配列
gc_nopt=0 gc_optn=() gc_optv=()
gc_skip_opts() {
  local shorts="$1" longs="$2" w k c l n=0 name=""
  shift 2
  gc_optn=() gc_optv=()
  for w in "$@"; do
    if [ -n "$name" ]; then
      gc_optn+=("$name") gc_optv+=("$w")
      name="" n=$((n + 1))
      continue
    fi
    case "$w" in
      --) n=$((n + 1)); break ;;
      --*)
        c=""
        # 長いオプションの名前は空白も * なども含まないので、分けて並べる
        # shellcheck disable=SC2086
        for l in $longs; do
          case "$l" in "${w%%=*}"*) c="$l"; break ;; esac
        done
        if [ -z "$c" ]; then
          gc_optn+=("${w%%=*}") gc_optv+=("")
        else
          case "$w" in
            *=*) gc_optn+=("$c") gc_optv+=("${w#*=}") ;;
            *) name="$c" ;;
          esac
        fi
        ;;
      -?*)
        # 値を取る文字の後ろが残っていれば、それが値（-uFOO）
        k=1
        while [ "$k" -lt "${#w}" ]; do
          c="${w:k:1}"
          case "$shorts" in
            *"$c"*)
              if [ "$((k + 1))" -lt "${#w}" ]; then
                gc_optn+=("-$c") gc_optv+=("${w:k+1}")
              else
                name="-$c"
              fi
              break
              ;;
          esac
          gc_optn+=("-$c") gc_optv+=("")
          k=$((k + 1))
        done
        ;;
      *) break ;;
    esac
    n=$((n + 1))
  done
  # 値の無いまま終わった
  if [ -n "$name" ]; then
    gc_optn+=("$name") gc_optv+=("")
  fi
  gc_nopt=$n
}

# cd で移る。after のときの外側の相対パスの扱いは、先頭のコメント。gc_scan の中から呼ぶ。
# 使い方: gc_cd <行き先（空なら $HOME、- なら前の場所）>
gc_cd() {
  local target="$1" to
  case "$target" in
    '') to="$(gc_resolve_dir "" "$HOME")" ;;
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
      gc_dir="${1#p}"
      [ "$dn" -gt 0 ] || anchored=false
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
gc_dirs_index() {
  local n="${1#[+-]}"
  case "$n" in '' | *[!0-9]*) return 1 ;; esac
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
    case "$1" in
      -n) nocd=true; shift ;;
      --) shift; break ;;
      - | [+-][0-9]*) break ;;
      -*) return 0 ;;
      *) break ;;
    esac
  done
  [ $# -le 1 ] || return 0
  if [ $# -eq 1 ]; then
    case "$1" in
      [+-][0-9]*) ;;
      *)
        if $nocd; then
          # パスのまま積む（改行を含むパスは、1行に収まらないので不明とする）
          case "$1" in
            *"$nl"*) pstack="d$nl$pstack" ;;
            *) pstack="r$1$nl$pstack" ;;
          esac
        else
          gc_cur_entry
          pstack="$entry$nl$pstack"
          gc_cd "$1"
        fi
        return 0
        ;;
    esac
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
    case "$1" in
      -n) nocd=true; shift ;;
      --) shift; break ;;
      [+-][0-9]*) break ;;
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

# dirs -c はスタックを空にする
gc_dirs() {
  local w
  for w in "$@"; do
    case "$w" in
      [+-][0-9]*) ;;
      -*c*) pstack="" ;;
    esac
  done
}

# 1つのコマンド（単語の並び）を調べる。cd・pushd・popd・dirs なら場所とスタックを変え、git ならコールバックを呼ぶ。
# gc_scan の中から呼ぶ。
# 使い方: gc_command <単語>...
gc_command() {
  local cdir="" has_cdir=false envbase ext=false k sw=() split=()
  # 先頭の環境変数の代入（FOO=1 git push）、前に付くコマンドとそのオプション、予約語（then git push）を飛ばす。
  # 操作の対象を変える代入（GIT_DIR など）は、対象のリポジトリを求めるときに使う。
  # 外部のコマンド（env・nohup・timeout・nice・exec）として実行する cd などは、シェルの場所を変えない（ext）
  gc_genv=()
  while [ $# -gt 0 ]; do
    case "$1" in
      GIT_DIR=* | GIT_WORK_TREE=* | GIT_COMMON_DIR=*) gc_genv+=("${1%%=*}=$(gc_expand_home "${1#*=}")"); shift ;;
      [A-Za-z_]*=*) shift ;;
      if | then | elif | else | while | until | do | '{' | '!') shift ;;
      time)
        # time -p（シェルの予約語なので、組み込みのコマンドもシェルの中で実行する）
        shift
        gc_skip_opts "" "" "$@"
        shift "$gc_nopt"
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
      nohup) ext=true; shift ;;
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
        gc_skip_opts ks "--kill-after --signal" "$@"
        shift "$gc_nopt"
        [ $# -eq 0 ] || shift
        ;;
      nice)
        # nice -n 5・nice -5・nice --adjustment=5
        ext=true
        shift
        gc_skip_opts n --adjustment "$@"
        shift "$gc_nopt"
        ;;
      env)
        ext=true
        shift
        gc_skip_opts uCSa "--unset --chdir --split-string --argv0" "$@"
        shift "$gc_nopt"
        # env の後ろの - は -i と同じ
        [ "${1:-}" != - ] || shift
        if $has_cdir; then envbase="$cdir"; else envbase="$gc_dir"; fi
        split=()
        k=0
        while [ "$k" -lt "${#gc_optn[@]}" ]; do
          case "${gc_optn[k]}" in
            # -C <dir> は、このコマンドだけを、その場所で実行する（git -C と同じに扱う）
            -C | --chdir)
              cdir="$(gc_resolve_dir "$envbase" "${gc_optv[k]}")"
              has_cdir=true
              ;;
            # -S <文字列> は、値を空白で分けた語を、続きの引数の前に置く（引用符・エスケープ・変数は解かない）
            -S | --split-string)
              sw=()
              IFS=" $tab$nl" read -r -d '' -a sw <<<"${gc_optv[k]}" || true
              split+=(${sw[@]+"${sw[@]}"})
              ;;
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
      shift
      while [ $# -gt 0 ]; do
        case "$1" in
          -) break ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      gc_cd "${1:-}"
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
  "$callback" "$@"
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

# case と esac を数える。case の時点の括弧の深さを積み、パターンの ) で括弧を閉じないようにする
gc_track_case() {
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

gc_end_command() {
  gc_flush_word
  skip_word=false
  [ "$nwords" -eq 0 ] || gc_track_case "${words[@]}"
  [ "$nwords" -eq 0 ] || gc_command "${words[@]}"
  words=() nwords=0
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
  # ( ) の中の cd は外に効かないので、( の時点のディレクトリを積んでおき、) で戻す
  local dstack=() dn=0
  # pushd で積んだ場所（gc_pushd の前のコメント）。( の時点のものを pstack_save に積んでおき、) で戻す
  local pstack="" pstack_save=() dl=() entry="" idx=0
  # case の中の深さ（case の時点の dn を積む）
  local case_dn=() cn=0
  local arith_i=0

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
        if [ "$hd_n" -gt 0 ]; then gc_skip_heredocs; else i=$((i + 1)); fi
        ;;
      ';' | '&' | '|')
        gc_end_command
        i=$((i + 1))
        ;;
      '(')
        gc_end_command
        if [ "${rest:1:1}" = '(' ] && gc_arith_end; then
          # (( ... )) は算術式なので、コマンドとして調べない（中の << もシフト演算）
          i=$arith_i
        else
          dstack[dn]="$gc_dir"
          pstack_save[dn]="$pstack"
          dn=$((dn + 1))
          i=$((i + 1))
        fi
        ;;
      ')')
        gc_end_command
        # case のパターンの ) （a) など）は括弧を閉じない
        if [ "$cn" -gt 0 ] && [ "$dn" -eq "${case_dn[cn - 1]}" ]; then
          :
        elif [ "$dn" -gt 0 ]; then
          dn=$((dn - 1))
          gc_dir="${dstack[dn]}"
          pstack="${pstack_save[dn]}"
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
