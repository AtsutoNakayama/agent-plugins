#!/usr/bin/env bash
# Claude Code のフック（PreToolUse の Bash）。マージ先のブランチ（base_branch。既定は main）を守るため、
# 次の git の操作を止める。
#   - base_branch の上での git commit
#   - base_branch への git push（base_branch の上で push 先を書かずに push するときを含む）
#   - 強制 push（--force / -f / +<refspec> / --mirror）。--force-with-lease は許可する
#
# また、ブランチを作るコマンド（git switch -c / git checkout -b / git branch <名前> / git worktree add -b）で、
# 名前が規約（branch-name.sh --check）に合わなければ、コマンドは止めずに警告する。
#
# 標準入力でフックの入力（JSON）を受け取る。止めるときは理由を標準エラーに1行で出し、終了コード 2 で終わる
# （Claude Code はコマンドを実行せず、理由を Claude に伝える）。警告するときは、フックの出力の JSON を
# 標準出力に出し、終了コード 0 で終わる。
# 操作の対象のリポジトリ（cd・pushd・popd・git -C・env -C で移った先、--git-dir・GIT_DIR などで指したリポジトリ）が、導入して
# いないリポジトリなら何もしない（gc_target・target_set_up）。git がリポジトリを見つけられないときは、守りを外さないよう調べる（設計書 §1）。
# ただし今のブランチを読めないので、コミットと、push 先を書かない push（と HEAD・@ への push）は止める（target_unknown）。
# コマンドの文字列の解析は、pr-link.sh と共有する（scripts/lib/git-command.sh）。timeout・env などの前に付くコマンドは飛ばすが、
# sh -c・xargs などを通したコマンドや git の別名（alias）を通すと見逃す。
# 最後の守りは GitHub のルールセット（setup-repo.sh）。
# 関数は gc_scan のコールバック（check_git）から呼ぶので、直接の呼び出しが無い（SC2329）
# shellcheck disable=SC2329
set -euo pipefail

# 日本語をバイト列として扱い、1文字ずつの読み取りを速く・確実にする
export LC_ALL=C

# shellcheck source=../scripts/lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/../scripts/lib/common.sh"
# shellcheck source=../scripts/lib/git-command.sh
. "$DW_SCRIPTS_DIR/lib/git-command.sh"
dw_require jq

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
# git を含まないコマンドは解析しない（Bash を使うたびに呼ばれるので速く抜ける）
case "$cmd" in
  *git*) ;;
  *) exit 0 ;;
esac
cwd="$(jq -r '.cwd // empty' <<<"$input")"
dir="$( (CDPATH='' cd "${cwd:-.}" && pwd -P) 2>/dev/null || true)"
# ブランチ名の警告（最後にまとめて出す）
warnings=() nwarn=0

# --- 判断 -------------------------------------------------------------------------

deny() { dw_die "$1" 2; }

# 操作の対象が、導入したリポジトリなら成功し、導入していなければ 1 を返す（設計書 §1）。gc_target の後に呼ぶ。
#   - ルートが分かれば、そこ（かメインのワークツリー）にチームの設定があるか（dw_is_set_up）
#   - リポジトリは分かるがルートが分からない（bare リポジトリ、外から指した --separate-git-dir のリポジトリなど）ときは、
#     HEAD にチームの設定がコミットされているか
#   - git がリポジトリを見つけられない（ディレクトリが分からない cd - の後など）ときは、守りを外さないよう、導入したものとみなす（ただし今のブランチを読めないので、コミットと push 先を書かない push（と HEAD・@ への push）は止める。target_unknown）
target_set_up() {
  if [ -n "$gc_root" ]; then
    dw_is_set_up "$gc_root"
    return
  fi
  [ -n "$gc_repo" ] || return 0
  gc_git cat-file -e "HEAD:.claude/dev-workflow/config.json"
}

# 対象のリポジトリを git が見つけられないとき（ディレクトリが分からない cd - の後など）に成功する。gc_target の後に呼ぶ。
# このときは HEAD を読めず、今のブランチが分からない。空のブランチを base_branch ではないとみなして通すと守りが外れるので、
# 今のブランチに頼る操作（コミットと、push 先を書かない push・HEAD や @ への push）は止める。それ以外の、先の名前を書いた push は、書かれた先で判断できるので通す
target_unknown() { [ -z "$gc_repo" ]; }

