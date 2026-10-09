---
status: "accepted"
date: 2026-10-10
issue: 339
---

# 無人の push で止めるパスを `.github/` 以下の全体とどの階層の `.claude/` 以下にし、push の回数は PR の head が進んだ `repair-run` だけを数え、止まった理由の種類は `repair-next.sh` の stop の理由にする

## 背景と課題

[ADR 000285](000285-unattended-pr-repair-scope.md) は、無人の修復について次を決めた。#287 の自動のレビューで、それぞれに穴が見つかった（#331・#332）。

* 無人の push で止めるパスは `.github/workflows/` と `.claude/`。しかし、`.github/actions/`・`.github/scripts/`（workflow が呼ぶスクリプト）・`CODEOWNERS` なども CI と権限に影響し、入れ子の `.claude/`（モノレポのパッケージの中など）も、そのディレクトリで動く Claude の権限と設定に影響する。`repair-push-check.sh` は、リポジトリ直下の `.claude/` しか見ていなかった。
* push の回数は、push の前に付ける `repair-run` のコメントの数で数える。push の前にセッションが落ちたり、失敗の追記に失敗したりすると、push していない回も数えられ、`repair.max_pushes_per_pr` の上限に早く達する。
* 止まるときの理由の種類は `push-limit`・`same-failure`・`other` のマーカーで残す。しかし、branch-update の無人の手順は常に `other` を書いており、見回りから止まった理由を見分けられない。また、Issue のコメントは `auto-hold.sh` が先頭に実行の印を足すので、「1行目にマーカーを入れる」という手順は成り立っていなかった。

無人で変えてはいけないパスをどこまでにするか。push していない回を数えないには、どう数えるか。止まった理由の種類を、どう決めて、どう残すか。

## 判断の決め手

* 無人の実行が、CI・権限・Claude の設定を変えて main に入る道を残さないこと（ADR 000285 の「無人で読む入力は信用しない」）
* push していない回で上限に達して、直せる PR が止まらないこと
* 数え方が、コメントの追記のような後からの操作の成否に頼らないこと（セッションが落ちても正しく数えられる）
* 止まった理由の種類が、判定のスクリプトの値と一対一で、手で言い換えないこと
* 同じ実行のコメントの見分け方（`auto-hold.sh` の実行の印）を壊さないこと

## 検討した案

止めるパス

* ADR 000285 のまま（`.github/workflows/` とリポジトリ直下の `.claude/`）
* `.github/workflows/`・`.github/actions/`・`.github/scripts/` を並べ、`.claude/` はどの階層も止める
* リポジトリ直下の `.github/` 以下の全体と、どの階層の `.claude/` 以下を止める

push の回数の数え方

* ADR 000285 のまま、`repair-run` の数で数え、失敗した回はコメントに追記して数え落とす
* push の後に `repair-run` を付ける（push が済んだ回だけにコメントがある）
* `repair-run` に push の前の PR の head の sha を書き、PR の head がそこから進んだ回だけを、sha ごとに1回として数える

止まった理由の種類

* ADR 000285 のまま、`push-limit`・`same-failure`・`other` の3つから選ぶ
* `repair-next.sh` の stop の `reason` をそのまま使い、表の外で止まるときは `other` にする。印は `auto-hold.sh` が `--repair-reason` で足す

## 判断の結果

選んだ案：止めるパスは「リポジトリ直下の `.github/` 以下の全体と、どの階層の `.claude/` 以下」、数え方は「`repair-run` に push の前の PR の head の sha を書き、head が進んだ回だけを数える」、理由の種類は「`repair-next.sh` の stop の `reason` をそのまま使い、`auto-hold.sh` が印を足す」。

### 止めるパス

* `repair-push-check.sh` は、push で origin に入る変更に、次のパスがあれば `ok` を false にする。取り込んだ `base_branch` と同じ内容のパスは、今までどおり数えない。
  * リポジトリ直下の `.github/` 以下のすべて（`workflows/` だけでなく、`actions/`・`scripts/`・`CODEOWNERS`・`dependabot.yml` なども）
  * どの階層の `.claude/` 以下も（`.claude/…` と `…/.claude/…`）
  * `.github`（直下）・`.claude`（どの階層も）という名前そのもの。ファイル・シンボリックリンク・サブモジュール（gitlink）にすると、中身を差し替えられるため
