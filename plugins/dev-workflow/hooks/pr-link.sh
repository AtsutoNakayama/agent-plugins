#!/usr/bin/env bash
# Claude Code のフック（PostToolUse の Bash）。git の操作のあとに、関連する PR・Issue・CI のリンクを出す。
# リンクは、Claude が返答に書いたときにしか見えないので、操作のたびに使用者の画面へ出して、すぐ開けるようにする。
#
#   - git push（pr-create.sh を含む）            開いた PR の URL（無ければ PR を作る URL）、紐付く Issue、PR の CI（checks）
#   - git commit（commit.sh を含む）             紐付く Issue
#   - ブランチ・ワークツリーの作成（追跡ブランチを作る git switch・checkout を含む）
#     （git switch -c など、task-start.sh を含む）  紐付く Issue
#   - gh pr create・gh issue create
#     （pr-create.sh・issue-create.sh を含む）      作った PR・Issue（標準出力から拾う）
#
# 決まり（設計書 §9）:
#   - 同じリンクも、連続で毎回出す（常に見えるようにするため）
#   - git のコマンドは、操作の対象（cd・pushd・popd・git -C・env -C・sudo -D で移った先、--git-dir・GIT_DIR で指したリポジトリ。gc_target）の
#     リポジトリ・ブランチで判断する。cd - の後と、プロジェクトのルートからの相対パスへの cd の後は、
#     移った先が分からないので出さない（scripts/lib/git-command.sh の gc_scan の after）
#   - Issue の番号が分からないブランチ（main など）では、ブランチから導くリンクは出さない（作った PR・Issue は出す）
#   - gh が無い・失敗する・解析できないときは、何も出さずに通す。フックは作業を止めない（いつも終了コード 0）
#   - 導入していないリポジトリ（dw_is_set_up）では、何も出さない（設計書 §1）
#
# 出力は、使用者に見せる systemMessage と、Claude に渡す additionalContext（返答でも触れてもらう）の JSON。
# git のコマンドは、guard-git.sh と同じ解析（scripts/lib/git-command.sh）で拾う。sh -c・xargs や別名を通すと見逃す。
# スクリプト（commit.sh など）と gh pr create・gh issue create は、コマンドの文字列を簡易に判定するだけなので、
# 引用符の中の文字にも反応し、フックの入力の cwd のリポジトリで判断する。
# 標準入力でフックの入力（JSON）を受け取る。
# 関数は gc_scan などのコールバック（on_git・add_new_name）から呼ぶので、直接の呼び出しが無い（SC2329）
# shellcheck disable=SC2329
set -euo pipefail
# どこで失敗しても、作業は止めない（失敗して止まるときも、終了コードは 0 にする）。
# ERR トラップ（set -E）は使わない。bash 3.2 では、コマンド置換 $( ) の中にも引き継がれ、
# 中の gh が失敗しても、トラップの exit 0 が先に動いて、置換が成功（空の出力）になってしまうため。
# EXIT トラップは、コマンド置換には引き継がれない。エラーの表示も出さない
trap 'exit 0' EXIT
exec 2>/dev/null

# 日本語をバイト列として扱う
export LC_ALL=C

command -v jq >/dev/null 2>&1 || exit 0
# shellcheck source=../scripts/lib/common.sh
. "$(CDPATH='' cd "$(dirname "$0")" && pwd)/../scripts/lib/common.sh"
# shellcheck source=../scripts/lib/git-command.sh
. "$DW_SCRIPTS_DIR/lib/git-command.sh"

input="$(cat)"
cmd="$(jq -r '.tool_input.command // empty' <<<"$input")"
# 関係のないコマンドは解析しない（Bash を使うたびに呼ばれるので速く抜ける）
case "$cmd" in
  *git* | *"gh "* | *commit.sh* | *task-start.sh* | *pr-create.sh* | *issue-create.sh*) ;;
  *) exit 0 ;;
esac

# コマンドの文字列が <正規表現> に当たるか
has() { printf '%s' "$cmd" | grep -Eq -- "$1"; }

# ファイル名の展開（*・?）は要らないので止める（出力の URL を空白で分けるときに、展開されないようにする）
set -f

created=false
{ has "(^|[^[:alnum:]_./-])gh( [^;&|]*)? (pr|issue) create([^[:alnum:]_-]|\$)" || has '(pr|issue)-create\.sh'; } && created=true

