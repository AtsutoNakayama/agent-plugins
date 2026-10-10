#!/usr/bin/env bats
# bats はテストごとにサブシェルで動くので、変数の変更がテスト内に閉じるのは意図どおり
# shellcheck disable=SC2030,SC2031

load test_helper
load fake_gh

# origin 役の bare リポジトリに main を push し、feat/17-x を作って1つコミットしておく
setup_branch() {
  setup_fake_gh
  git add .claude/dev-workflow/config.json
  git commit -q -m config
  git init -q --bare -b main "$TMP/origin.git"
  git remote add origin "$TMP/origin.git"
  git push -q origin main
  git switch -q -c feat/17-x
  echo work >work.txt
  git add work.txt
  git commit -q -m "feat: work"
}

# origin の main を進める別の作業場所（$TMP/other）を用意する。無ければ clone し、あれば origin の main を取り込む
other_clone() {
  if [ -d "$TMP/other" ]; then
    git -C "$TMP/other" pull -q origin main
  else
    git clone -q "$TMP/origin.git" "$TMP/other"
  fi
}

# origin の main に、別の PR がマージされたことにする（main を n 個進める）
advance_main() {
  local i
  other_clone
  for i in $(seq 1 "$1"); do
    echo "$i" >"$TMP/other/main-$i.txt"
    git -C "$TMP/other" add .
    git -C "$TMP/other" commit -q -m "main $i"
  done
  git -C "$TMP/other" push -q origin main
}

# origin の main に、ブランチの work.txt と衝突する変更（work.txt を別の内容で作る）がマージされたことにする
conflict_main() {
  other_clone
  echo other >"$TMP/other/work.txt"
  git -C "$TMP/other" add work.txt
  git -C "$TMP/other" commit -q -m "main: work"
  git -C "$TMP/other" push -q origin main
}

# origin の feat/17-x に、別の場所からコミットを1つ push する（手元に無い origin のコミット）
push_from_elsewhere() {
  git clone -q -b feat/17-x "$TMP/origin.git" "$TMP/other2"
  echo b >"$TMP/other2/b.txt"
  git -C "$TMP/other2" add b.txt
  git -C "$TMP/other2" commit -q -m "feat: b"
  git -C "$TMP/other2" push -q origin feat/17-x
}

run_status() {
  run_script branch-status.sh "$@"
  printf '%s\n' "$output"
}

@test "main が進んでいなければ up_to_date で、先行のコミット数を出す" {
  setup_branch
  run_status
  assert_success
  assert_equal "$(jq -r '[.branch, .base, .behind, .ahead, .up_to_date, .pr] | map(tostring) | join(" ")' <<<"$output")" "feat/17-x main 0 1 true null"
}

@test "main が進んでいれば、遅れているコミット数を出す（取得は branch-status.sh が行う）" {
  setup_branch
  advance_main 2
  run_status
  assert_success
  assert_equal "$(jq -r '[.behind, .ahead, .up_to_date] | map(tostring) | join(" ")' <<<"$output")" "2 1 false"
}

@test "開いている PR のマージ状態を出す" {
  setup_branch
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "BEHIND", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -r '.pr | [.number, .merge_state] | map(tostring) | join(" ")' <<<"$output")" "5 BEHIND"
  assert_equal "$(args pr-list)" "--head feat/17-x --state open --json number,url,mergeStateStatus,isCrossRepository,baseRefName"
}

@test "PR のマージ先が設定の base_branch と違えば、PR のマージ先に対する遅れと衝突を出す（#284）" {
  setup_branch
  # origin に release/v1 を作り、1つ進める。main は2つ進める
  other_clone
  git -C "$TMP/other" switch -q -c release/v1
  echo r >"$TMP/other/release.txt"
  git -C "$TMP/other" add release.txt
  git -C "$TMP/other" commit -q -m "release 1"
  git -C "$TMP/other" push -q origin release/v1
  git -C "$TMP/other" switch -q main
  advance_main 2
  echo '[{"number": 5, "url": "u", "mergeStateStatus": "BEHIND", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -r '[.base, .behind, .ahead, .conflicts, .plan.action] | map(tostring) | join(" ")' <<<"$output")" "release/v1 1 1 false merge"
}

