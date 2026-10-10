---
status: "accepted"
date: 2026-10-10
issue: 323
---

# pr-merge-status.sh は、マージキューの状態を GraphQL で読み、外れた後の push をリポジトリの activity で見る（branch-status.sh もそろえる）

## 背景と課題

`pr-merge-status.sh`（#199）は、PR がマージキューの中か・外れたかを、GraphQL を使わずに、`gh run list --event merge_group` の実行のブランチ名（`gh-readonly-queue/<base>/pr-<番号>-`）と、`gh pr view` の `autoMergeRequest` から推定していた（[ADR 000089](000089-prefer-gh-and-rest-over-graphql.md) の「GraphQL は他に手段が無いときだけ使う」に従ったもの）。この推定には、次の取りこぼしがあった。

* キューに入れた直後で、まだ merge_group の実行が無く、`autoMergeRequest` も無い間は `not_queued` に見える。task-finish が待つかを選ぶ流れが、最も要る時間帯に使われない
* コンフリクトで外れた場合は、CI の実行が作られないので `removed` にならず `not_queued` になる。`branch-status.sh` は GraphQL の `RemovedFromMergeQueueEvent` で外れたことを出すので、スクリプトの間で「外れた」かが食い違う
* 失敗して外れた後に修正を push し、まだ入れ直していない間も、古い失敗の実行が一番新しい実行として残り、`removed` のままになる
* `gh run list --limit 200` はリポジトリ全体の merge_group の実行を新しい方から数えるので、忙しいリポジトリでは自分の PR の実行が窓から外れうる

`branch-status.sh` も、外れた後に push したかを見ない（[ADR 000210](000210-merge-main-only-on-conflict-with-queue.md) の時点で、GitHub から分からないこととして扱った）ので、修正を push した後も `merge_queue.removed` が残り、branch-update が「外れたまま」と案内していた。

キューに並んでいるか（`mergeQueueEntry`）と、キューから外れたイベント（`RemovedFromMergeQueueEvent`）は、`gh pr view` の `--json` にも REST にも無い。つまり、ADR 000089 の「他に手段が無いとき」に当たる。

## 判断の決め手

* キューに入れた直後・コンフリクトで外れた・修正を push した後のそれぞれで、判定が実際の状態と合うこと
* `branch-status.sh`・`pr-watch.sh` と、キューの中か・外れたかの読み方がそろうこと（外れた後の push の扱いも、`branch-status.sh` とそろうこと）
* 判定のロジックを2つのスクリプトで重複させないこと
* 忙しいリポジトリでも、自分の PR の実行を取りこぼさないこと
* GraphQL は他に手段が無いところだけに使うこと（ADR 000089）

## 検討した案

* キューの状態を GraphQL（`mergeQueueEntry`・タイムラインの `RemovedFromMergeQueueEvent`）で読み、外れた後の push をリポジトリの activity（REST）で見て、失敗した CI は外れたイベントのコミットで絞って読む
* これまでどおり、`gh run list` のブランチ名と `autoMergeRequest` から推定する（#199 の形）
* GraphQL で読むが、外れた後の push は見ない（それまでの `branch-status.sh` と同じ形）
* 外れた後の push を `pr-merge-status.sh` だけで見て、`branch-status.sh` は見ないまま残す

## 判断の結果

選んだ案：「キューの状態を GraphQL で読み、外れた後の push をリポジトリの activity で見て、失敗した CI は外れたイベントのコミットで絞って読む」。外れた後の push の判定は、`branch-status.sh` にも入れて、2つのスクリプトの「外れたまま」をそろえる。理由は、決め手のうち、4つの取りこぼしをすべて直し、2つのスクリプトの判定を食い違わせない唯一の案だから。