# フックの入力の cwd は、コマンドを実行した後の Claude Code のディレクトリ（外側の cd で移った先。
# プロジェクトの外へ移ったときは、Claude Code が戻した先（プロジェクトのルート。$CLAUDE_PROJECT_DIR））
cwd="$(jq -r '.cwd // empty' <<<"$input")"
dir="$( (CDPATH='' cd "${cwd:-.}" && pwd -P) 2>/dev/null || true)"
project_dir=""
[ -z "${CLAUDE_PROJECT_DIR:-}" ] || project_dir="$( (CDPATH='' cd "$CLAUDE_PROJECT_DIR" && pwd -P) 2>/dev/null || true)"

# 操作ごとの対象を、同じ添え字で持つ
#   ev_kind    push・commit・created（PR・Issue を作った）・create（ブランチを作る）
#   ev_repo    操作の対象のリポジトリ（gc_repo。ワークツリーなら元のリポジトリ）
#   ev_root    操作の対象の作業ツリーの一番上（gc_root）
#   ev_branch  create は作るブランチの名前、ほかは対象の今のブランチ
#   ev_issue   ev_branch の Issue の番号（Issue のリンクを足すときに入れる）
ev_kind=() ev_repo=() ev_root=() ev_branch=() ev_issue=()
add_event() {
  ev_kind+=("$1")
  ev_repo+=("$gc_repo")
  ev_root+=("$gc_root")
  ev_branch+=("$2")
  ev_issue+=("")
}

# 作るブランチの名前を覚える（gc_new_branches・gc_worktree_branch のコールバック）
new_names=()
add_new_name() { new_names+=("$1"); }

# git の呼び出しを1つ調べ、push・commit・ブランチの作成なら、対象のリポジトリとブランチを覚える（gc_scan のコールバック）。
# git stash push や git log --grep commit は、サブコマンドが違うので当たらない。
# ブランチを作るコマンドの名前は、guard-git.sh と同じ書き方（-cname なども）で拾う。-b・-B の無い git worktree add は、
# 2つ目の位置引数（git worktree add <パス> <ブランチ>）を名前にする。commit-ish を書かない git worktree add <パス> は、
# パスの最後の名前にする。git switch・checkout が作る追跡ブランチ（gc_tracking_branches）は、候補の名前が、リモートにあり、
# 手元にあり、今作られた（reflog が「branch: Created from …」の 1 行だけ）ときに拾う
# 使い方: on_git <サブコマンド> <引数>...
on_git() {
  local sub="$1" k tracking=false
  shift
  new_names=()
  case "$sub" in
    push)
      # git push -n（--dry-run。-nu のようにまとめた書き方を含む）は push しない
      gc_push_args "$@"
      ! $gc_push_dry || return 0
      ;;
    commit)
      # git commit --dry-run（略した形も）は commit しない
      gc_commit_args "$@"
      ! $gc_commit_dry || return 0
      ;;
    switch | checkout | branch | worktree)
      gc_new_branches add_new_name "$sub" "$@"
      if [ "$sub" = worktree ] && [ "${1:-}" = add ] && [ "${#new_names[@]}" -eq 0 ]; then
        shift
        gc_worktree_branch add_new_name "$@"
      fi
      # 手元に無いブランチへの switch・checkout は、リモートに同じ名前があれば、追跡ブランチを作る（確かめるのは下）
      if [ "${#new_names[@]}" -eq 0 ] && { [ "$sub" = switch ] || [ "$sub" = checkout ]; }; then
        gc_tracking_branches add_new_name "$sub" "$@"
        tracking=true
      fi
      [ "${#new_names[@]}" -gt 0 ] || return 0
      ;;
    *) return 0 ;;
  esac
  # 操作の対象を求める（--git-dir・GIT_DIR などで指したときも、guard-git.sh と同じ求め方）。作業ツリーが分からなければ出さない
  gc_target
  [ -n "$gc_root" ] || return 0
  case "$sub" in
    push | commit) add_event "$sub" "$(gc_branch)" ;;
    *)
      for k in "${new_names[@]}"; do
        # 追跡ブランチの候補は、リモートにあり、手元にあって、今作られたものだけ（前からある手元のブランチは、ただの切り替え。
        # 手元に無ければ、コマンドが失敗したか、ブランチの名前でなかった）。このフックはコマンドの後に動くので、
        # 作られたブランチは手元にあり、reflog で今作ったかを見る
        if $tracking; then
          gc_git show-ref --verify --quiet "refs/heads/$k" || continue
          gc_just_created "$k" || continue
          gc_remote_has "$k" || continue
        fi
        add_event create "$k"
      done
      ;;
  esac
}
gc_scan on_git "$cmd" "$dir" after "$project_dir"

