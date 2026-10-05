#!/usr/bin/env bash
# 実行環境と設定を確認し、結果を JSON で出力する。
# level が error の確認に1つでも失敗したら終了コード 1。
set -uo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

if ! command -v jq >/dev/null 2>&1; then
  printf '{"ok":false,"checks":[{"name":"jq","ok":false,"level":"error","detail":"jq が見つかりません"}]}\n'
  exit 1
fi

checks=""
gh_auth=false

# 使い方: check <名前> <true|false> <error|warn> <詳細>
check() {
  checks="$checks$(jq -nc --arg n "$1" --argjson ok "$2" --arg l "$3" --arg d "$4" \
    '{name: $n, ok: $ok, level: $l, detail: $d}')
"
}

has() { command -v "$1" >/dev/null 2>&1; }

# bash 3.2 以上
if [ "${BASH_VERSINFO[0]}" -gt 3 ] || { [ "${BASH_VERSINFO[0]}" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  check bash true error "$BASH_VERSION"
else
  check bash false error "bash 3.2 以上が必要です（現在 ${BASH_VERSION}）"
fi

check jq true error "$(jq --version)"

if has git; then check git true error "$(git --version)"; else check git false error "git が見つかりません"; fi

if has gh; then
  check gh true error "$(gh --version | head -n 1)"
  # 古いと使えない機能があるだけなので、止めずに更新を促す
  gh_version="$(dw_gh_version)"
  if [ -n "$gh_version" ] && dw_version_ge "$gh_version" "$DW_GH_MIN_VERSION"; then
    check gh-version true warn "$gh_version"
  else
    check gh-version false warn "gh ${DW_GH_MIN_VERSION} 以上を使ってください（今は ${gh_version:-不明}）。gh を更新してください（https://cli.github.com/）"
  fi
  if gh auth status -h github.com >/dev/null 2>&1; then
    gh_auth=true
    check gh-auth true error "github.com にログイン済み"
    scopes="$(gh api -i user 2>/dev/null | tr -d '\r' | LC_ALL=C sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p')"
    if [ -z "$scopes" ]; then
      check gh-project-scope false warn "トークンのスコープを確認できません（fine-grained token など）"
    elif printf '%s\n' "$scopes" | tr ',' '\n' | sed 's/^ *//' | grep -qx project; then
      check gh-project-scope true error "$scopes"
    else
      check gh-project-scope false error "project スコープがありません。ターミナルで gh auth refresh -h github.com -s project を実行してください"
    fi
  else
    check gh-auth false error "ターミナルで gh auth login を実行してください"
  fi
else
  check gh false error "gh が見つかりません（https://cli.github.com/）"
fi

if config="$("$BASH" "$DW_SCRIPTS_DIR/config.sh" 2>&1)"; then
  check config true error "$(jq -r '.sources | join(", ")' <<<"$config")"
  if [ "$(jq -r '.project.number // empty' <<<"$config")" != "" ]; then
    check project true warn "$(jq -r '"\(.project.owner)/\(.project.number)"' <<<"$config")"
  else
    check project false warn "Project が未設定です（.claude/dev-workflow/config.json の project）"
  fi
else
  check config false error "$config"
fi

# 古い置き場所（.claude/dev-workflow/ にまとめる前）のファイルは使われないので、移すよう促す
moves=""
# 使い方: old_location <古いパス> <新しいパス>。古いパスがディレクトリなら、*.md があるときだけ数える
old_location() {
  if [ -d "$1" ]; then
    ls "$1"/*.md >/dev/null 2>&1 || return 0
  elif [ ! -f "$1" ]; then
    return 0
  fi
  moves="$moves${moves:+、}$1 → $2"
}
repo_root="$(dw_repo_root || true)"
if [ -n "$repo_root" ]; then
  old_location "$repo_root/.claude/workflow.json" "$repo_root/.claude/dev-workflow/config.json"
  old_location "$repo_root/.claude/workflow" "$repo_root/.claude/dev-workflow/"
  old_location "$repo_root/.claude/review" "$repo_root/.claude/dev-workflow/review/"
  old_location "$repo_root/.claude/labels.json" "$repo_root/.claude/dev-workflow/labels.json"
  # 個人の設定はメインのワークツリーに置く
  main_root="$(dw_main_root "$repo_root" || true)"
  local_root="${main_root:-$repo_root}"
  old_location "$local_root/.claude/workflow.local.json" "$local_root/.claude/dev-workflow/config.local.json"
  # .gitignore が古い名前だけを無視している、または既にコミットしてあると、個人の設定がコミットされうる
  # （dw_local_config_state で両方を見分け、それぞれに合う案内を出す）
  if [ -f "$local_root/.claude/workflow.local.json" ] || [ -f "$(dw_local_config_file "$repo_root")" ]; then
    hint="$(dw_local_config_hint "$(dw_local_config_state "$repo_root")")"
    [ -z "$hint" ] || check local-ignored false warn "$hint"
  fi
fi
user_parent="$(dirname "$(dw_user_dir)")"
old_location "$user_parent/workflow/workflow.json" "$(dw_user_dir)/config.json"
old_location "$user_parent/workflow" "$(dw_user_dir)/"
old_location "$user_parent/review" "$(dw_user_review_dir)/"
if [ -n "$moves" ]; then
  check old-locations false warn "古い置き場所のファイルは使われません。移してください: ${moves}"
else
  check old-locations true warn "古い置き場所のファイルはありません"
fi

# ラベルの定義にあってリポジトリに無いラベルがあると、起票などで止まる。定義に足したラベルは、
# 初期設定を済ませたリポジトリには入らないので知らせる。GitHub に問い合わせられないときは飛ばす
if $gh_auth && [ -n "$repo_root" ]; then
  labels_err="$(mktemp)"
  labels="$("$BASH" "$DW_SCRIPTS_DIR/setup/setup-labels.sh" --dry-run --keep-defaults 2>"$labels_err")"
  labels_status=$?
  if [ "$labels_status" -eq 0 ] && missing="$(jq -er '.labels.created | join(", ")' <<<"$labels" 2>/dev/null)"; then
    if [ -n "$missing" ]; then
      check labels false warn "ラベルの定義にあってリポジトリに無いラベルがあります: ${missing}。/dev-workflow:repo-setup でラベルを登録してください"
    else
      check labels true warn "ラベルの定義にあるラベルはすべてリポジトリにあります"
    fi
  elif [ "$labels_status" -eq 2 ]; then
    # 終了コード 2 は定義を読めないとき。GitHub に問い合わせられないときと違い、直さないと起票などで止まる
    check labels false warn "$(tail -n 1 "$labels_err" | LC_ALL=C sed 's/^error: //')"
  fi
  rm -f "$labels_err"
fi

# base_branch にマージキューと strict（最新の取り込みを求める）のどちらが効いているかを示す。どちらも無いと、
# 古い base_branch で通った CI の結果のままマージして壊れることがある。組織のルールセットも含めて見るため、
# ブランチに効いているルール（rules/branches）を読む。ブランチは、setup-repo.sh がルールセットで守るものと同じく、
# チームの設定で決める（個人の設定は使わない）。GitHub に問い合わせられないときは飛ばす
base_branch=""
if [ -n "$repo_root" ]; then
  base_branch="$(dw_team_base_branch "$repo_root/.claude/dev-workflow/config.json" || true)"
fi
if $gh_auth && [ -n "$repo_root" ] && [ -n "$base_branch" ] \
  && rules="$(gh api --paginate "repos/{owner}/{repo}/rules/branches/$(jq -rn --arg b "$base_branch" '$b | @uri')?per_page=100" 2>/dev/null)" \
  && merge="$(jq -ser '
    # --paginate はページごとに配列を出力するので、1つにまとめる
    add // []
    | if any(.[]; .type == "merge_queue") then "queue"
    elif any(.[]; .type == "required_status_checks" and .parameters.strict_required_status_checks_policy) then "strict"
    elif any(.[]; .type == "required_status_checks") then "none"
    else "no-checks" end' <<<"$rules" 2>/dev/null)"; then
  case "$merge" in
    queue) check merge-queue true warn "${base_branch} へのマージはマージキューを通します" ;;
    strict) check merge-queue true warn "${base_branch} へのマージは、PR が最新の ${base_branch} を取り込んでいることを求めます（strict）" ;;
    none) check merge-queue false warn "${base_branch} へのマージに、マージキューも最新の ${base_branch} の取り込み（strict）も求めていません。古い ${base_branch} で通った CI のままマージすると壊れることがあります。/dev-workflow:repo-setup で設定してください" ;;
    *) check merge-queue true warn "${base_branch} へのマージに必須のチェックが無いので、マージキューも strict も使っていません" ;;
  esac
  # キューを使っていれば、必須のチェックのワークフローが merge_group のイベントで動くかを確かめる。動かないと、
  # キューのチェックが「待ち」のまま残り、PR がマージされない。確かめられないときは飛ばす
  if [ "$merge" = queue ]; then
    required="$(jq -sc 'add // [] | [.[] | select(.type == "required_status_checks")
      | .parameters.required_status_checks[]?.context] | unique' <<<"$rules" 2>/dev/null || echo '[]')"
    if [ "$required" != "[]" ] \
      && mg="$("$BASH" "$DW_SCRIPTS_DIR/merge-group-check.sh" --branch "$base_branch" --checks-json "$required" 2>/dev/null)"; then
      if [ "$(jq -r '.messages.not_running // empty' <<<"$mg")" != "" ]; then
        check merge-group false warn "$(jq -r .messages.not_running <<<"$mg")"
      elif [ "$(jq -r '.messages.unknown // empty' <<<"$mg")" != "" ]; then
        check merge-group true warn "$(jq -r .messages.unknown <<<"$mg")"
      else
        check merge-group true warn "必須のチェックのワークフローは、merge_group のイベントでも動きます"
      fi
    fi
  fi
fi

result="$(printf '%s' "$checks" | jq -s '{ok: (map(select(.level == "error" and (.ok | not))) | length == 0), checks: .}')"
printf '%s\n' "$result"
[ "$(jq -r .ok <<<"$result")" = true ]
