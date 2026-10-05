#!/usr/bin/env bash
# Issue の作業を始める。ワークツリーとブランチを作り（--no-worktree では作らず）、Issue を自分に割り当て、Project の start の列に移す。
# 何度実行しても同じ結果になる（既にあるワークツリー・ブランチ・割り当ては使い回す）。
#
# 使い方: task-start.sh --issue N (--slug TEXT | --no-worktree) [--dry-run]
#   --issue N        Issue の番号（#N でもよい）
#   --slug TEXT      ブランチ名の短い説明（英語）。branch-name.sh で整える
#   --no-worktree    リポジトリを変えないタスク（調査・Issue の整理など）。1 と 2 を飛ばし、
#                    割り当てと列の移動だけを行う（branch と worktree は null）。
#                    後からリポジトリを変えることになったら、--slug を付けてもう一度実行すれば作れる
#   --dry-run        変更せず、行う予定の操作だけを出力する
#
# 親の Issue（サブ Issue を持つ Issue）は作業の単位ではないので、何もせずに止まる（終了コード 2）。作業は子の Issue で進める。
#
# 行うこと:
#   1. ブランチ名を決める（branch.pattern に従う。既定は {type}/{issue_number}-{slug}）
#   2. <branch.worktree_dir>/<ブランチ名> にワークツリーを作る（相対パスはメインのワークツリーから）。
#      ブランチが無ければ、origin に push 済みならそこから、無ければ origin/<base_branch> から作る。
#      ワークツリーの置き場所が git に無視されていなければ、.git/info/exclude に足す（コミットしない手元だけの設定）。
#      .gitmodules があれば、サブモジュールを初期化する（git submodule update --init --recursive）。
#      失敗しても（通信できないなど）止めずに警告する。既にあるワークツリーでも、未初期化なら初期化し直す
#   3. Issue を自分に割り当てる
#   4. Project の Status を start の列に移す（status-set.sh）。project.number が未設定なら警告して飛ばす
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
dw_require gh jq git

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

issue="" slug="" dry_run=false no_worktree=false
while [ $# -gt 0 ]; do
  case "$1" in
    --issue | --slug)
      need_value "$@"
      case "$1" in
        --issue) issue="$2" ;;
        --slug) slug="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    --no-worktree) no_worktree=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
[ -n "$issue" ] || dw_die "--issue は必須です" 64
# スキルの引数の #12 も受ける（dw_issue_number）
issue="$(dw_issue_number --issue "$issue")"
if $no_worktree; then
  [ -z "$slug" ] || dw_die "--no-worktree と --slug は一緒に指定できません" 64
else
  [ -n "$slug" ] || dw_die "--slug は必須です（ワークツリーを作らないときは --no-worktree）" 64
fi

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
main_root="$(dw_main_root "$repo_root")" || dw_die "メインのワークツリーが分かりません"
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
base="$(jq -r '.base_branch' <<<"$config")"
worktree_dir="$(jq -r '.branch.worktree_dir' <<<"$config")"

actions='[]'
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# --- Issue ----------------------------------------------------------------------
issue_json="$(gh issue view "$issue" --json number,title,state,assignees,subIssuesSummary)"
[ "$(jq -r .state <<<"$issue_json")" = OPEN ] || dw_die "Issue #${issue} は閉じています" 2
# 親の Issue は子をまとめるだけで、親そのものの作業は無い（設計書 §4）。ブランチ・割り当て・列の移動のどれも行わない
sub_total="$(jq -r '.subIssuesSummary.total // 0' <<<"$issue_json")"
[ "$sub_total" -eq 0 ] \
  || dw_die "Issue #${issue} は親の Issue（子の Issue が ${sub_total} 件）なので、着手しません。子の Issue に着手してください" 2
title="$(jq -r .title <<<"$issue_json")"