* キューの状態の問い合わせと判定（キューの中か・外れたままか）は、`common.sh` の `dw_merge_queue_state` 1つにまとめ、`pr-merge-status.sh` と `branch-status.sh` の両方が使う。2つのスクリプトで別々に読むと、同じ PR の判定が食い違うため
* キューを使うか（`enabled`）は、2つのスクリプトとも GraphQL の `isMergeQueueEnabled` で決める。それまでは、`pr-merge-status.sh` が REST のブランチのルール（`dw_merge_queue_enabled`。#199 で `pr-create.sh`・`doctor.sh` の読み方に合わせた）、`branch-status.sh` が GraphQL の `isMergeQueueEnabled`（ADR 000210）と、別々に決めていた。REST の `rules/branches` はルールセットのルールだけを返し、古いブランチ保護の「Require merge queue」でキューを有効にしたリポジトリでは、キューを使っていても false になる。`isMergeQueueEnabled` は PR のマージ先でキューが有効かを GitHub が返すので、どちらの設定でも正しく、キューの状態と同じ1回の問い合わせで読める。キューが無効なら、キューの中・外れたままとはせず、push も読まない。`pr-create.sh`・`doctor.sh` の読み方（ルール）は、この ADR では変えない
* キューの状態（GraphQL）を読めなければ、ブランチのルール（REST の `dw_merge_queue_enabled`）でキューを使うかを確かめる。`isMergeQueueEnabled` に寄せただけでは、キューを使わないリポジトリでも、GraphQL を読めないと止まってしまう（`--wait` も最初の一時的な失敗で止まる）ため。`pr-merge-status.sh` は、ルールでキューを使わないと分かれば warn を出して `not_queued` を返し、使う、またはルールも読めなければ、理由を1行で伝えて止まる。`branch-status.sh` は、理由を warn で出し、ルールでキューを使うと分かれば `enabled` を true・`queued` を null（キューの中か分からない。`branch-plan.sh` の `plan.queue` は `unknown`）にする。`merge_queue` を null にすると、`branch-plan.sh` がキューを使わないリポジトリとみなし、遅れていれば main を取り込んでしまう（ADR 000210 に反する）ため。使わないと分かれば `enabled` を false にし、ルールも読めなければ、これまでどおり `merge_queue` を null にする。ルールは古いブランチ保護のキューを含まないので、この確かめ方は読めないときの代わりにだけ使う
* キューの中か（`queued`）は、`mergeQueueEntry` があるか、タイムラインの最後のキューの出入りのイベント（`ADDED_TO_MERGE_QUEUE_EVENT`・`REMOVED_FROM_MERGE_QUEUE_EVENT`）が入れたもの（入れた直後で、まだ `mergeQueueEntry` に出ていない。入れたイベントから10分まで。それを過ぎても出ないのはイベントの欠けなどとして、並んでいないとみなし、外れた理由は分からないことを warn で伝える。`common.sh` の `DW_QUEUE_ADDED_GRACE_MINUTES`。手元の時計とのずれは扱わない）か、merged の理由で外れたもの（マージの直前で、PR の state がまだ MERGED でない）かで見る。入れた直後で CI の実行が無くても、`pr-merge-status.sh` は `waiting`、`branch-status.sh` は `queued` になる
* 外れたままか（`removed`）は、最後のイベントが merged 以外の理由で外れたもので、その後に push していないかで見る。衝突で外れて CI の実行が無くても外れたままになり、理由（`reason`）も返す
* push したかは、リポジトリの activity（`GET /repos/{owner}/{repo}/activity?ref=refs/heads/<ブランチ>`）の `push`・`force_push` の時刻で見る。GitHub の GraphQL には、PR のコミットを push した時刻が無い（`Commit.pushedDate` は廃止。コミットの時刻は手元でコミットした時刻）が、activity は REST で push の時刻を返す。比べるのは、外れた時刻ではなく、最後にキューに入れた時刻（`AddedToMergeQueueEvent` の時刻。タイムラインの最後の2つのイベントから読む）。キューに並んでいる間の push は、それ自体で PR をキューから外すので、push の時刻が外れた時刻より前になるため。push があれば、直して入れ直す前なので、外れたままとはしない（`pr-merge-status.sh` は `not_queued`、`branch-status.sh` は `merge_queue.removed` が null）。フォークからの PR は、push がこのリポジトリの activity に無いので読まず、外れたままとする（`branch-status.sh` はフォークからの PR をもともと対象にしない）
* push を読めなければ、push は分からないものとして、warn を出して外れたままとみなし、`removed.push_unknown` を true にする（フォークからの PR も true）。task-finish と branch-update は、そのとき、push したかは確かめられなかったこと、もう直して push してあるなら入れ直すだけでよいことを伝える。キューの状態は捨てない（`branch-status.sh` が `merge_queue` を null にすると、`branch-plan.sh` がキューを使わないリポジトリとみなし、遅れていれば main を取り込んでしまう。ADR 000210 に反する）。`pr-merge-status.sh` も止まらない（`--wait` の途中でも待ちを続けられる）
* gh は `common.sh` の `dw_gh_run` 1つで呼ぶ（`dw_merge_queue_state`・`dw_pushed_since`・`pr-merge-status.sh` の `gh pr view`・`gh run list`）。標準出力と標準エラーを分けて受け、成功しても gh がお知らせや警告を標準エラーに出すことがあるので、JSON と混ぜない（混ぜると JSON として読めず、`branch-status.sh` がキューの状態を捨てていた）。失敗の理由は、標準出力の GraphQL の errors[].message を優先し、無ければ標準エラーから gh のお知らせの行を除いた最後の行にして、必ず1行で標準エラーに出す（エラーは1行のメッセージという決まり。呼ぶ場所ごとに受け方がばらばらで、理由が複数行になったり、お知らせが理由になったりしていた）
* warn は「warn: <種類の文>: <変わる値>」の形で出し、`pr-merge-status.sh` の `--wait` の間は、種類ごとに1回だけ出す（`dw_warn_once`。gh のエラーの文は呼ぶたびに変わりうるので、文全体では見分けない）
* 外れる原因になった CI の実行は、`RemovedFromMergeQueueEvent` の `beforeCommit`（キューの一時的なブランチのコミット）で `gh run list --commit` を絞って読む。リポジトリ全体の実行を新しい方から数えないので、窓から外れない

