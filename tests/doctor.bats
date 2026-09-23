#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、export がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh を PATH の先頭に置く。FAKE_SCOPES でトークンのスコープを変えられる。
fake_gh() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "--version "*) echo "gh version 0.0.0" ;;
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
  [ "$status" -eq 0 ]
  [ "$(jq -r .ok <<<"$output")" = true ]
}

@test "project スコープが無ければ ok=false で終了コード 1" {
  fake_gh
  export FAKE_SCOPES="repo, workflow"
  run_script doctor.sh
  [ "$status" -eq 1 ]
  [ "$(jq -r '.checks[] | select(.name == "gh-project-scope") | .ok' <<<"$output")" = false ]
}

@test "未ログインなら gh-auth が失敗する" {
  fake_gh
  export FAKE_AUTH_STATUS=1
  run_script doctor.sh
  [ "$status" -eq 1 ]
  [ "$(jq -r '.checks[] | select(.name == "gh-auth") | .ok' <<<"$output")" = false ]
}

@test "Project が未設定なのは警告にとどまる" {
  fake_gh
  export FAKE_SCOPES="project"
  run_script doctor.sh
  [ "$status" -eq 0 ]
  [ "$(jq -r '.checks[] | select(.name == "project") | .level' <<<"$output")" = warn ]
}

@test "設定が壊れていれば config が失敗する" {
  fake_gh
  export FAKE_SCOPES="project"
  echo '{broken' >.claude/workflow.json
  run_script doctor.sh
  [ "$status" -eq 1 ]
  [ "$(jq -r '.checks[] | select(.name == "config") | .ok' <<<"$output")" = false ]
}