* パスは大文字と小文字を区別せずに照らす（`.Claude/`・`.GitHub/` も止める）。大文字と小文字を区別しないファイルシステム（macOS・Windows の既定）では、`.Claude/` も `.claude/` として読まれるため。
* 入れ子の `.github/`（`docs/.github/` など）は、GitHub が読まないので止めない。名前が似ているだけのパス（`.githubx/`・`.claudex/`・`.claude.md`）も止めない。
* 衝突の直し方で「直すのに変更が要るなら止まる」とするパスも、同じ範囲にする。

### push の回数の数え方

* `repair-run` のマーカーを `<!-- dev-workflow:repair-run head=<sha> -->` にする。`<sha>` は、push で進める前の PR の head の sha（`gh pr view --json headRefOid`。40 桁）。
* 見回りは、`repair-run` のうち、今の PR の head が `head` の sha と違うもの（head がそこから進んだもの）だけを、`head` の値ごとに1回として数える。無人の push は強制をしない fast-forward だけなので、同じ sha から進める push は1回しか無く、同じ sha で何度試しても1回になる。
* push に失敗した回、コメントを付けた後に push の前で止まった・落ちた回は、PR の head がその sha のままなので数えない。その後に別の実行が同じ sha から push すれば、その sha が1回と数えられる。
* 人の push で head が進んだときは、ADR 000285 の「再開の起点」で数え直しになるので、起点より前の `repair-run` は数えない（変えない）。
* `head` の無い `repair-run`（この ADR より前の形式）は、ADR 000285 のとおり1つを1回と数える（少なく数えて上限を超えないように、多い側に倒す）。
* push に失敗したときに `repair-run` に失敗を追記する手順は残す。数え方には使わず、PR を読む人が、push していない回だと分かるようにするためのものにする。
* コメントを付ける時機（push の前）は変えない。push の後に付けると、push の後に落ちた回の記録が残らず、上限が効かなくなるため。

### 止まった理由の種類

* 理由の種類は、`repair-next.sh` が `stop` を返したときは、その `reason`（`base_mismatch`・`recheck_exhausted`・`dirty`・`unknown_plan`・`checks_unconfirmed`・`same_failure`・`forbidden_paths`）をそのまま使う。表の外で止まるとき（止まる衝突・表の `action` で決まらない場面など）は `other` にする。ADR 000285 の `same-failure` は `same_failure` に、`push-limit` は、見回りが上限で止めるときの `push_limit` に、それぞれ書き方をそろえる（英小文字・数字・`_`）。
* 印は、`auto-hold.sh --repair-reason <種類>` が、実行の印（`<!-- dev-workflow:task-auto run=<id> -->`）の次の行に `<!-- dev-workflow:repair-stopped reason=<種類> -->` として足す。止まった理由の本文には書かない。本文の先頭は実行の印のままなので、同じ実行のコメントの見分け方は変わらない。`--repair-reason` は、英小文字で始まり英小文字・数字・`_` だけの値しか受け付けない（印を `-->` で閉じさせない）。
* 見回りは、Issue のコメントの中の `repair-stopped` の印で、止まった理由を見分ける。

### 結果として起きること

* 良い点：workflow が呼ぶスクリプトや、入れ子の Claude の設定を、無人の実行が変えて push できなくなる。
* 良い点：push していない回で上限に達しない。数え方が、追記の成否やセッションが落ちたかに左右されない。
* 良い点：止まった理由の種類が、判定のスクリプトの値と同じなので、見回りや人が、理由ごとに扱いを変えられる。
* 悪い点：`.github/` の中の、CI と関係の薄いファイル（Issue のテンプレートなど）の衝突でも、無人では直さずに止まる。
* 悪い点：見回りの数え方が、コメントの数を数えるだけより複雑になる（PR の head と、`repair-run` の `head` を比べる）。
* 悪い点：理由の種類の名前が `repair-next.sh` の値に結び付くので、その値の名前を変えると、見回りの側も直す必要がある。

