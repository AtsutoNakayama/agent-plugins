#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper

# 偽の gh。gh label list は $FIX/labels.json を返し、
# gh label create / delete と gh api -X PATCH は引数を $CALLS に1行ずつ記録する。
# gh repo view は、リポジトリを指定すれば repo.json、指定しなければ（今いるリポジトリ）here.json を返す。
# 別のリポジトリのファイル（gh api .../contents/<パス>）は $FIX/remote/<パス> を返し、無ければ 404 にする。
# $FIX/remote/<パス>.err があれば、その内容を標準エラーに出して失敗する。
setup_fake_gh() {
  FIX="$TMP/fix"
  CALLS="$TMP/calls"
  export FIX CALLS
  mkdir -p "$TMP/bin" "$FIX"
  : >"$CALLS"
  cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
q=.
for a in "$@"; do
  if [ "${prev:-}" = -q ]; then q="$a"; fi
  prev="$a"
done
record() {
  printf '%s' "$1" >>"$CALLS"
  shift
  printf ' [%s]' "$@" >>"$CALLS"
  echo >>"$CALLS"
}
case "$1 $2" in
  "repo view")
    case "${3:-}" in
      "" | -*) f=here.json ;;
      *) f=repo.json ;;
    esac
    [ -f "$FIX/$f" ] || f=repo.json
    jq -r "$q" "$FIX/$f"
    ;;
  "label list") cat "$FIX/labels.json" ;;
  "label create" | "label delete") shift; record "$@" ;;
  "api -X") shift 2; record edit "$@" ;;
  "api -H")
    path="${4#repos/*/*/contents/}"
    if [ -f "$FIX/remote/$path.err" ]; then cat "$FIX/remote/$path.err" >&2; exit 1
    elif [ -f "$FIX/remote/$path" ]; then cat "$FIX/remote/$path"
    else echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
    ;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"

  printf '%s\n' '{"nameWithOwner": "me/demo"}' >"$FIX/repo.json"
  current '[]'
}

# 使い方: current <リポジトリにある今のラベルの配列>
current() { printf '%s\n' "$1" >"$FIX/labels.json"; }

# GitHub が新しいリポジトリに付ける既定のラベル
github_defaults() {
  jq -c 'map({name: ., color: "ededed", description: ""})' <<<'["bug", "documentation", "duplicate",
    "enhancement", "good first issue", "help wanted", "invalid", "question", "wontfix"]'
}

run_setup() {
  run "${TEST_BASH:-bash}" "$BATS_TEST_DIRNAME/../scripts/setup-labels.sh" "$@"
  # bats は失敗したテストの標準出力だけを表示するので、原因を追えるよう出力を残す
  printf '%s\n' "$output"
  # 標準エラーの警告の後ろに出る JSON だけを取り出す
  # macOS の BSD sed は日本語を含む入力で失敗することがあるので、バイト列として扱わせる
  json="$(printf '%s\n' "$output" | LC_ALL=C sed -n '/^{/,$p')"
}

called() { grep -c "^$1 " "$CALLS" || true; }

@test "新しいリポジトリでは type ラベル 10 個を作り、既定のラベルを削除する" {
  setup_fake_gh
  current "$(github_defaults)"
  run_setup
  [ "$status" -eq 0 ]
  [ "$(called create)" -eq 10 ]
  [ "$(called delete)" -eq 9 ]
  [ "$(called edit)" -eq 0 ]
  grep -qF 'create [feat] [-R] [me/demo] [--color] [0e8a16] [--description] [新しい機能]' "$CALLS"
  grep -qF 'delete [good first issue] [-R] [me/demo] [--yes]' "$CALLS"
  [ "$(jq -c '.labels | [(.created | length), (.deleted | length), .unchanged]' <<<"$json")" = '[10,9,0]' ]
}

@test "定義と同じラベルは変更しない（2回目の実行では何もしない）" {
  setup_fake_gh
  current "$(jq -c 'map(.color |= ascii_upcase)' "$BATS_TEST_DIRNAME/../plugins/dev-workflow/defaults/labels.json")"
  run_setup
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [ "$(jq -r .labels.unchanged <<<"$json")" -eq 10 ]
  [ "$(jq -c .actions <<<"$json")" = '[]' ]
}

@test "色・説明・大文字小文字が違うラベルだけ既存の名前を指定して更新する" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "#0E8A16", "description": "新機能"},
    {"name": "fix", "color": "d73a4a"}]' >labels.json
  current '[{"name": "Feat", "color": "0e8a16", "description": "新機能"},
    {"name": "fix", "color": "000000", "description": ""}]'
  run_setup --file labels.json
  [ "$status" -eq 0 ]
  [ "$(called create)" -eq 0 ]
  [ "$(called edit)" -eq 2 ]
  grep -qF 'edit [PATCH] [repos/me/demo/labels/Feat] [-f] [new_name=feat] [-f] [color=0e8a16] [-f] [description=新機能]' "$CALLS"
  grep -qF 'edit [PATCH] [repos/me/demo/labels/fix] [-f] [new_name=fix] [-f] [color=d73a4a] [-f] [description=]' "$CALLS"
}

@test "--keep-defaults では既定のラベルを削除しない" {
  setup_fake_gh
  current "$(github_defaults)"
  run_setup --keep-defaults
  [ "$status" -eq 0 ]
  [ "$(called delete)" -eq 0 ]
}

