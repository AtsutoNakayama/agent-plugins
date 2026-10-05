#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

TEAM=.claude/dev-workflow/config.json
LOCAL=.claude/dev-workflow/config.local.json

# 標準エラーの警告の後ろに出る JSON だけを取り出す
# macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
json_of() { printf '%s\n' "$1" | LC_ALL=C sed -n '/^{/,$p'; }

@test "オプションが無ければ、どの層でも決めていないことを出力し、何も書かない" {
  run_script setup/setup-models.sh
  assert_success
  assert_equal "$(jq -c '[.review.model, .review.decided, .review.layers, .file, .changed]' <<<"$output")" '[null,false,[],null,false]'
  [ ! -e "$TEAM" ] && [ ! -e "$LOCAL" ] && [ ! -e "$WORKFLOW_USER_DIR/config.json" ]
}

@test "null に決めた層があれば、オフに決めたとみなす" {
  echo '{"review": {"model": null}}' >"$LOCAL"
  run_script setup/setup-models.sh
  assert_success
  assert_equal "$(jq -c '[.review.model, .review.decided, (.review.layers | map(.layer))]' <<<"$output")" '[null,true,["local"]]'
}

@test "user の層に書くと、ほかの項目を残して review.model を足し、config.sh に効く" {
  echo '{"language": "en", "review": {"max_rounds": 5}}' >"$WORKFLOW_USER_DIR/config.json"
  run_script setup/setup-models.sh --review-model sonnet --scope user
  assert_success
  assert_equal "$(jq -c '[.review.model, .review.decided, .changed, .file]' <<<"$output")" \
    "[\"sonnet\",true,true,\"$WORKFLOW_USER_DIR/config.json\"]"
  assert_equal "$(jq -c . "$WORKFLOW_USER_DIR/config.json")" '{"language":"en","review":{"max_rounds":5,"model":"sonnet"}}'
  run_script config.sh .review.model
  assert_output sonnet
}

@test "team の層には、リポジトリの config.json に書く" {
  run_script setup/setup-models.sh --review-model opus --scope team
  assert_success
  assert_equal "$(jq -c . "$TEAM")" '{"review":{"model":"opus"}}'
}

@test "local の層には、ワークツリーの中でもメインのワークツリーの config.local.json に書く" {
  git worktree add -q -b feat/1-x "$TMP/wt"
  cd "$TMP/wt"
  run_script setup/setup-models.sh --review-model fable --scope local
  assert_success
  assert_equal "$(jq -c . "$REPO/$LOCAL")" '{"review":{"model":"fable"}}'
  [ ! -e "$TMP/wt/$LOCAL" ]
  run_script config.sh .review.model
  assert_output fable
}

@test "off は null を書き、セッションと同じモデルに戻す" {
  echo '{"review": {"model": "opus"}}' >"$LOCAL"
  run_script setup/setup-models.sh --review-model off --scope local
  assert_success
  assert_equal "$(jq -c . "$LOCAL")" '{"review":{"model":null}}'
  assert_equal "$(jq -c '[.review.model, .review.decided, .changed]' <<<"$output")" '[null,true,true]'
}

@test "既に同じ値なら書き直さない" {
  printf '{ "review" : { "model" : "haiku" } }\n' >"$TEAM"
  before="$(cat "$TEAM")"
  run_script setup/setup-models.sh --review-model haiku --scope team
  assert_success
  assert_equal "$(jq -c '[.changed, .actions]' <<<"$output")" '[false,[]]'
  assert_equal "$(cat "$TEAM")" "$before"
}

@test "キーが無い層に off を選ぶと、null を書く（決めていないことと区別する）" {
  echo '{"review": {"max_rounds": 2}}' >"$TEAM"
  run_script setup/setup-models.sh --review-model off --scope team
  assert_success
  assert_equal "$(jq -c . "$TEAM")" '{"review":{"max_rounds":2,"model":null}}'
  assert_equal "$(jq -r .changed <<<"$output")" true
}

@test "dry-run では書かずに、予定だけを出力する" {
  run_script setup/setup-models.sh --review-model opus --scope team --dry-run
  assert_success
  [ ! -e "$TEAM" ]
  assert_equal "$(jq -c '[.dry_run, .changed, .review.model, (.actions | length)]' <<<"$output")" '[true,true,"opus",1]'
  assert_equal "$(jq -r '.actions[0]' <<<"$output")" "$REPO/$TEAM の review.model を opus にする"
}

@test "上位の層が別の値を決めていれば、書いても効かないことを警告する" {
  echo '{"review": {"model": "haiku"}}' >"$LOCAL"
  run_script setup/setup-models.sh --review-model opus --scope team
  assert_success
  assert_output --partial "warn: $REPO/$LOCAL の review.model（haiku）が優先されるので、書いた値は効きません"
  assert_equal "$(json_of "$output" | jq -r .review.model)" haiku
}

@test "使えないモデル・層の指定の誤りは、使い方の誤り（64）で止まり、何も書かない" {
  run_script setup/setup-models.sh --review-model gpt --scope team
  assert_failure 64
  assert_output --partial "--review-model は off か opus・sonnet・haiku・fable のどれかにしてください: gpt"
  run_script setup/setup-models.sh --review-model opus
  assert_failure 64
  assert_output --partial "--scope（user・local・team）が要ります"
  run_script setup/setup-models.sh --review-model opus --scope repo
  assert_failure 64
  run_script setup/setup-models.sh --scope team
  assert_failure 64
  [ ! -e "$TEAM" ]
}
