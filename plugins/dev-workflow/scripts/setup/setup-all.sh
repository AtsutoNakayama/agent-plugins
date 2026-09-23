#!/usr/bin/env bash
# リポジトリの初期設定をまとめて行う。今いるリポジトリが対象。何度実行しても同じ結果になる。
#
# 使い方: setup-all.sh [オプション]
#   --keep-defaults         GitHub の既定のラベルを削除しない
#   --number N              既存の Project に接続する
#   --title TITLE           Project の名前で探し、無ければその名前で作る（既定: リポジトリ名）
#   --require-approval N    マージに必要な承認の数（既定: 今の値のまま。新しく作るときは 0）
#   --dry-run               変更せず、行う予定の操作だけを出力する
#
# 行うこと:
#   1. setup-labels.sh：type ラベルの登録
#   2. setup-project.sh --write-config：Project の作成・接続と、.claude/workflow.json への書き込み
#   3. setup-repo.sh：マージ方法の設定と、ルールセットの登録
#   4. PR テンプレート（.github/pull_request_template.md）と Issue テンプレート
#      （.github/ISSUE_TEMPLATE/task.md）を作る。既にテンプレートがあれば作らない
# 作ったファイルはコミットしない。マージ先のブランチは守られているので、PR でマージする。
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
dw_require jq git

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

labels_args=() project_args=() repo_args=() dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --number | --title)
      need_value "$@"
      project_args+=("$1" "$2")
      shift 2
      ;;
    --require-approval)
      need_value "$@"
      repo_args+=("$1" "$2")
      shift 2
      ;;
    --keep-defaults) labels_args+=("$1"); shift ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
cd "$repo_root"
setup_dir="$DW_SCRIPTS_DIR/setup"

# 3つを順に実行し、それぞれの出力を labels・project・repo に入れる。引数は dry-run のときに足すもの
# if の条件の中でも最初の失敗で止まるよう、set -e に頼らず || return で返す
# bash 3.2 では空の配列を "${a[@]}" で展開すると set -u で止まるので、${a[@]+"${a[@]}"} と書く
run_steps() {
  labels="$("$BASH" "$setup_dir/setup-labels.sh" ${labels_args[@]+"${labels_args[@]}"} "$@")" || return
  project="$("$BASH" "$setup_dir/setup-project.sh" --write-config ${project_args[@]+"${project_args[@]}"} "$@")" || return
  repo="$("$BASH" "$setup_dir/setup-repo.sh" ${repo_args[@]+"${repo_args[@]}"} "$@")" || return
}
if $dry_run; then
  run_steps --dry-run
else
  # 途中で失敗して一部だけ変わらないよう、先に3つとも dry-run で通ることを確かめる
  # （例：非公開のリポジトリで、プランによってルールセットを使えない）。警告は本番で出るので、失敗したときだけ表示する
  if ! preflight="$(run_steps --dry-run 2>&1)"; then
    printf '%s\n' "$preflight" >&2
    dw_die "確認（dry-run）で失敗したので、何も変更していません"
  fi
  # git に無視されていると git status に出ないので、変わったかどうかは中身で比べる
  config_before="$(cat .claude/workflow.json 2>/dev/null || true)"
  run_steps
fi

# --- テンプレート ---------------------------------------------------------------
config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh")"
created='[]' skipped='[]'
# 使い方: place <テンプレート> <置き場所> <設定で分かっている既存のもの（空なら無い）>
# 設定はチームの層で null に上書きできるので、置き場所に実際にファイルがあるかも確かめ、上書きしない
place() {
  local existing="$3"
  [ -n "$existing" ] || existing="$(dw_find_nocase . "$2" || true)"
  if [ -n "$existing" ]; then
    skipped="$(jq -c --arg p "$2" --arg e "$existing" '. + [{path: $p, existing: $e}]' <<<"$skipped")"
    return
  fi
  created="$(jq -c --arg p "$2" '. + [$p]' <<<"$created")"
  if ! $dry_run; then
    mkdir -p "$(dirname "$2")"
    cp "$DW_PLUGIN_ROOT/templates/$1" "$2"
  fi
}
place pull_request_template.md .github/pull_request_template.md \
  "$(jq -r '.pr.template // .detected.pr_templates // empty' <<<"$config")"
place ISSUE_TEMPLATE/task.md .github/ISSUE_TEMPLATE/task.md "$(jq -r '.detected.issue_templates // empty' <<<"$config")"

# --- 次にやること ---------------------------------------------------------------
# コミットが必要なファイル（dry-run では作る予定のもの）
files="$created"
if $dry_run; then
  # 書き込む予定の project と今のファイルが違えば、変わる予定とみなす。
  # Project を新しく作る予定なら番号はまだ無いので必ず変わり、未コミットのファイルもコミットが要る
  config_changes=true
  if [ -f .claude/workflow.json ] \
    && [ "$(jq -r '.project.created' <<<"$project")" != true ] \
    && [ -z "$(git status --porcelain -- .claude/workflow.json)" ] \
    && jq -e --argjson p "$project" \
      '.project.owner == $p.project.owner and .project.number == $p.project.number' .claude/workflow.json >/dev/null 2>&1; then
    config_changes=false
  fi
else
  config_changes=false
  if [ "$(cat .claude/workflow.json 2>/dev/null || true)" != "$config_before" ] \
    || [ -n "$(git status --porcelain -- .claude/workflow.json)" ]; then
    config_changes=true
  fi
fi
if $config_changes; then
  files="$(jq -c '. + [".claude/workflow.json"]' <<<"$files")"
fi
# git に無視されているファイルはコミットできないので、.gitignore を直すよう伝える
ignored='[]'
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if git check-ignore -q -- "$f"; then
    ignored="$(jq -c --arg f "$f" '. + [$f]' <<<"$ignored")"
  fi
done <<<"$(jq -r '.[]' <<<"$files")"
next='[]'
if [ "$files" != "[]" ]; then
  next="$(jq -c --argjson f "$files" --arg b "$(jq -r .branch <<<"$repo")" \
    '. + ["\($f | join("・")) をコミットし、PR で \($b) にマージする"]' <<<"$next")"
fi
if [ "$ignored" != "[]" ]; then
  dw_warn "git に無視されているのでコミットできません: $(jq -r 'join(", ")' <<<"$ignored")"
  next="$(jq -c --argjson f "$ignored" \
    '. + ["\($f | join("・")) が git に無視されているので、.gitignore で無視を外す（例：.claude/ を .claude/* に変えて !.claude/workflow.json を足す）"]' <<<"$next")"
fi
if [ "$(jq -r .workflows.auto_add <<<"$project")" = false ]; then
  next="$(jq -c --arg u "$(jq -r .workflows.url <<<"$project")" \
    '. + ["自動追加（Auto-add to project）を \($u) で有効にする"]' <<<"$next")"
fi

jq -n --argjson dry "$dry_run" --argjson labels "$labels" --argjson project "$project" --argjson repo "$repo" \
  --argjson created "$created" --argjson skipped "$skipped" --argjson next "$next" '{
    dry_run: $dry,
    labels: $labels,
    project: $project,
    repo: $repo,
    templates: {created: $created, skipped: $skipped},
    next_steps: $next
  }'
