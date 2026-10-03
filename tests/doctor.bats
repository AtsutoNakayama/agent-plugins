#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、export がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh を PATH の先頭に置く。FAKE_SCOPES でトークンのスコープを、FAKE_GH_VERSION で gh のバージョンを変えられる。
fake_gh() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "--version "*) echo "gh version ${FAKE_GH_VERSION:-2.96.0} (2026-07-02)" ;;
  "auth status") exit "${FAKE_AUTH_STATUS:-0}" ;;
  "api -i") printf 'HTTP/2.0 200 OK\r\nX-Oauth-Scopes: %s\r\n\r\n{}\n' "$FAKE_SCOPES" ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

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
  echo '{broken' >.claude/workflow.json
  run_script doctor.sh
  assert_failure 1
  assert_equal "$(jq -r '.checks[] | select(.name == "config") | .ok' <<<"$output")" false
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
