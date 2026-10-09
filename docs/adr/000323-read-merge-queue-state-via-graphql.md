---
status: "accepted"
date: 2026-10-10
issue: 323
---

# pr-merge-status.sh は、マージキューの状態を GraphQL で読み、外れた後の push をリポジトリの activity で見る

## 背景と課題

`pr-merge-status.sh`（#199）は、PR がマージキューの中か・外れたかを、GraphQL を使わずに、`gh run list --event merge_group` の実行のブランチ名（`gh-readonly-queue/<base>/pr-<番号>-`）と、`gh pr view` の `autoMergeRequest` から推定していた（[ADR 000089](000089-prefer-gh-and-rest-over-graphql.md) の「GraphQL は他に手段が無いときだけ使う」に従ったもの）。この推定には、次の取りこぼしがあった。

* キューに入れた直後で、まだ merge_group の実行が無く、`autoMergeRequest` も無い間は `not_queued` に見える。task-finish が待つかを選ぶ流れが、最も要る時間帯に使われない
* コンフリクトで外れた場合は、CI の実行が作られないので `removed` にならず `not_queued` になる。`branch-status.sh` は GraphQL の `RemovedFromMergeQueueEvent` で外れたことを出すので、スクリプトの間で「外れた」かが食い違う
* 失敗して外れた後に修正を push し、まだ入れ直していない間も、古い失敗の実行が一番新しい実行として残り、`removed` のままになる
* `gh run list --limit 200` はリポジトリ全体の merge_group の実行を新しい方から数えるので、忙しいリポジトリでは自分の PR の実行が窓から外れうる

キューに並んでいるか（`mergeQueueEntry`）と、キューから外れたイベント（`RemovedFromMergeQueueEvent`）は、`gh pr view` の `--json` にも REST にも無い。つまり、ADR 000089 の「他に手段が無いとき」に当たる。

## 判断の決め手

* キューに入れた直後・コンフリクトで外れた・修正を push した後のそれぞれで、判定が実際の状態と合うこと
* `branch-status.sh`・`pr-watch.sh` と、キューの中か・外れたかの読み方がそろうこと
* 忙しいリポジトリでも、自分の PR の実行を取りこぼさないこと
* GraphQL は他に手段が無いところだけに使うこと（ADR 000089）

## 検討した案

* キューの状態を GraphQL（`mergeQueueEntry`・タイムラインの `RemovedFromMergeQueueEvent`）で読み、外れた後の push をリポジトリの activity（REST）で見て、失敗した CI は外れたイベントのコミットで絞って読む
* これまでどおり、`gh run list` のブランチ名と `autoMergeRequest` から推定する（#199 の形）
* GraphQL で読むが、外れた後の push は見ない（`branch-status.sh` と同じ形）

## 判断の結果

選んだ案：「キューの状態を GraphQL で読み、外れた後の push をリポジトリの activity で見て、失敗した CI は外れたイベントのコミットで絞って読む」。理由は、決め手のうち、4つの取りこぼしをすべて直せる唯一の案だから。

* 並んでいるかは `mergeQueueEntry` で見る。入れた直後で CI の実行が無くても `waiting` になる
* 外れたことは、タイムラインの最後のキューの出入りのイベント（`ADDED_TO_MERGE_QUEUE_EVENT`・`REMOVED_FROM_MERGE_QUEUE_EVENT`）で見る（`branch-status.sh` と同じ）。衝突で外れて CI の実行が無くても `removed` になり、理由（`reason`）も返す
* 外れた後に push したかは、リポジトリの activity（`GET /repos/{owner}/{repo}/activity?ref=refs/heads/<ブランチ>`）の `push`・`force_push` の時刻で見る。GitHub の GraphQL には、PR のコミットを push した時刻が無い（`Commit.pushedDate` は廃止。コミットの時刻は手元でコミットした時刻）が、activity は REST で push の時刻を返す。push があれば、直して入れ直す前なので `not_queued` にする。フォークからの PR は、push がこのリポジトリの activity に無いので読まず、`removed` のままにする
* 外れる原因になった CI の実行は、`RemovedFromMergeQueueEvent` の `beforeCommit`（キューの一時的なブランチのコミット）で `gh run list --commit` を絞って読む。リポジトリ全体の実行を新しい方から数えないので、窓から外れない

### 結果として起きること

* 良い点：`pr-merge-status.sh` と `branch-status.sh` で、キューから外れたか（`removed`）の判定がそろう
* 良い点：task-finish が、キューに入れた直後でも待つかを聞けるようになり、修正を push した後に古い失敗を伝えなくなる
* 悪い点：GraphQL を使う箇所が1つ増える（設計書 §10 の、GraphQL を残している箇所の一覧に足す）。偽の gh のテストでは、`gh api graphql` の答えを用意する
* 悪い点：外れた後の push を見るために、REST の呼び出しが1回増える（外れたままのときだけ）。activity を読めない権限では止まる
* 悪い点：`autoMergeRequest` は使わなくなる（キューを使うリポジトリでは、キューに並んでいるかは `mergeQueueEntry` で分かるため）

### 確認

`tests/pr-merge-status.bats` の判定の表で、キューに入れた直後（実行も予約も無い）・コンフリクトで外れた・外れた後に push した・入れ直した後に古い失敗の実行が残っている・実行をコミットで絞って読む、のそれぞれを確かめる。

## 各案の長所と短所

### キューの状態を GraphQL で読み、外れた後の push を activity で見る

* 良い点：4つの取りこぼしをすべて直せる
* 良い点：`branch-status.sh`・`pr-watch.sh` と読み方がそろう
* 悪い点：GraphQL と activity の呼び出しが増え、テストの偽の gh も増える

### これまでどおり、実行のブランチ名と autoMergeRequest から推定する

* 良い点：GraphQL を使わない
* 悪い点：入れた直後・衝突で外れた・push した後の判定を直せない（実行が作られないか、古い実行しか無いため）

### GraphQL で読むが、外れた後の push は見ない

* 良い点：`branch-status.sh` と全く同じ読み方になる
* 悪い点：修正を push した後も `removed` のままで、task-finish が古い失敗を伝える

## 補足

* 出典：Issue #323（https://github.com/nakayama-labs/agent-plugins/issues/323）、元の決め事は Issue #199
* [ADR 000089](000089-prefer-gh-and-rest-over-graphql.md) の方針（GraphQL は他に手段が無いときだけ使う）は変えない。この ADR は、#199 で `pr-merge-status.sh` を GraphQL なしで書いた決め事を変え、キューの状態を、他に手段が無いものとして GraphQL で読む箇所に加える
* [ADR 000210](000210-merge-main-only-on-conflict-with-queue.md) と `branch-status.sh` は、外れた後に push したかを見ない（GitHub から分からないこととして扱った）。この ADR では `pr-merge-status.sh` だけで activity を使って見る。`branch-status.sh` の扱いは変えない