# 対象が分からないときに止める理由。使い方: unknown_target_message <止める操作>
unknown_target_message() {
  echo "操作の対象のリポジトリが分からないので、${1}は止めます（今のブランチが分からず、base_branch の上かを確かめられません）。cd -- <絶対パス> && git ...、または git -C <絶対パス> ... で対象を書き直してください"
}

# 対象のリポジトリの base_branch を求め、base_of に入れる。読めなければ main。gc_target・target_set_up の後（導入した
# リポジトリのとき）に呼ぶ。1つのコマンドの中で同じリポジトリを何度も調べるので、対象（gc_root・gc_repo）ごとに覚えておく。
# ルートが分かれば、そのリポジトリの設定（config.sh。導入したリポジトリなのでユーザーの層も合わせる）から読む。
# ルートが分からなければ、HEAD にコミットされたチームの設定、ユーザーの層の順に読む（導入したものとして調べているので、
# ユーザーの層も効かせる）。今のディレクトリのリポジトリの設定は、対象と違うことがあるので、代わりに読まない。
# どの値も、git のブランチ名として使えなければ（dw_valid_base_branch）使わない。チームの設定に値があって使えなければ、
# 個人の層の値（上書きやユーザーの層）は使わずに main を守る（チームが決めた値の代わりに、個人の値を守らない。
# setup-repo.sh もその値で止まり、ルールセットを作らない）。合わせた設定の値が使えなければ、チームの設定の値を使う
base_of="" base_of_key="" user_config=""
load_base_branch() {
  local base="" team key
  key="${gc_root}|${gc_repo}"
  [ "$base_of_key" != "$key" ] || return 0
  if [ -n "$gc_root" ]; then
    if team="$( (dw_team_base_branch "$gc_root/.claude/dev-workflow/config.json") 2>/dev/null)"; then
      # 末尾の改行を消さないよう、印（.）を付けて受けて外す（dw_base_branch と同じ）
      base="$( (cd "$gc_root" && WORKFLOW_REPO_ROOT="$gc_root" "$BASH" "$DW_SCRIPTS_DIR/config.sh" '.base_branch | strings | . + "."') 2>/dev/null || true)"
      base="${base%.}"
      dw_valid_base_branch "$base" || base="$team"
    fi
  elif [ -n "$gc_repo" ] && team="$(gc_git show "HEAD:.claude/dev-workflow/config.json")"; then
    # コミットしたチームの設定は、ルートが分かるときと同じ決め方（DW_JQ_ONE_OBJECT）で読む。壊れていれば main を守り、
    # 値が無いときだけユーザーの層を読む。値があれば（false などの文字列でない値も）、使えなくても main を守る
    if team="$(jq -sc "$DW_JQ_ONE_OBJECT | {base_branch}" <<<"$team" 2>/dev/null)"; then
      if [ "$team" = '{"base_branch":null}' ]; then
        read_user_base_branch
      else
        base="$( (dw_base_branch "$team") 2>/dev/null || true)"
      fi
    fi
  else
    read_user_base_branch
  fi
  dw_valid_base_branch "$base" || base=""
  base_of="${base:-main}" base_of_key="$key"
}

# ユーザーの層の base_branch を、呼んだ側の base に入れる。ほかの設定と同じく、JSON のオブジェクト1つとして読み
# （DW_JQ_ONE_OBJECT）、読めなければ空にする。ユーザーの層の場所は、フックの中で変わらないので、初めて要るときに1回だけ求める
read_user_base_branch() {
  [ -n "$user_config" ] || user_config="$(dw_user_dir)/config.json"
  base="$(jq -sr "$DW_JQ_ONE_OBJECT | .base_branch | strings | . + \".\"" "$user_config" 2>/dev/null || true)"
  base="${base%.}"
}

