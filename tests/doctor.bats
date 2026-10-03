#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、export がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh を PATH の先頭に置く。FAKE_SCOPES でトークンのスコープを、FAKE_GH_VERSION で gh のバージョンを変えられる。
# gh repo view は me/demo を返し、FAKE_NO_REPO があれば失敗する（GitHub のリポジトリでないとき）。
# gh label list はリポジトリにある今のラベルとして FAKE_LABELS（既定: プラグインの定義のラベルすべて）を返す。
# ほかの呼び出しは失敗する。
fake_gh() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "--version "*) echo "gh version ${FAKE_GH_VERSION:-2.96.0} (2026-07-02)" ;;
  "auth status") exit "${FAKE_AUTH_STATUS:-0}" ;;
  "api -i") printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: %s\r\n\r\n{}\n' "$FAKE_SCOPES" ;;
  "repo view")
    [ -z "${FAKE_NO_REPO:-}" ] || { echo "no git remotes found" >&2; exit 1; }
    echo me/demo
    ;;
  "label list") printf '%s\n' "$FAKE_LABELS" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
  FAKE_LABELS="$(cat "$SCRIPTS/../defaults/labels.json")"
  export FAKE_LABELS
}

# 使い方: labels_check → labels の確認の [ok, level, detail]。確認が無ければ空
labels_check() { jq -c '.checks[] | select(.name == "labels") | [.ok, .level, .detail]' <<<"$output"; }

@test "すべて揃っていれば ok で終了コード 0" {
  fake_gh
  export FAKE_SCOPES="repo, project, workflow"
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r .ok <<<"$output")" true
}

@test "project スコープが無ければ ok=false で終了コード 1" {
  fake_gh
  export FAKE_SCOPES="repo, workflow"
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -r '.checks[] | select(.name == "gh-project-scope") | .ok' <<<"$output")" false
}

@test "未ログインなら gh-auth が失敗する" {
  fake_gh
  export FAKE_AUTH_STATUS=1
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -r '.checks[] | select(.name == "gh-auth") | .ok' <<<"$output")" false
}

@test "Project が未設定なのは警告にとどまる" {
  fake_gh
  export FAKE_SCOPES="project"
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -r '.checks[] | select(.name == "project") | .level' <<<"$output")" warn
}

@test "設定が壊れていれば config が失敗する" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '{broken' >.claude/dev-workflow/config.json
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -r '.checks[] | select(.name == "config") | .ok' <<<"$output")" false
}

@test "古い置き場所のファイルがあれば、止めずに移すよう促す" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '{}' >.claude/workflow.json
  mkdir -p .claude/review "$TMP/workflow" "$TMP/review" "$TMP/wt-parent"
  touch .claude/review/mine.md "$TMP/workflow/commit.md" "$TMP/review/mine.md"
  echo '{}' >.claude/workflow.local.json
  git worktree add -q -b feat/1-x "$TMP/wt-parent/wt"
  cd "$TMP/wt-parent/wt"
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.checks[] | select(.name == "old-locations") | [.ok, .level]' <<<"$output")" '[false,"warn"]'
  detail="$(jq -r '.checks[] | select(.name == "old-locations") | .detail' <<<"$output")"
  assert_equal "$detail" "古い置き場所のファイルは使われません。移してください: $REPO/.claude/workflow.local.json → $REPO/.claude/dev-workflow/config.local.json、$TMP/workflow → $WORKFLOW_USER_DIR/、$TMP/review → $WORKFLOW_USER_DIR/review/"
  cd "$REPO"
  run_script doctor.sh
  assert_output --partial "$REPO/.claude/workflow.json → $REPO/.claude/dev-workflow/config.json、$REPO/.claude/review → $REPO/.claude/dev-workflow/review/、"
}