@test "PR がマージ先を返さなければ、設定の base_branch を取り込み先にする" {
  setup_branch
  advance_main 2
  echo '[{"number": 5, "url": "u", "mergeStateStatus": "BEHIND", "isCrossRepository": false, "baseRefName": ""}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -r '[.base, .behind] | map(tostring) | join(" ")' <<<"$output")" "main 2"
}

@test "gh が JSON でない応答を返しても止まらず、pr は null で、設定の base_branch を取り込み先にする（#284）" {
  setup_branch
  advance_main 1
  echo 'not json' >"$FIX/pr-list.raw"
  run_status
  assert_success
  assert_equal "$(jq -r '[.base, .behind, .pr] | map(tostring) | join(" ")' <<<"$output")" "main 1 null"
}

@test "PR のマージ先を使えない（ブランチ名として使えない・マージ先の違う PR が複数ある）なら、取り込み先を決めずに終了コード 2 で止まる（#284）" {
  setup_branch
  advance_main 1
  for b in -x +x HEAD; do
    jq -nc --arg b "$b" '[{number: 5, url: "u", mergeStateStatus: "BEHIND", isCrossRepository: false, baseRefName: $b}]' >"$FIX/pr-list.json"
    run_status
    assert_failure 2
    assert_output --partial "PR のマージ先（\"${b}\"）は git のブランチ名として使えません。取り込み先を決められないので止めます"
  done
  echo '[{"number": 5, "url": "u", "isCrossRepository": false, "baseRefName": "release/v1"}, {"number": 6, "url": "u", "isCrossRepository": false, "baseRefName": "main"}]' >"$FIX/pr-list.json"
  run_status
  assert_failure 2
  assert_output --partial "マージ先の違う開いた PR が複数あります"
  # 同じマージ先の PR が複数なら、そのマージ先を取り込み先にする
  echo '[{"number": 5, "url": "u", "isCrossRepository": false, "baseRefName": "main"}, {"number": 6, "url": "u", "isCrossRepository": false, "baseRefName": "main"}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -r '[.base, .behind, .pr.number] | map(tostring) | join(" ")' <<<"$output")" "main 1 5"
}

@test "PR のマージ先を取得できなければ、base_branch に戻さずに終了コード 2 で止まる（取り込む側なので。#284）" {
  setup_branch
  echo '[{"number": 5, "url": "u", "isCrossRepository": false, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_status
  assert_failure 2
  assert_output --partial "origin/release/v1 を取得できませんでした"
}

@test "マージ先が空の PR と base_branch に向いた PR が並んでも、マージ先の違う PR とはみなさずに base_branch を取り込み先にする（#284）" {
  setup_branch
  advance_main 1
  echo '[{"number": 5, "url": "u", "isCrossRepository": false, "baseRefName": ""}, {"number": 6, "url": "u6", "isCrossRepository": false, "baseRefName": "main"}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -r '[.base, .behind, .pr.number] | map(tostring) | join(" ")' <<<"$output")" "main 1 5"
}

@test "fork の PR のマージ先は使わない" {
  setup_branch
  advance_main 1
  echo '[{"number": 9, "url": "u", "mergeStateStatus": "CLEAN", "isCrossRepository": true, "baseRefName": "release/v1"}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -r '[.base, .behind, .pr] | map(tostring) | join(" ")' <<<"$output")" "main 1 null"
}

@test "fork の同じ名前のブランチからの PR は除く" {
  setup_branch
  echo '[{"number": 9, "url": "u", "mergeStateStatus": "CLEAN", "isCrossRepository": true}]' >"$FIX/pr-list.json"
  run_status
  assert_success
  assert_equal "$(jq -c .pr <<<"$output")" "null"
}

@test "gh が無くても、遅れの数は出す（pr は null）" {
  setup_branch
  mkdir "$TMP/nogh"
  for c in git jq bash env sed awk cat dirname basename grep cut head tr sort mktemp rm wc; do
    ln -s "$(command -v "$c")" "$TMP/nogh/$c" 2>/dev/null || true
  done
  PATH="$TMP/nogh" run_status
  assert_success
  assert_equal "$(jq -r '[.behind, .pr] | map(tostring) | join(" ")' <<<"$output")" "0 null"
}