# リポジトリを変えないタスク（--no-worktree）では、ブランチもワークツリーも作らない
branch="" path="" worktree_created=false branch_created=false
if ! $no_worktree; then
  # --- 1. ブランチ名 --------------------------------------------------------------
  branch="$("$BASH" "$DW_SCRIPTS_DIR/branch-name.sh" --issue "$issue" --slug "$slug" | jq -r .branch)"
  # 置き場所が絶対パスならそのまま、相対パスならメインのワークツリーから
  case "$worktree_dir" in
    /*) path="${worktree_dir%/}/$branch" ;;
    *) path="$main_root/$worktree_dir/$branch" ;;
  esac

  # --- 2. ワークツリーとブランチ --------------------------------------------------
  # そのブランチのワークツリーが既にあれば使い回す
  existing="$(dw_worktree_of "$main_root" "$branch")"
  src_ref=""  # 新しく作るワークツリーの中身の元（dry-run で .gitmodules の有無を見る）
  # ディレクトリを手で消すと、git の記録だけが残る。記録を片付けてから作り直す
  if [ -n "$existing" ] && [ ! -d "$existing" ]; then
    note "消えたワークツリー $existing の記録を片付ける（git worktree prune）"
    $dry_run || git -C "$main_root" worktree prune
    existing=""
  fi
  if [ -n "$existing" ]; then
    path="$existing"
  else
    worktree_created=true
    if git -C "$main_root" show-ref --verify --quiet "refs/heads/$branch"; then
      src_ref="$branch"
      note "既にあるブランチ ${branch} のワークツリーを $path に作る"
      $dry_run || git -C "$main_root" worktree add -q "$path" "$branch"
    elif [ -n "$(git -C "$main_root" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null)" ]; then
      # 別のマシンで push 済み（またはローカルだけ消した）ブランチは、push 済みのコミットから続ける
      branch_created=true
      src_ref="origin/$branch"
      note "push 済みの origin/${branch} からブランチ ${branch} を作り、ワークツリーを $path に作る"
      if ! $dry_run; then
        git -C "$main_root" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" \
          || dw_die "origin/${branch} を取得できませんでした"
        git -C "$main_root" worktree add -q --track -b "$branch" "$path" "origin/$branch"
      fi
    else
      branch_created=true
      src_ref="origin/$base"
      note "origin/${base} からブランチ ${branch} を作り、ワークツリーを $path に作る"
      if ! $dry_run; then
        git -C "$main_root" fetch -q origin "$base" || dw_die "origin/${base} を取得できませんでした"
        # origin/<base> を追跡させない（追跡すると git push の先が base になりうる。push 先は pr-create で決める）
        git -C "$main_root" worktree add -q --no-track -b "$branch" "$path" "origin/$base"
      fi
    fi
  fi

  # ワークツリーの置き場所がメインのワークツリーの中なら、未追跡のファイルとして見えないよう手元だけで無視する
  case "$worktree_dir" in
    /* | ../* | ..) ;;
    *)
      if ! git -C "$main_root" check-ignore -q "$worktree_dir/x"; then
        exclude="$(git -C "$main_root" rev-parse --git-common-dir)/info/exclude"
        case "$exclude" in /*) ;; *) exclude="$main_root/$exclude" ;; esac
        note "${worktree_dir}/ を $exclude に足す（手元だけで git に無視させる）"
        if ! $dry_run; then
          mkdir -p "$(dirname "$exclude")"
          printf '%s/\n' "${worktree_dir%/}" >>"$exclude"
        fi
      fi
      ;;
  esac

  # サブモジュール（テスト用のライブラリなど）は、ワークツリーを作っただけでは空のまま
  submodules=false
  if $worktree_created && $dry_run; then
    # まだワークツリーが無いので、中身の元で見る。dry-run では fetch しないので、元が手元に無い・古いこともある。
    # そのときに予定から漏れないよう、メインのワークツリーに .gitmodules があれば予定に出す
    if git -C "$main_root" cat-file -e "${src_ref}:.gitmodules" 2>/dev/null || [ -f "$main_root/.gitmodules" ]; then
      submodules=true
    fi
  elif [ -f "$path/.gitmodules" ]; then
    # 新しく作ったワークツリーなら必ず、既にあるワークツリーなら未初期化のもの（入れ子も含む）があれば初期化する
    if $worktree_created || git -C "$path" submodule status --recursive 2>/dev/null | grep -q '^-'; then
      submodules=true
    fi
  fi
  if $submodules; then
    note "ワークツリーのサブモジュールを初期化する（git submodule update --init --recursive）"
    # 出力は JSON だけにするため、git の出力は標準エラーに回す
    if ! $dry_run && ! git -C "$path" submodule update -q --init --recursive >&2; then
      dw_warn "サブモジュールを初期化できませんでした。ワークツリーで git submodule update --init --recursive を実行してください（cd ${path}）"
    fi
  fi
fi

# --- 3. 自分に割り当てる --------------------------------------------------------
me="$(gh api user -q .login)"
assigned=false
if ! jq -e --arg m "$me" 'any(.assignees[]; .login == $m)' <<<"$issue_json" >/dev/null; then
  assigned=true
  note "Issue #${issue} を ${me} に割り当てる"
  $dry_run || gh issue edit "$issue" --add-assignee @me >/dev/null || dw_die "Issue #${issue} を割り当てられませんでした"
fi

# --- 4. start の列に移す --------------------------------------------------------
# Project が未設定なら、列の移動だけ飛ばす（issue-create.sh と同じく、Project なしでも使えるようにする）
if [ -z "$(jq -r '.project.number // empty' <<<"$config")" ]; then
  dw_warn "project.number が未設定なので、Project の列は移しません（setup-project.sh --write-config で設定できます）"
  status='{"skipped": true, "actions": []}'
else
  status_args=(--issue "$issue" --to start)
  $dry_run && status_args+=(--dry-run)
  status="$("$BASH" "$DW_SCRIPTS_DIR/status-set.sh" "${status_args[@]}")"
fi
while IFS= read -r a; do
  [ -n "$a" ] && note "$a"
done <<<"$(jq -r '.actions[]?' <<<"$status")"

jq -n --argjson i "$issue" --arg title "$title" --arg branch "$branch" --arg path "$path" --arg base "$base" \
  --argjson wc "$worktree_created" --argjson bc "$branch_created" --argjson assigned "$assigned" \
  --argjson status "$status" --argjson dry "$dry_run" --argjson actions "$actions" '{
    issue: $i,
    title: $title,
    dry_run: $dry,
    branch: (if $branch == "" then null else $branch end),
    worktree: (if $path == "" then null else $path end),
    base: $base,
    created: {worktree: $wc, branch: $bc},
    assigned: $assigned,
    status: {from: $status.from, to: ($status.to // null), skipped: ($status.skipped // false)},
    actions: $actions
  }'