@test "個人の設定が git に無視されていなければ、.gitignore に足すよう促す" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '.claude/workflow.local.json' >.gitignore
  echo '{}' >.claude/workflow.local.json
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.checks[] | select(.name == "local-ignored") | [.ok, .level]' <<<"$output")" '[false,"warn"]'
  assert_output --partial "個人の設定が git に無視されていません。.gitignore に .claude/dev-workflow/config.local.json を足してください"
  # 移して .gitignore も直せば促さない
  mv .claude/workflow.local.json .claude/dev-workflow/config.local.json
  echo '.claude/dev-workflow/config.local.json' >.gitignore
  run_script doctor.sh
  assert_equal "$(jq '[.checks[] | select(.name == "local-ignored")] | length' <<<"$output")" 0
}

@test "古い置き場所に Markdown の無いディレクトリがあるだけなら、促さない" {
  fake_gh
  export FAKE_SCOPES="project"
  mkdir -p .claude/review "$TMP/workflow"
  touch "$TMP/workflow/other.txt"
  run_script doctor.sh
  assert_equal "$(jq -r '.checks[] | select(.name == "old-locations") | .ok' <<<"$output")" true
}

@test "gh が古ければ、止めずに更新を促す" {
  fake_gh
  export FAKE_SCOPES="repo, project" FAKE_GH_VERSION=2.87.9
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.checks[] | select(.name == "gh-version") | [.ok, .level]' <<<"$output")" '[false,"warn"]'
  assert_output --partial "gh 2.88.0 以上を使ってください（今は 2.87.9）。gh を更新してください"
}

@test "gh のバージョンは数字ごとに比べる（2.100.0 は 2.88.0 より新しい）" {
  fake_gh
  export FAKE_SCOPES="repo, project" FAKE_GH_VERSION=2.100.0
  run_script doctor.sh
  assert_equal "$(jq -r '.checks[] | select(.name == "gh-version") | .ok' <<<"$output")" true
  export FAKE_GH_VERSION=3.0
  run_script doctor.sh
  assert_equal "$(jq -r '.checks[] | select(.name == "gh-version") | .ok' <<<"$output")" true
}

@test "定義にあってリポジトリに無いラベルがあれば、止めずに名前と repo-setup を知らせる" {
  fake_gh
  export FAKE_SCOPES="project"
  FAKE_LABELS="$(jq -c 'map(select(.name != "breaking" and .name != "perf"))' "$SCRIPTS/../defaults/labels.json")"
  run_script doctor.sh
  assert_success
  assert_equal "$(labels_check)" '[false,"warn","ラベルの定義にあってリポジトリに無いラベルがあります: perf, breaking。/dev-workflow:repo-setup でラベルを登録してください"]'
}

@test "定義のラベルが揃っていれば、ラベルの警告は出ない" {
  fake_gh
  export FAKE_SCOPES="project"
  # 名前は大文字と小文字を区別せず、色・説明の違いや定義に無いラベルは問わない
  FAKE_LABELS="$(jq -c 'map(.name |= ascii_upcase | .color = "000000") + [{name: "bug", color: "ededed", description: ""}]' \
    "$SCRIPTS/../defaults/labels.json")"
  run_script doctor.sh
  assert_success
  assert_equal "$(jq -c '.[0:2]' <<<"$(labels_check)")" '[true,"warn"]'
}

@test "リポジトリ独自のラベルの定義があれば、それと比べる" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '[{"name": "feat", "color": "0e8a16"}, {"name": "breaking", "color": "b60205"}, {"name": "spike", "color": "ffffff"}]' \
    >.claude/dev-workflow/labels.json
  run_script doctor.sh
  assert_output --partial "リポジトリに無いラベルがあります: spike。"
}

@test "GitHub に問い合わせられないときは、ラベルの確認を飛ばす" {
  fake_gh
  export FAKE_SCOPES="project" FAKE_LABELS='[]'
  # 未ログイン
  export FAKE_AUTH_STATUS=1
  run_script doctor.sh
  assert_equal "$(labels_check)" ""
  # GitHub のリポジトリでない
  export FAKE_AUTH_STATUS=0 FAKE_NO_REPO=1
  run_script doctor.sh
  assert_success
  assert_equal "$(labels_check)" ""
  # リポジトリの外
  unset FAKE_NO_REPO
  cd "$TMP"
  run_script doctor.sh
  assert_equal "$(labels_check)" ""
}