@test "未コミットの変更があれば dirty が true" {
  setup_branch
  run_status
  assert_equal "$(jq -r .dirty <<<"$output")" "false"
  echo more >>work.txt
  run_status
  assert_equal "$(jq -r .dirty <<<"$output")" "true"
}

@test "origin にブランチが無ければ unpushed・unpulled は null" {
  setup_branch
  run_status
  assert_equal "$(jq -c '[.unpushed, .unpulled]' <<<"$output")" "[null,null]"
}

@test "未 push のコミットと、手元に無い origin のコミットの数を出す" {
  setup_branch
  git push -q origin feat/17-x
  echo a >a.txt
  git add a.txt
  git commit -q -m "feat: a"
  run_status
  assert_equal "$(jq -c '[.unpushed, .unpulled]' <<<"$output")" "[1,0]"
  push_from_elsewhere
  run_status
  assert_equal "$(jq -c '[.unpushed, .unpulled]' <<<"$output")" "[1,1]"
}

@test "PR を取得できなくても、遅れの数は出す（pr は null）" {
  setup_branch
  FAKE_FAIL=pr-list run_status
  assert_success
  assert_equal "$(jq -c .pr <<<"$output")" "null"
}

@test "base_branch の上では止まる" {
  setup_branch
  git switch -q main
  run_status
  assert_failure 64
  assert_output --partial "main には取り込めません"
}

@test "不明な引数（--branch など）は拒否する" {
  setup_branch
  run_status --branch feat/17-x
  assert_failure 64
  assert_output --partial "不明な引数です: --branch"
}

@test "base_branch がダッシュで始まれば、オプションとして扱わず、設定を読む時点で止まる" {
  setup_branch
  echo '{"base_branch": "-foo", "project": {"owner": "me", "number": 4}}' >"$REPO/.claude/dev-workflow/config.json"
  run_status
  assert_failure 2
  assert_output --partial "設定の base_branch が git のブランチ名として使えません: -foo"
}

@test "ブランチの上にいなければ止まる" {
  setup_branch
  git switch -q --detach
  run_status
  assert_failure 64
  assert_output --partial "ブランチの上にいません"
}

@test "未追跡のファイルだけなら dirty は false" {
  setup_branch
  echo memo >memo.txt
  run_status
  assert_equal "$(jq -r .dirty <<<"$output")" "false"
}

@test "origin でブランチが削除されていたら、残っている追跡ブランチではなく null を出す" {
  setup_branch
  git push -q origin feat/17-x
  git fetch -q origin
  git push -q origin --delete feat/17-x
  run_status
  assert_equal "$(jq -c '[.unpushed, .unpulled]' <<<"$output")" "[null,null]"
}

@test "PR のマージキューの状態（有効か・並んでいるときの状態と順番）を、PR の URL から読んで出す" {
  setup_branch
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "CLEAN", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  echo '{"data": {"resource": {"isMergeQueueEnabled": true, "mergeQueueEntry": {"state": "UNMERGEABLE", "position": 2}}}}' >"$FIX/PrQueue.json"
  run_status
  assert_success
  assert_equal "$(jq -c '.pr | [.merge_state, .merge_queue]' <<<"$output")" '["CLEAN",{"enabled":true,"state":"UNMERGEABLE","position":2,"removed":null}]'
  assert_equal "$(grep '^PrQueue ' "$CALLS")" 'PrQueue {"url":"https://github.com/me/demo/pull/5"}'
}

@test "キューに並んでいなければ state・position は null、キューが無ければ enabled は false" {
  setup_branch
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "CLEAN", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  echo '{"data": {"resource": {"isMergeQueueEnabled": true, "mergeQueueEntry": null}}}' >"$FIX/PrQueue.json"
  run_status
  assert_equal "$(jq -c .pr.merge_queue <<<"$output")" '{"enabled":true,"state":null,"position":null,"removed":null}'
  echo '{"data": {"resource": {"isMergeQueueEnabled": false, "mergeQueueEntry": null}}}' >"$FIX/PrQueue.json"
  run_status
  assert_equal "$(jq -c .pr.merge_queue <<<"$output")" '{"enabled":false,"state":null,"position":null,"removed":null}'
}

