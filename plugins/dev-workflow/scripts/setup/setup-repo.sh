#!/usr/bin/env bash
# リポジトリのマージ方法を設定し、マージ先のブランチを守るルールセットを登録する。何度実行しても同じ結果になる。
#
# 使い方: setup-repo.sh [オプション]
#   --repo OWNER/NAME       対象のリポジトリ（既定: 今いるリポジトリ）
#   --require-approval N    マージに必要な承認の数（0〜10。既定: 今の値のまま。新しく作るときは 0）
#   --dry-run               変更せず、行う予定の操作だけを出力する
#
# 行うこと:
#   1. マージ方法：スカッシュのみ許可（コミットのタイトルは PR タイトル、本文は PR 本文）、
#      マージしたブランチを自動で削除する
#   2. ルールセット「dev-workflow」：設定の base_branch への直接 push を禁止して PR を必須にし、
#      強制 push と削除を禁止する。管理者も例外にしない
#      このスクリプトが扱わないルール（必須のステータスチェックなど）は残す
# リポジトリの管理者権限が必要（dry-run でも確かめる）。守るブランチがリポジトリに無ければ止める。
# 守るブランチは、チームの設定（.claude/workflow.json）の base_branch で決める（個人の設定は使わない）。
# --repo が今いるリポジトリと違うときは、対象のリポジトリの .claude/workflow.json を API で読む。
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
dw_require gh jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

# オプションの値を取り出す。無ければ使い方の誤り（64）で終了する
need_value() {
  if [ $# -lt 2 ] || [ -z "$2" ]; then
    dw_die "$1 に値がありません" 64
  fi
}

RULESET_NAME="dev-workflow"
# スクリプトが揃えるリポジトリの設定
SETTINGS='{
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "allow_rebase_merge": false,
  "delete_branch_on_merge": true,
  "squash_merge_commit_title": "PR_TITLE",
  "squash_merge_commit_message": "PR_BODY"
}'

repo="" approvals="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --repo | --require-approval)
      need_value "$@"
      case "$1" in
        --repo) repo="$2" ;;
        --require-approval) approvals="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done
case "$approvals" in
  *[!0-9]*) dw_die "--require-approval には数字を指定してください: $approvals" 64 ;;
esac
# GitHub が受け付ける範囲。dry-run で確かめられるよう、API に送る前に調べる
if [ -n "$approvals" ] && [ "$approvals" -gt 10 ]; then
  dw_die "--require-approval は 0〜10 で指定してください: $approvals" 64
fi

repo_nwo="$(gh repo view ${repo:+"$repo"} --json nameWithOwner -q .nameWithOwner)"
here_nwo=""
if [ -n "$repo" ]; then
  here_nwo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi

# --- 守るブランチ（設定の base_branch） ------------------------------------------
# ルールセットはリポジトリ全体で共有するので、個人の層（workflow.local.json・~/.claude/workflow）は使わず、
# チームの設定（.claude/workflow.json）とプラグインの既定だけで決める
branch="$(jq -r '.base_branch' "$DW_PLUGIN_ROOT/defaults/workflow.json")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
team=""
if [ -z "$repo" ] || [ "$here_nwo" = "$repo_nwo" ]; then
  repo_root="$(dw_repo_root || true)"
  if [ -n "$repo_root" ] && [ -f "$repo_root/.claude/workflow.json" ]; then
    team="$repo_root/.claude/workflow.json"
  fi
elif dw_fetch_repo_file "$repo_nwo" .claude/workflow.json "$tmp/workflow.json"; then
  # 別のリポジトリでは、そのリポジトリの既定のブランチにある設定を読む
  team="$tmp/workflow.json"
fi
if [ -n "$team" ]; then
  branch="$(jq -r --arg d "$branch" '.base_branch // $d' "$team" 2>/dev/null)" \
    || dw_die "${repo_nwo} の .claude/workflow.json を JSON として読めません" 2
fi
[ -n "$branch" ] || dw_die "設定の base_branch が空です" 2

actions='[]'
# 行った（または dry-run で行う予定の）操作を記録する
note() { actions="$(jq -c --arg a "$1" '. + [$a]' <<<"$actions")"; }

# 読み取りの API。失敗したら GitHub の理由を伝えて止める
# （例：非公開のリポジトリで、プランによってルールセットを使えない）
get() {
  local out
  out="$(gh api "$@" 2>&1)" || dw_die "gh api ${*} に失敗しました: $out"
  printf '%s\n' "$out"
}

# 変更を伴う API の呼び出し。本文は JSON を標準入力から渡す。dry-run では呼ばずに null を返す
# 使い方: mutate <メソッド> <パス> <本文の JSON>
mutate() {
  local out
  if $dry_run; then
    echo null
    return
  fi
  # 非公開のリポジトリでは、プランによってルールセットを使えない。GitHub の理由をそのまま伝える
  out="$(gh api -X "$1" "$2" --input - <<<"$3" 2>&1)" || dw_die "$1 $2 に失敗しました: $out"
  printf '%s\n' "$out"
}

current="$(get "repos/$repo_nwo")"
# 設定の変更には管理者権限が要る。dry-run でも確かめ、setup-all.sh が途中で止まらないようにする
[ "$(jq -r '.permissions.admin // false' <<<"$current")" = true ] \
  || dw_die "${repo_nwo} の管理者権限が必要です（マージ方法とルールセットの変更のため）" 77