### 確認

* `tests/repair-push-check.bats` で、`.github/` 以下の workflows 以外のパス・入れ子の `.claude/`・名前が似ているだけのパス・取り込んだ main と同じ内容の入れ子の `.claude/` を確かめる。
* `tests/auto-hold.bats` で、`--repair-reason` の印の位置・同じ実行の再試行・使えない文字を確かめる。`tests/repair-next.bats` で、stop の `reason` がどれも `--repair-reason` に渡せる形であることを確かめる。
* `tests/skills.bats` で、branch-update の無人の手順に、`repair-run` の `head`・数え方・`--repair-reason` の渡し方が書かれていることを確かめる。
* `repair-run` を数える見回りのスクリプトは、見回りのワークフロー（#341）で実装し、そこで、push していない回を数えないことを bats で確かめる。

## 各案の長所と短所

### 止めるパスを ADR 000285 のままにする

* 良い点：止まる場面が少なく、無人で直せる範囲が広い。
* 悪い点：workflow が呼ぶスクリプトや action、入れ子の `.claude/` を、無人の実行が変えられる。

### `.github/` の下のディレクトリを並べる

* 良い点：Issue のテンプレートなど、CI と関係の薄いファイルでは止まらない。
* 悪い点：`CODEOWNERS`・`dependabot.yml` のように権限や自動の更新に関わるファイルや、今後足される場所を、並べ漏らす。

### `.github/` 以下の全体と、どの階層の `.claude/` 以下を止める

* 良い点：並べ漏らしが無く、規則が短い。
* 悪い点：CI と関係の薄いファイルでも止まる（人が直す）。

### `repair-run` の数で数え、失敗は追記で数え落とす（ADR 000285 のまま）

* 良い点：数え方が単純。
* 悪い点：push の前に落ちた回や、追記に失敗した回が数えられ、上限に早く達する。

### push の後に `repair-run` を付ける

* 良い点：push した回だけにコメントがある。
* 悪い点：push の後、コメントの前に落ちると、push した回が数えられず、上限が効かない（暴走を止められない側に倒れる）。

### `repair-run` に push の前の head の sha を書き、head が進んだ回だけ数える

* 良い点：push の前にコメントを付けたまま、push していない回を、後からの操作なしに見分けられる。
* 悪い点：見回りが、PR の今の head と、コメントの sha を比べる必要がある。

### 理由の種類を3つから選ぶ（ADR 000285 のまま）

* 良い点：種類が少なく、見回りの扱いが単純。
* 悪い点：branch-update の無人の手順で止まる理由の多くが `other` になり、見分けられない。

### `repair-next.sh` の stop の `reason` をそのまま使い、`auto-hold.sh` が印を足す

* 良い点：手で言い換えず、判定のスクリプトの値と一対一になる。印の位置と書き方をスクリプトが決めるので、本文の書き方に左右されない。
* 悪い点：`auto-hold.sh` に引数が1つ増える。

## 補足

* 出典：Issue #339（#331・#332 をまとめたもの）。どちらも #287 の自動のレビューで見つかった指摘。
* [ADR 000285](000285-unattended-pr-repair-scope.md) を一部だけ変える。変えるのは、「直す対象と止まる条件」「返信と resolve」「無人で push する条件」の、無人で変えてはいけないパス（`.github/workflows/` と `.claude/` → リポジトリ直下の `.github/` 以下の全体と、どの階層の `.claude/` 以下）と、「無人で push する条件」の push の回数の数え方（`repair-run` の数 → PR の head が進んだ `repair-run` を、`head` の sha ごとに1回）と、「状態の持ち方」の止まった理由の種類（`push-limit`・`same-failure`・`other` → `repair-next.sh` の stop の `reason`・`push_limit`・`other`）。それ以外の判断は変えない。ADR 000285 は書き換えない。