@test "マージキューの状態を取得できなくても、PR は出す（merge_queue は null）" {
  setup_branch
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "DIRTY", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  FAKE_FAIL=PrQueue run_status
  assert_success
  assert_equal "$(jq -c '.pr | [.number, .merge_state, .merge_queue]' <<<"$output")" '[5,"DIRTY",null]'
}

@test "PR が無ければ、マージキューの状態は問い合わせない" {
  setup_branch
  run_status
  assert_success
  assert_equal "$(grep -c '^PrQueue ' "$CALLS")" 0
}

# キューから外れた PR の応答。$1 は最後のキューの出入りのイベント（JSON）
queue_removed_fixture() {
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "CLEAN", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  jq -n --argjson ev "$1" '{data: {resource: {isMergeQueueEnabled: true, mergeQueueEntry: null,
    timelineItems: {nodes: [$ev]}}}}' >"$FIX/PrQueue.json"
}

@test "衝突してキューから外れたままの PR は、外れた理由と時刻を removed に出す（state は null でも見分けられる）" {
  setup_branch
  queue_removed_fixture '{"__typename": "RemovedFromMergeQueueEvent", "reason": "merge_conflict", "createdAt": "2026-10-04T16:36:30Z"}'
  run_status
  assert_success
  assert_equal "$(jq -c '.pr | [.merge_state, .merge_queue]' <<<"$output")" \
    '["CLEAN",{"enabled":true,"state":null,"position":null,"removed":{"reason":"merge_conflict","at":"2026-10-04T16:36:30Z"}}]'
}

@test "外れた後に push したかは見ない（コミットの時刻は手元でコミットした時刻なので、外れた時刻と比べない）" {
  setup_branch
  queue_removed_fixture '{"__typename": "RemovedFromMergeQueueEvent", "reason": "merge_conflict", "createdAt": "2026-10-04T16:36:30Z"}'
  # 外れた時刻より新しいコミットがあっても、removed は残る
  jq '.data.resource.commits = {nodes: [{commit: {committedDate: "2026-10-04T17:00:00Z"}}]}' "$FIX/PrQueue.json" >"$FIX/q" && mv "$FIX/q" "$FIX/PrQueue.json"
  run_status
  assert_equal "$(jq -r .pr.merge_queue.removed.reason <<<"$output")" merge_conflict
}

@test "キューから外れた後に入れ直していれば（最後のイベントが入れたもの）、removed は null" {
  setup_branch
  queue_removed_fixture '{"__typename": "AddedToMergeQueueEvent"}'
  run_status
  assert_equal "$(jq -c .pr.merge_queue.removed <<<"$output")" null
}

@test "main を取り込むと衝突するかを、手元で確かめて conflicts に出す（作業ツリーとブランチは変えない）" {
  setup_branch
  advance_main 1
  run_status
  assert_equal "$(jq -c '[.behind, .conflicts]' <<<"$output")" "[1,false]"
  conflict_main
  head="$(git rev-parse HEAD)"
  run_status
  assert_success
  assert_equal "$(jq -c '[.behind, .conflicts, .dirty]' <<<"$output")" "[2,true,false]"
  assert_equal "$(git rev-parse HEAD)" "$head"
  assert_equal "$(cat work.txt)" work
}

@test "main が進んでいなければ conflicts は false" {
  setup_branch
  run_status
  assert_equal "$(jq -c .conflicts <<<"$output")" false
}

@test "衝突を確かめられない（git merge-tree --write-tree の無い古い git）ときは conflicts は null" {
  setup_branch
  advance_main 1
  real_git="$(command -v git)"
  # merge-tree だけを、古い git と同じく使い方の誤り（129）で失敗させる
  # shellcheck disable=SC2016 # 偽の git の中身なので、$@ はここでは展開しない
  printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = merge-tree ] && exit 129; done\nexec "%s" "$@"\n' "$real_git" >"$TMP/bin/git"
  chmod +x "$TMP/bin/git"
  git push -q origin feat/17-x
  run_status
  assert_success
  assert_equal "$(jq -c '[.behind, .conflicts, .pushed_behind, .pushed_conflicts]' <<<"$output")" "[1,null,1,null]"
}