# git push の引数を調べる（引数の読み方は gc_push_args）。使い方: check_push <引数>...
check_push() {
  local w dest current base
  gc_push_args "$@"
  ! $gc_push_force || deny "強制 push（--force / -f / +<refspec> / --mirror）はしません。必要なら --force-with-lease を使ってください"

  current="$(gc_branch)"
  load_base_branch
  base="$base_of"
  if [ "${#gc_push_refs[@]}" -eq 0 ]; then
    ! target_unknown || deny "$(unknown_target_message "push 先を書かない push")"
    [ "$current" != "$base" ] \
      || deny "${base} へは push しません。作業用のブランチ（task-start）で PR を作ってください"
    return 0
  fi
  for w in "${gc_push_refs[@]}"; do
    w="${w#+}"
    case "$w" in
      *:*) dest="${w##*:}" ;;
      *) dest="$w" ;;
    esac
    case "$dest" in
      HEAD | @)
        # 今のブランチを読めないと dest が空になって通ってしまうので、止める
        ! target_unknown || deny "$(unknown_target_message "HEAD・@ への push")"
        dest="$current"
        ;;
    esac
    dest="${dest#refs/heads/}"
    # ":" は、先を書かない matching refspec で、手元とリモートに同じ名前のブランチをすべて push する（base_branch も含みうる）。
    # 今のブランチだけを調べても防げないので、いつも止める
    [ "$w" != ":" ] \
      || deny "matching refspec（:）は、同じ名前のブランチをすべて push するので止めます。push するブランチの名前を書いてください"
    [ -z "$dest" ] || [ "$dest" != "$base" ] \
      || deny "${base} へは push しません。作業用のブランチ（task-start）で PR を作ってください"
  done
}

# 作るブランチの名前を branch-name.sh --check で確かめ、規約に合わなければ警告を覚えておく。
# 名前に展開前の $ や ` があるとき、設定を読めないときなどは何もしない。
# base_branch や、手元・リモートに既にあるブランチ（-C・-B・-f で合わせ直すとき、他人のブランチを取ってくるとき）は、
# 名前を変えさせないよう確かめない
# 使い方: check_branch_name <名前>
check_branch_name() {
  local name="$1" out
  case "$name" in
    '' | *'$'* | *'`'*) return 0 ;;
  esac
  # 対象のルートが分からなければ、どの規約で確かめるか分からないので確かめない（警告だけなので、止める側に倒さない）
  [ -n "$gc_root" ] || return 0
  load_base_branch
  [ "$name" != "$base_of" ] || return 0
  gc_git show-ref --verify --quiet "refs/heads/$name" && return 0
  [ -z "$(gc_git for-each-ref --format=x "refs/remotes/*/$name" || true)" ] || return 0
  # 規約に合わないときだけ終了コード 1（設定を読めないなどは 2）
  out="$( (cd "$gc_root" && WORKFLOW_REPO_ROOT="$gc_root" "$BASH" "$DW_SCRIPTS_DIR/branch-name.sh" --check "$name") 2>/dev/null)" \
    && return 0
  [ $? -eq 1 ] || return 0
  warnings+=("ブランチ名 ${name} は規約に合いません（$(jq -r '.reason // empty' <<<"$out" 2>/dev/null || true)）。")
  nwarn=$((nwarn + 1))
}

# git の呼び出しを1つ調べる（gc_scan のコールバック）。使い方: check_git <サブコマンド> <引数>...
check_git() {
  local sub="$1" base
  shift
  case "$sub" in
    commit | push | switch | checkout | branch | worktree)
      # 操作の対象を求め、導入していないリポジトリなら何もしない（git がリポジトリを見つけられないときは、今までどおり調べる。ただし今のブランチを読めないので、コミットと push 先を書かない push（と HEAD・@ への push）は止める。target_unknown）
      gc_target
      target_set_up || return 0
      ;;
    *) return 0 ;;
  esac

  case "$sub" in
    commit)
      ! target_unknown || deny "$(unknown_target_message "コミット")"
      load_base_branch
      base="$base_of"
      [ "$(gc_branch)" != "$base" ] \
        || deny "${base} の上ではコミットしません。作業用のブランチを作ってください（task-start）"
      ;;
    push) check_push "$@" ;;
    *) gc_new_branches check_branch_name "$sub" "$@" ;;
  esac
}

gc_scan check_git "$cmd" "$dir"

# 警告は、使用者には systemMessage、Claude には additionalContext で伝える。コマンドはいつもどおり実行させる
if [ "$nwarn" -gt 0 ]; then
  msg="${warnings[*]} 規約（branch.pattern）に合うブランチは task-start で作れます。作った後なら git branch -m <新しい名前> で名前を変えられます"
  jq -n --arg m "$msg" '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $m}}'
fi
exit 0
