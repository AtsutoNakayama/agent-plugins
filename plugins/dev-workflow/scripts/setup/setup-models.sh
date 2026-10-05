#!/usr/bin/env bash
# レビューのサブエージェントに使うモデル（設定の review.model）を、選んだ層の設定ファイルに書く。
# 何度実行しても同じ結果になる。オプションを付けなければ、今の設定と、どの層で決めたかだけを出力する。
#
# 使い方: setup-models.sh [オプション]
#   --review-model M   opus・sonnet・haiku・fable のどれか。off なら null を書き、セッションと同じモデルで動かす
#   --scope S          書く層。user（~/.claude/dev-workflow/config.json。自分のすべてのリポジトリ）・
#                      local（<repo>/.claude/dev-workflow/config.local.json。自分だけ・このリポジトリ）・
#                      team（<repo>/.claude/dev-workflow/config.json。チーム。コミットが要る）。--review-model には必須
#   --dry-run          変更せず、行う予定の操作だけを出力する
#
# 出力: review.model（合わせた後の値）・review.decided（既定の層以外のどこかで決めてあるか）・
#       review.layers（review.model を決めている層と値）・file（書く・書いたファイル）・changed・actions
# 書いた層より上位の層（user < team < local）が別の値を決めていると、書いても効かないので警告する。
set -euo pipefail

# shellcheck source=../lib/common.sh
. "$(cd "$(dirname "$0")" && pwd)/../lib/common.sh"
dw_require jq

# macOS の BSD sed が日本語で失敗しないよう、バイト列として扱わせる
usage() { LC_ALL=C sed -n '2,/^[^#]/{/^[^#]/d;s/^# \{0,1\}//;p;}' "$0"; }

review_model="" scope="" dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --review-model | --scope)
      if [ $# -lt 2 ] || [ -z "$2" ]; then dw_die "$1 に値がありません" 64; fi
      case "$1" in
        --review-model) review_model="$2" ;;
        --scope) scope="$2" ;;
      esac
      shift 2
      ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) dw_die "不明な引数です: $1" 64 ;;
  esac
done

value=""
if [ -n "$review_model" ]; then
  if [ "$review_model" = off ]; then
    value=null
  else
    case " $DW_REVIEW_MODELS " in
      *" $review_model "*) value="$(jq -n --arg m "$review_model" '$m')" ;;
      *) dw_die "--review-model は off か ${DW_REVIEW_MODELS// /・} のどれかにしてください: ${review_model}" 64 ;;
    esac
  fi
  case "$scope" in
    user | local | team) ;;
    "") dw_die "--review-model には --scope（user・local・team）が要ります" 64 ;;
    *) dw_die "--scope は user・local・team のどれかにしてください: ${scope}" 64 ;;
  esac
elif [ -n "$scope" ]; then
  dw_die "--scope は --review-model と一緒に使ってください" 64
fi

repo_root="$(dw_repo_root)" || dw_die "リポジトリの中で実行してください" 64
# 個人の上書き（local）は、ワークツリーで作業中でもメインのワークツリーに置く（config.sh が読む場所と揃える）
main_root="$(dw_main_root "$repo_root" || true)"
user_file="$(dw_user_dir)/config.json"
team_file="$repo_root/.claude/dev-workflow/config.json"
local_file="${main_root:-$repo_root}/.claude/dev-workflow/config.local.json"

# 層ごとに review.model を決めているか（null も「オフに決めた」とみなす）。優先度の低い順に並べる
layers='[]'
for pair in "user:$user_file" "team:$team_file" "local:$local_file"; do
  name="${pair%%:*}" f="${pair#*:}"
  [ -f "$f" ] || continue
  dw_check_json "$f"
  if jq -e '(.review | type) == "object" and (.review | has("model"))' "$f" >/dev/null; then
    layers="$(jq -c --arg n "$name" --arg f "$f" --argjson v "$(jq -c .review.model "$f")" \
      '. + [{layer: $n, file: $f, model: $v}]' <<<"$layers")"
  fi
done

file=null changed=false actions='[]'
if [ -n "$value" ]; then
  case "$scope" in
    user) target="$user_file" ;;
    team) target="$team_file" ;;
    local) target="$local_file" ;;
  esac
  file="$(jq -n --arg f "$target" '$f')"
  # 決めていない（キーが無い）ことと、null に決めたことを分けるため、無ければ空にする
  current=""
  if [ -f "$target" ] && jq -e '(.review | type) == "object" and (.review | has("model"))' "$target" >/dev/null; then
    current="$(jq -c .review.model "$target")"
  fi
  # 既に同じ値なら書き直さない（書式の違いで空白だけの差分を作らない）
  if [ "$current" != "$value" ]; then
    changed=true
    label="$(if [ "$value" = null ]; then echo "null（セッションと同じモデル）"; else jq -r . <<<"$value"; fi)"
    actions="$(jq -c --arg a "$target の review.model を ${label} にする" '. + [$a]' <<<"$actions")"
    if ! $dry_run; then
      mkdir -p "$(dirname "$target")"
      body='{}'
      [ -f "$target" ] && body="$(cat "$target")"
      jq --argjson v "$value" '.review = ((.review // {}) + {model: $v})' <<<"$body" >"$target.tmp"
      mv "$target.tmp" "$target"
    fi
  fi
  layers="$(jq -c --arg n "$scope" --arg f "$target" --argjson v "$value" \
    'map(select(.layer != $n)) + [{layer: $n, file: $f, model: $v}]
     | sort_by({user: 0, team: 1, local: 2}[.layer])' <<<"$layers")"
  # 上位の層が別の値を決めていれば、書いても効かない
  over="$(jq -r --arg n "$scope" --argjson v "$value" \
    '({user: 0, team: 1, local: 2}) as $o | map(select($o[.layer] > $o[$n] and .model != $v)) | last // empty
     | "\(.file) の review.model（\(.model)）が優先されるので、書いた値は効きません"' <<<"$layers")"
  [ -z "$over" ] || dw_warn "$over"
fi

jq -n --argjson layers "$layers" --argjson file "$file" --argjson changed "$changed" \
  --argjson dry "$dry_run" --argjson actions "$actions" '{
    dry_run: $dry,
    review: {model: ((($layers | last) // {model: null}).model), decided: ($layers | length > 0), layers: $layers},
    file: $file,
    changed: $changed,
    actions: $actions
  }'