@test "手元で main を取り込んだが push していなければ、pushed_behind に push 済みのブランチの遅れを出す" {
  setup_branch
  git push -q origin feat/17-x
  advance_main 2
  run_status
  assert_equal "$(jq -c '[.behind, .pushed_behind]' <<<"$output")" "[2,2]"
  git merge -q --no-edit origin/main
  run_status
  # 手元は最新だが、push 済みのブランチはまだ遅れている
  assert_equal "$(jq -c '[.up_to_date, .unpushed, .pushed_behind]' <<<"$output")" "[true,3,2]"
  git push -q origin feat/17-x
  run_status
  assert_equal "$(jq -c '[.up_to_date, .unpushed, .pushed_behind]' <<<"$output")" "[true,0,0]"
}

@test "取り込みと関係の無いコミットだけが push されていなくても、pushed_behind は 0" {
  setup_branch
  git push -q origin feat/17-x
  echo a >a.txt
  git add a.txt
  git commit -q -m "feat: a"
  run_status
  assert_equal "$(jq -c '[.up_to_date, .unpushed, .pushed_behind]' <<<"$output")" "[true,1,0]"
}

@test "origin にブランチが無ければ pushed_behind は null" {
  setup_branch
  run_status
  assert_equal "$(jq -c .pushed_behind <<<"$output")" null
}

@test "手元で衝突を直して取り込んだが push していなければ、push 済みのブランチの衝突を pushed_conflicts に出す" {
  setup_branch
  git push -q origin feat/17-x
  conflict_main
  git fetch -q origin main
  git merge -q --no-edit origin/main >/dev/null 2>&1 || true
  echo resolved >work.txt
  git add work.txt
  git commit -q --no-edit
  run_status
  assert_success
  # 手元は取り込み済みで衝突しないが、push 済みのブランチはまだ衝突する
  assert_equal "$(jq -c '[.up_to_date, .conflicts, .pushed_behind, .pushed_conflicts]' <<<"$output")" "[true,false,1,true]"
}

@test "push 済みのブランチが遅れていても、衝突しなければ pushed_conflicts は false" {
  setup_branch
  git push -q origin feat/17-x
  advance_main 1
  run_status
  assert_equal "$(jq -c '[.pushed_behind, .pushed_conflicts]' <<<"$output")" "[1,false]"
}

@test "origin にブランチが無ければ pushed_conflicts は null、遅れていなければ false" {
  setup_branch
  run_status
  assert_equal "$(jq -c .pushed_conflicts <<<"$output")" null
  git push -q origin feat/17-x
  run_status
  assert_equal "$(jq -c .pushed_conflicts <<<"$output")" false
}

@test "次にすること（plan）を、branch-plan.sh の判断で出す" {
  setup_branch
  advance_main 1
  run_status
  assert_success
  # PR が無いので、キューを使わないものとして、遅れていれば取り込む
  assert_equal "$(jq -c .plan <<<"$output")" '{"action":"merge","reason":"behind","queue":null,"fallback":null}'
  echo '[{"number": 5, "url": "https://github.com/me/demo/pull/5", "mergeStateStatus": "BEHIND", "isCrossRepository": false}]' >"$FIX/pr-list.json"
  echo '{"data": {"resource": {"isMergeQueueEnabled": true, "mergeQueueEntry": {"state": "QUEUED", "position": 3}}}}' >"$FIX/PrQueue.json"
  run_status
  assert_success
  # キューを使い、main と衝突しないので取り込まず、並んでいることを案内する（最新の main を求められたら、遅れているので取り込む）
  assert_equal "$(jq -c .plan <<<"$output")" '{"action":"none","reason":"no_conflict","queue":"queued","fallback":"merge"}'
}

# 使い方: subjects <組の名前> → push_commits の組の件名を、古い順に「,」でつないで出す
subjects() { jq -r --arg k "$1" '.push_commits[$k] | if . == null then "null" else reverse | map(.subject) | join(",") end' <<<"$output"; }

@test "push で入るコミットを、push_commits.all に出す（取り込みの前の sha が無ければ、組には分けない）" {
  setup_branch
  run_status
  assert_success
  assert_equal "$(jq -c '.push_commits | [.to, .first_push]' <<<"$output")" '["origin/main",true]'
  assert_equal "$(subjects all)" "feat: work"
  assert_equal "$(jq -c '.push_commits | [.main, .pull, .own]' <<<"$output")" "[null,null,null]"
  [[ "$(jq -r '.push_commits.all[0].sha' <<<"$output")" =~ ^[0-9a-f]{7,}$ ]] || fail "sha が短い形の sha ではありません"
}