# スクリプトの中の git は、コマンドの文字列に現れないので、名前で拾う（cwd のリポジトリ・ブランチで判断する）
task_start=false
has 'task-start\.sh' && task_start=true
script_push=false script_commit=false
has 'pr-create\.sh' && script_push=true
has 'commit\.sh' && script_commit=true
# --dry-run を付けたスクリプトと gh pr create は、push も commit も PR・Issue の作成もしないので、それらのリンクは出さない。
# 名前で拾うのと同じく、コマンドの文字列で調べる（引用符の中（コミットメッセージなど）の --dry-run は、取り除いてから調べる）。
# git push・git commit の --dry-run は、on_git が git の呼び出しごとに調べる
if printf '%s' "$cmd" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g" | grep -Eq '(^|[[:space:]])--dry-run([[:space:]=]|$)'; then
  task_start=false script_push=false script_commit=false created=false
fi
cwd_root="" cwd_repo=""
if $created || $task_start || $script_push || $script_commit; then
  gc_git_dir="$dir" gc_gopts=() gc_genv=()
  gc_target
  cwd_root="$gc_root" cwd_repo="$gc_repo"
  if [ -n "$cwd_root" ]; then
    cwd_branch="$(gc_branch)"
    ! $script_push || add_event push "$cwd_branch"
    ! $script_commit || add_event commit "$cwd_branch"
    # 作った PR・Issue の Issue は、cwd のブランチのもの
    ! $created || add_event created "$cwd_branch"
  fi
fi

[ "${#ev_kind[@]}" -gt 0 ] || $task_start || exit 0

# コマンドの標準出力（標準エラーは見ない。警告などが混ざるので）
stdout="$(jq -r '.tool_response | if type == "object" then (.stdout // "") else (. // "" | tostring) end' <<<"$input" 2>/dev/null || true)"

links=()
add_link() {
  local l
  for l in ${links[@]+"${links[@]}"}; do
    [ "$l" != "$2: $1" ] || return 0
  done
  links+=("$2: $1")
}