@test "定義にあるラベルと、既定以外のラベルは削除しない" {
  setup_fake_gh
  printf '%s\n' '[{"name": "Bug", "color": "d73a4a"}]' >labels.json
  current '[{"name": "bug", "color": "d73a4a", "description": ""},
    {"name": "wontfix", "color": "ffffff", "description": ""},
    {"name": "priority: high", "color": "ff0000", "description": ""}]'
  run_setup --file labels.json
  [ "$status" -eq 0 ]
  [ "$(called delete)" -eq 1 ]
  grep -qF 'delete [wontfix]' "$CALLS"
}

@test "dry-run では変更せず、予定の操作だけを出力する" {
  setup_fake_gh
  current "$(github_defaults)"
  run_setup --dry-run
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [ "$(jq -r .dry_run <<<"$json")" = true ]
  [ "$(jq -r '.actions[0]' <<<"$json")" = "ラベル「feat」を作成する" ]
  [ "$(jq -r '.actions[-1]' <<<"$json")" = "既定のラベル「wontfix」を削除する" ]
}

@test "リポジトリの .claude/labels.json があれば、既定の定義より優先する" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >.claude/labels.json
  run_setup
  [ "$status" -eq 0 ]
  [ "$(called create)" -eq 1 ]
  [ "$(jq -r .file <<<"$json")" = "$REPO/.claude/labels.json" ]
}

@test "更新する既存のラベルの名前は URL エンコードする" {
  setup_fake_gh
  printf '%s\n' '[{"name": "priority: high", "color": "ff0000"}]' >labels.json
  current '[{"name": "Priority: High", "color": "ff0000", "description": ""}]'
  run_setup --file labels.json
  [ "$status" -eq 0 ]
  grep -qF 'edit [PATCH] [repos/me/demo/labels/Priority%3A%20High]' "$CALLS"
}

@test "--repo で別のリポジトリを指定したら、そのリポジトリの定義と設定を使う" {
  setup_fake_gh
  printf '%s\n' '{"nameWithOwner": "me/here"}' >"$FIX/here.json"
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >.claude/labels.json
  mkdir -p "$FIX/remote/.claude"
  printf '%s\n' '[{"name": "story", "color": "111111"}]' >"$FIX/remote/.claude/labels.json"
  printf '%s\n' '{"labels": {"types": ["story", "spike"]}}' >"$FIX/remote/.claude/workflow.json"
  run_setup --repo me/demo
  [ "$status" -eq 0 ]
  [ "$(called create)" -eq 1 ]
  grep -qF 'create [story] [-R] [me/demo]' "$CALLS"
  [ "$(jq -r .file <<<"$json")" = "me/demo:.claude/labels.json" ]
  [[ "$output" == *"定義に無いラベルがあります: spike"* ]]
}

@test "別のリポジトリに定義が無ければ、プラグインの既定を使う" {
  setup_fake_gh
  printf '%s\n' '{"nameWithOwner": "me/here"}' >"$FIX/here.json"
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >.claude/labels.json
  run_setup --repo me/demo
  [ "$status" -eq 0 ]
  [ "$(called create)" -eq 10 ]
  [[ "$(jq -r .file <<<"$json")" == */defaults/labels.json ]]
}

@test "--repo が今いるリポジトリと同じなら、手元の定義を使う" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >.claude/labels.json
  run_setup --repo me/demo
  [ "$status" -eq 0 ]
  [ "$(called create)" -eq 1 ]
  [ "$(jq -r .file <<<"$json")" = "$REPO/.claude/labels.json" ]
}

@test "別のリポジトリの定義を 404 以外の理由で読めなければ、変更せずに止まる" {
  setup_fake_gh
  printf '%s\n' '{"nameWithOwner": "me/here"}' >"$FIX/here.json"
  mkdir -p "$FIX/remote/.claude"
  echo 'gh: Server Error (HTTP 502)' >"$FIX/remote/.claude/labels.json.err"
  run_setup --repo me/demo
  [ "$status" -ne 0 ]
  [[ "$output" == *"me/demo の .claude/labels.json を読めません"* ]]
  [ ! -s "$CALLS" ]
}

@test "設定の type ラベルが定義に無ければ警告する" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "000000"}]' >labels.json
  run_setup --file labels.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"定義に無いラベルがあります: fix, hotfix"* ]]
}

@test "定義の色が 6 桁でなければエラーになる" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "red"}]' >labels.json
  run_setup --file labels.json
  [ "$status" -eq 2 ]
  [[ "$output" == *"ラベルの定義を読めません"* ]]
  [ ! -s "$CALLS" ]
}

@test "名前が大文字小文字違いで重複していればエラーになる" {
  setup_fake_gh
  printf '%s\n' '[{"name": "feat", "color": "000000"}, {"name": "Feat", "color": "000000"}]' >labels.json
  run_setup --file labels.json
  [ "$status" -eq 2 ]
  [[ "$output" == *"ラベルの名前が重複しています: feat"* ]]
}

@test "定義のファイルが無ければエラーになる" {
  setup_fake_gh
  run_setup --file nothing.json
  [ "$status" -eq 2 ]
}

@test "オプションの値が無ければ終了コード 64" {
  setup_fake_gh
  run_setup --file
  [ "$status" -eq 64 ]
  [[ "$output" == *"--file に値がありません"* ]]
}

@test "--help は使い方を表示する" {
  setup_fake_gh
  run_setup --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--keep-defaults"* ]]
  [[ "$output" != *"set -euo"* ]]
}