@test "初回の push では、origin/main に既にある main のコミットを、main の取り込みに数えない（#242）" {
  setup_branch
  advance_main 2
  merged_from="$(git rev-parse HEAD)"
  git fetch -q origin main
  git merge -q --no-edit origin/main
  run_status --merged-from "$merged_from"
  assert_success
  assert_equal "$(jq -r '.push_commits.first_push' <<<"$output")" "true"
  assert_equal "$(subjects main)" "Merge remote-tracking branch 'origin/main' into feat/17-x"
  assert_equal "$(subjects pull)" ""
  assert_equal "$(subjects own)" "feat: work"
  assert_equal "$(jq '.push_commits.all | length' <<<"$output")" "2"
}

@test "pull で作った取り込みのコミットを自分のコミットに数えず、pull で取り込んだ origin のコミットも数えない（#242）" {
  setup_branch
  git push -q origin feat/17-x
  push_from_elsewhere
  advance_main 1
  echo a >a.txt
  git add a.txt
  git commit -q -m "feat: a"
  pulled_from="$(git rev-parse HEAD)"
  git pull -q --no-rebase --no-edit origin feat/17-x
  merged_from="$(git rev-parse HEAD)"
  git fetch -q origin main
  git merge -q --no-edit origin/main
  run_status --merged-from "$merged_from" --pulled-from "$pulled_from"
  assert_success
  assert_equal "$(jq -c '.push_commits | [.to, .first_push]' <<<"$output")" '["origin/feat/17-x",false]'
  assert_equal "$(subjects main)" "main 1,Merge remote-tracking branch 'origin/main' into feat/17-x"
  assert_equal "$(subjects pull)" "Merge branch 'feat/17-x' of $TMP/origin into feat/17-x"
  assert_equal "$(subjects own)" "feat: a"
  # 3つの組を合わせると、push で入るコミットの全部になる（origin に既にある feat: b・feat: work は入らない）
  assert_equal "$(jq '.push_commits | (.main + .pull + .own | map(.sha) | sort) == (.all | map(.sha) | sort)' <<<"$output")" "true"
  assert_equal "$(jq '.push_commits.all | length' <<<"$output")" "4"
}

@test "pull が fast-forward で済んだら、pull の取り込みは空" {
  setup_branch
  git push -q origin feat/17-x
  push_from_elsewhere
  advance_main 1
  pulled_from="$(git rev-parse HEAD)"
  git pull -q --no-rebase --no-edit origin feat/17-x
  merged_from="$(git rev-parse HEAD)"
  git fetch -q origin main
  git merge -q --no-edit origin/main
  run_status --merged-from "$merged_from" --pulled-from "$pulled_from"
  assert_success
  assert_equal "$(subjects pull)" ""
  assert_equal "$(subjects own)" ""
  assert_equal "$(subjects main)" "main 1,Merge remote-tracking branch 'origin/main' into feat/17-x"
}

@test "コミットでない sha や空の値を渡すと止まる" {
  setup_branch
  run_script branch-status.sh --merged-from 0000000000000000000000000000000000000000
  assert_failure 64
  assert_output --partial "コミットではありません"
  run_script branch-status.sh --merged-from
  assert_failure 64
  run_script branch-status.sh --merged-from ""
  assert_failure 64
  assert_output --partial "--merged-from に値（コミットの sha）がありません"
}

@test "pull の後、merge の前に止めたとき（--pulled-from だけ）は、merge の前を HEAD とみなして分ける" {
  setup_branch
  git push -q origin feat/17-x
  push_from_elsewhere
  echo a >a.txt
  git add a.txt
  git commit -q -m "feat: a"
  pulled_from="$(git rev-parse HEAD)"
  git pull -q --no-rebase --no-edit origin feat/17-x
  run_status --pulled-from "$pulled_from"
  assert_success
  assert_equal "$(subjects main)" ""
  assert_equal "$(subjects pull)" "Merge branch 'feat/17-x' of $TMP/origin into feat/17-x"
  assert_equal "$(subjects own)" "feat: a"
  # pull をやめた（取り込む前に戻した）ときも止まらない
  git reset -q --hard "$pulled_from"
  run_status --pulled-from "$pulled_from"
  assert_success
  assert_equal "$(subjects pull)" ""
  assert_equal "$(subjects own)" "feat: a"
}