# --- 作った PR・Issue（標準出力から拾う）-------------------------------------------
# スクリプトの出力の JSON は、作ったものの URL を url（issue-create.sh）か pr.url（pr-create.sh）に持つ（body などの別の URL は拾わない）。
# gh pr create・gh issue create は、URL だけの行を出す。導入していないリポジトリ（cwd）では出さない
if $created && dw_is_set_up "$cwd_root"; then
  for u in $( { jq -r 'objects | (.url // .pr.url // empty)' <<<"$stdout" 2>/dev/null || true
    printf '%s\n' "$stdout" | grep -E '^https://[^[:space:]]+/(pull|issues)/[0-9]+[[:space:]]*$' || true; } | awk '!seen[$0]++'); do
    case "$u" in
      */pull/*) add_link "$u" "PR" ;;
      */issues/*) add_link "$u" "Issue" ;;
    esac
  done
fi

# --- ブランチから導くリンク ----------------------------------------------------------
# リポジトリのルートの設定を読む（直前に読んだルートと同じなら読み直さない）。使い方: load_config <ルート>
config_root="" config=""
load_config() {
  [ "$1" != "$config_root" ] || return 0
  config_root="$1"
  config="$( (CDPATH='' cd "$1" && WORKFLOW_REPO_ROOT="$1" "$BASH" "$DW_SCRIPTS_DIR/config.sh") 2>/dev/null || true)"
}
# ブランチ名を、そのリポジトリの branch.pattern に当てて、Issue の番号を issue に入れる（無ければ空）。
# 設定の読み込みを使い回すため、$( ) の中では呼ばない。使い方: issue_of <ルート> <ブランチ名>
issue=""
issue_of() {
  local parsed
  issue=""
  [ -n "$2" ] || return 0
  load_config "$1"
  [ -n "$config" ] || return 0
  # branch.pattern などの設定に誤り（正規表現として正しくない・文字列でない・labels.types が正しくないなど）があっても、フックは止めず Issue なしとして扱う（ツールの実行を妨げないため。
  # 他のスクリプトのように設定の誤りとして終了コード 2 で止めることはしない）
  parsed="$(dw_parse_branch "$config" "$2" 2>/dev/null || true)"
  issue="${parsed#*|}"
}
# Issue のリンクを足す。同じリポジトリ（別のワークツリーを含む）の同じ Issue は、1回だけ調べる。
# 使い方: add_issue <リポジトリ> <ルート> <番号>
seen_issues=()
add_issue() {
  local url s
  [ -n "$3" ] || return 0
  for s in ${seen_issues[@]+"${seen_issues[@]}"}; do
    [ "$s" != "$1|$3" ] || return 0
  done
  seen_issues+=("$1|$3")
  url="$( (CDPATH='' cd "$2" && gh issue view "$3" --json url -q .url) 2>/dev/null || true)"
  [ -z "$url" ] || add_link "$url" "Issue #${3}"
}

# 出す Issue のリンク。操作ごとに、対象の Issue が違う。導入していないリポジトリへの操作は飛ばす
#   - push・commit・PR や Issue を作る操作：対象のリポジトリの今のブランチの Issue
#   - ブランチを作るコマンド：作るブランチの Issue（名前が拾えない・Issue の番号が無いときは出さない。間違った Issue より、何も出さないほうがよい）
#   - task-start.sh：標準出力の JSON の issue（別のワークツリーを作るので。標準エラーの警告（warn:）が混ざっても読める。取れなければ出さない）
# 今のブランチの Issue を先に、作るブランチの Issue を後に並べる
for pass in current create; do
  for ((k = 0; k < ${#ev_kind[@]}; k++)); do
    if [ "${ev_kind[k]}" = create ]; then
      [ "$pass" = create ] || continue
    else
      [ "$pass" = current ] || continue
    fi
    dw_is_set_up "${ev_root[k]}" || continue
    issue_of "${ev_root[k]}" "${ev_branch[k]}"
    ev_issue[k]="$issue"
    add_issue "${ev_repo[k]}" "${ev_root[k]}" "$issue"
  done
done
if $task_start && dw_is_set_up "$cwd_root"; then
  n="$(jq -r 'objects | .issue // empty' <<<"$stdout" 2>/dev/null | head -n 1 || true)"
  case "$n" in '' | *[!0-9]*) ;; *) add_issue "$cwd_repo" "$cwd_root" "$n" ;; esac
fi

# push の PR・CI は、push したリポジトリの今のブランチのもの（Issue が分からないブランチでは出さない）。
# 同じブランチへの push は、1回だけ調べる
pushed=()
for ((k = 0; k < ${#ev_kind[@]}; k++)); do
  [ "${ev_kind[k]}" = push ] || continue
  root="${ev_root[k]}" branch="${ev_branch[k]}"
  [ -n "$branch" ] || continue
  dup=false
  for p in ${pushed[@]+"${pushed[@]}"}; do
    [ "$p" != "$root|$branch" ] || dup=true
  done
  ! $dup || continue
  pushed+=("$root|$branch")
  # Issue のリンクを足すときに求めた番号を使う（導入していないリポジトリでは空）
  [ -n "${ev_issue[k]}" ] || continue
  # gh pr list が失敗したときは、PR が無いのか分からないので、PR・CI のリンクは出さない（Issue のリンクは出す）
  if pr="$( (CDPATH='' cd "$root" && gh pr list --head "$branch" --state open --json url,isCrossRepository \
    -q 'map(select(.isCrossRepository | not)) | .[0].url // empty') 2>/dev/null)"; then
    if [ -n "$pr" ]; then
      add_link "$pr" "PR"
      add_link "$pr/checks" "CI"
    else
      repo="$( (CDPATH='' cd "$root" && gh repo view --json url -q .url) 2>/dev/null || true)"
      if [ -n "$repo" ]; then
        add_link "$repo/pull/new/$branch" "PR を作る"
        add_link "$repo/actions?query=branch%3A$(printf '%s' "$branch" | sed 's|/|%2F|g')" "CI"
      fi
    fi
  fi
done

[ "${#links[@]}" -gt 0 ] || exit 0

msg="関連するリンク:"
for l in "${links[@]}"; do
  msg="${msg}
- ${l}"
done
ctx="${msg}
返答でも、これらのリンクに触れてください。"
jq -n --arg m "$msg" --arg c "$ctx" \
  '{systemMessage: $m, hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
exit 0