### 結果として起きること

* 良い点：`pr-merge-status.sh` と `branch-status.sh` で、キューの中か・外れたままかの判定がそろう（入れた直後・マージの直前・外れた後の push の扱いも、同じ関数で決まる）
* 良い点：branch-update が、修正を push した後に「外れたまま」と案内しなくなる
* 良い点：task-finish が、キューに入れた直後でも待つかを聞けるようになり、修正を push した後に古い失敗を伝えなくなる
* 悪い点：GraphQL を使う箇所が1つ増える（設計書 §10 の、GraphQL を残している箇所の一覧に足す）。偽の gh のテストでは、`gh api graphql` の答えを用意する
* 悪い点：外れた後の push を見るために、REST の呼び出しが1回増える（外れたままのときだけ）。activity を読めない権限では、push したかが分からず、warn を出して外れたままとみなす（push していても「外れたまま」と案内することがある）
* 悪い点：キューの状態を読めず、ルールでキューを使うと分かったときは、`pr-merge-status.sh` は止まり、`branch-status.sh` はキューの中かを「分からない」と案内する（ルールでは、並んでいるかも外れたかも分からないため）
* 悪い点：`autoMergeRequest` は使わなくなる（キューを使うリポジトリでは、キューに並んでいるかは `mergeQueueEntry` で分かるため）

### 確認

`tests/pr-merge-status.bats` の判定の表で、キューに入れた直後（実行も予約も無い）・コンフリクトで外れた・外れた後に push した・入れ直した後に古い失敗の実行が残っている・実行をコミットで絞って読む、のそれぞれを確かめる。`tests/branch-status.bats` で、外れた後に push した・並んでいる間に push して外れた・入れる前の push・push を読めない・入れた直後・入れてから10分を過ぎた・merged の理由で外れた直後・キューが無効・gh が標準エラーに何か出す・フォークの PR のそれぞれを確かめる。両方のテストで、並んでいる間の push と、push を読めないときの扱いが同じになることを確かめる。キューの状態を読めないとき（ルールでキューを使う・使わない）、GraphQL の errors や gh のお知らせがあるときの理由の1行、warn の種類ごとの1回（`tests/common.bats` の `dw_warn_once`）、`DW_QUEUE_NOW` の誤りも確かめる。

## 各案の長所と短所

### キューの状態を GraphQL で読み、外れた後の push を activity で見る

* 良い点：4つの取りこぼしをすべて直せる
* 良い点：`branch-status.sh`・`pr-watch.sh` と読み方がそろう
* 悪い点：GraphQL と activity の呼び出しが増え、テストの偽の gh も増える

### これまでどおり、実行のブランチ名と autoMergeRequest から推定する

* 良い点：GraphQL を使わない
* 悪い点：入れた直後・衝突で外れた・push した後の判定を直せない（実行が作られないか、古い実行しか無いため）

### GraphQL で読むが、外れた後の push は見ない

* 良い点：それまでの `branch-status.sh` と全く同じ読み方になる
* 悪い点：修正を push した後も `removed` のままで、task-finish が古い失敗を伝える

### 外れた後の push を pr-merge-status.sh だけで見る

* 良い点：`branch-status.sh` と branch-update を変えずに済む
* 悪い点：同じ PR を、`pr-merge-status.sh` は `not_queued`、`branch-status.sh` は外れたままと判定し、スクリプトの間で食い違う

## 補足

* 出典：Issue #323（https://github.com/nakayama-labs/agent-plugins/issues/323）、元の決め事は Issue #199
* [ADR 000089](000089-prefer-gh-and-rest-over-graphql.md) の方針（GraphQL は他に手段が無いときだけ使う）は変えない。この ADR は、#199 で `pr-merge-status.sh` を GraphQL なしで書いた決め事を変え、キューの状態を、他に手段が無いものとして GraphQL で読む箇所に加える
* [ADR 000210](000210-merge-main-only-on-conflict-with-queue.md) は、「外れた後に push したかは GitHub から分からない」（push の時刻が無く、コミットの時刻は使えない）という前提で、`branch-status.sh` と branch-update の案内を決めた。この ADR は、リポジトリの activity で push の時刻を読めることから、その前提を変え、`branch-status.sh` でも外れた後の push を見る。000210 の残りの判断（キューを使うリポジトリでは main と衝突したときだけ取り込み、キューの状態は案内にだけ使う）は変えない