@test "控えた sha の順番が違う（pull の前が merge の前の祖先でない・merge の前がブランチの祖先でない）と止まる" {
  setup_branch
  git push -q origin feat/17-x
  push_from_elsewhere
  advance_main 1
  pulled_from="$(git rev-parse HEAD)"
  git pull -q --no-rebase --no-edit origin feat/17-x
  merged_from="$(git rev-parse HEAD)"
  git fetch -q origin main
  git merge -q --no-edit origin/main
  # 入れ替えて渡した
  run_script branch-status.sh --merged-from "$pulled_from" --pulled-from "$merged_from"
  assert_failure 64
  assert_output --partial "祖先ではありません"
  # ブランチに無いコミットを merge の前として渡した
  git switch -q -c side "$pulled_from^"
  echo s >s.txt
  git add s.txt
  git commit -q -m side
  side="$(git rev-parse HEAD)"
  git switch -q feat/17-x
  run_script branch-status.sh --merged-from "$side"
  assert_failure 64
  assert_output --partial "feat/17-x の祖先ではありません"
}

@test "署名を表示する設定（log.showSignature）でも、署名の検証の行をコミットに数えない" {
  setup_branch
  use_fake_gpg
  echo signed >signed.txt
  git add signed.txt
  git commit -q -S -m "feat: signed"
  git config log.showSignature true
  run_status
  assert_success
  assert_equal "$(subjects all)" "feat: work,feat: signed"
}

@test "push で入るコミットが多くても（一覧が jq の引数の長さの上限を超えても）止まらない" {
  setup_branch
  # 件名の長いコミットを 2000 件作る（一覧は 128 KiB を超える）
  make_commits feat/17-x 2000
  git reset -q --hard feat/17-x
  run_status --merged-from "$(git rev-parse HEAD)"
  assert_success
  assert_equal "$(jq '.push_commits.all | length' <<<"$output")" "2001"
  assert_equal "$(jq '.push_commits.own | length' <<<"$output")" "2001"
}

@test "--pulled-from だけで、ブランチの祖先でない sha を渡すと止まる" {
  setup_branch
  git switch -q -c side main
  echo s >s.txt
  git add s.txt
  git commit -q -m side
  side="$(git rev-parse HEAD)"
  git switch -q feat/17-x
  run_script branch-status.sh --pulled-from "$side"
  assert_failure 64
  assert_output --partial "--merged-from（無ければ feat/17-x）の祖先ではありません"
}

@test "push で入るコミットを調べる git が失敗したら、空の一覧で組を誤らずに止まる" {
  setup_branch
  advance_main 1
  merged_from="$(git rev-parse HEAD)"
  git fetch -q origin main
  git merge -q --no-edit origin/main
  # 一覧と届くコミットを調べる git（log と、--count の無い rev-list）だけを失敗させる
  make_failing_git
  PATH="$TMP/failgit:$PATH" FAIL_GIT='* rev-list [!-]*' run_script branch-status.sh --merged-from "$merged_from"
  assert_failure 1
  assert_output --partial "push で入るコミットを調べられませんでした"
  PATH="$TMP/failgit:$PATH" FAIL_GIT='* log --no-show-signature *' run_script branch-status.sh
  assert_failure 1
  assert_output --partial "push で入るコミットを調べられませんでした"
  # 失敗させなければ通る（偽の git がほかの呼び出しを邪魔していない）
  PATH="$TMP/failgit:$PATH" FAIL_GIT="" run_script branch-status.sh --merged-from "$merged_from"
  assert_success
}

@test "未コミットの変更を調べる git status が失敗したら、変更が無いとみなさずに止まる" {
  setup_branch
  make_failing_git
  PATH="$TMP/failgit:$PATH" FAIL_GIT='* status --porcelain *' run_script branch-status.sh
  assert_failure 1
  assert_output --partial "未コミットの変更を調べられませんでした"
}