# 無いブランチを守っても意味がないので止める。既定のブランチと違うだけなら、意図した運用かもしれないので警告にとどめる
default_branch="$(jq -r .default_branch <<<"$current")"
if [ "$branch" != "$default_branch" ]; then
  if ! out="$(gh api "repos/$repo_nwo/branches/$(jq -rn --arg b "$branch" '$b | @uri')" 2>&1)"; then
    case "$out" in
      *"HTTP 404"*) dw_die "守るブランチ ${branch} が ${repo_nwo} にありません（既定のブランチは ${default_branch}）。.claude/workflow.json の base_branch を設定してください" 2 ;;
      *) dw_die "ブランチ ${branch} を確かめられません: $out" ;;
    esac
  fi
  dw_warn "守るブランチ ${branch} は、リポジトリの既定のブランチ（${default_branch}）と違います"
fi

# --- 1. マージ方法 --------------------------------------------------------------
changed="$(jq -nc --argjson want "$SETTINGS" --argjson cur "$current" \
  '[$want | to_entries[] | select(.value != $cur[.key]) | .key]')"
if [ "$changed" != "[]" ]; then
  note "マージ方法をスカッシュのみにし、マージしたブランチを自動で削除する（$(jq -r 'join(", ")' <<<"$changed")）"
  # 違う項目だけを送る。ただし GitHub はスカッシュのタイトルと本文を組で求める（本文だけだと 422）ので、片方が違えば両方送る
  mutate PATCH "repos/$repo_nwo" "$(jq -c --argjson c "$changed" '
    ["squash_merge_commit_title", "squash_merge_commit_message"] as $pair
    | (if any($c[]; . as $k | $pair | index($k)) then $c + $pair else $c end) as $send
    | with_entries(select(.key as $k | $send | index($k)))' <<<"$SETTINGS")" >/dev/null
fi

# --- 2. ルールセット ------------------------------------------------------------
# 組織のルールセットも返るので、このリポジトリのものだけを名前で探す。--paginate はページごとに配列を出力する
rulesets="$(get --paginate "repos/$repo_nwo/rulesets?per_page=100")"
ruleset_id="$(jq -rs --arg n "$RULESET_NAME" \
  '[.[][] | select(.name == $n and .source_type == "Repository")][0].id // empty' <<<"$rulesets")"
existing='null'
if [ -n "$ruleset_id" ]; then
  existing="$(get "repos/$repo_nwo/rulesets/$ruleset_id")"
fi

# 既存の pull_request の設定は残し、承認の数（指定されたときだけ）とマージ方法を揃える
desired="$(jq -n --argjson ex "$existing" --arg name "$RULESET_NAME" --arg ref "refs/heads/$branch" \
  --arg n "$approvals" '
  ([($ex // {}).rules // [] | .[] | select(.type == "pull_request")][0].parameters // {}) as $old
  | ["deletion", "non_fast_forward", "pull_request"] as $managed
  | {
      name: $name,
      target: "branch",
      enforcement: "active",
      bypass_actors: [],
      conditions: {ref_name: {include: [$ref], exclude: []}},
      rules: (
        [($ex // {}).rules // [] | .[] | select(.type as $t | $managed | index($t) | not)]
        + [{type: "deletion"}, {type: "non_fast_forward"},
           {type: "pull_request", parameters: ({
              dismiss_stale_reviews_on_push: false,
              require_code_owner_review: false,
              require_last_push_approval: false,
              required_approving_review_count: 0,
              required_review_thread_resolution: false
            } + $old + {allowed_merge_methods: ["squash"]}
              + (if $n == "" then {} else {required_approving_review_count: ($n | tonumber)} end))}]
      )
    }')"
approvals_now="$(jq '.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count' <<<"$desired")"

# 比べる形に揃える（ルールは種類の順、GitHub が付け足す項目は除く）
normalize() {
  jq -S '{enforcement, target, bypass_actors: (.bypass_actors // []),
    conditions: {ref_name: {include: (.conditions.ref_name.include // []), exclude: (.conditions.ref_name.exclude // [])}},
    rules: ((.rules // []) | map({type} + (if .parameters then {parameters} else {} end)) | sort_by(.type))}'
}

created=false updated=false
if [ "$existing" = null ]; then
  note "ルールセット「${RULESET_NAME}」を作成し、${branch} への直接 push・強制 push・削除を禁止する（必要な承認: ${approvals_now}）"
  created=true
  ruleset_id="$(mutate POST "repos/$repo_nwo/rulesets" "$desired" | jq -r '.id // empty')"
elif [ "$(normalize <<<"$existing")" != "$(normalize <<<"$desired")" ]; then
  note "ルールセット「${RULESET_NAME}」を揃える（${branch} を保護、必要な承認: ${approvals_now}）"
  updated=true
  mutate PUT "repos/$repo_nwo/rulesets/$ruleset_id" "$desired" >/dev/null
fi

jq -n --argjson dry "$dry_run" --arg repo "$repo_nwo" --arg branch "$branch" --argjson changed "$changed" \
  --arg id "$ruleset_id" --argjson created "$created" --argjson updated "$updated" \
  --argjson approvals "$approvals_now" --argjson actions "$actions" '{
    dry_run: $dry,
    repo: $repo,
    branch: $branch,
    settings: {changed: $changed},
    ruleset: {id: (if $id == "" then null else ($id | tonumber) end), created: $created, updated: $updated,
      required_approvals: $approvals},
    actions: $actions
  }'
