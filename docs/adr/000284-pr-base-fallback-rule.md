---
status: "accepted"
date: 2026-10-10
issue: 284
---

# PR のマージ先を使えないときは、変更を加える処理は止まり、読むだけの処理は警告して base_branch で続ける

## 背景と課題

既にある PR のマージ先は、設定の `base_branch` と違うことがある（例：`base_branch` は main、PR は release/v1 に向いている）。#284 で、branch-update（`branch-status.sh`）・pr-create（`pr-create.sh`）・レビュー（`review-perspectives.sh --auto`）・task-auto の確認が、開いた PR があればそのマージ先（`baseRefName`）を使うようにした。

ところが、PR のマージ先を、そのままは使えないことがある。

* `baseRefName` が、git のブランチ名として使えない値（`-x`・`+x`・`HEAD`・制御文字を含む値など）
* 同じブランチに、fork でない開いた PR が複数あり、マージ先が違う（gh の並び順で選ぶマージ先が変わる）
* PR のマージ先を origin から取得できず、手元にも無い

これまで、このときの扱いは処理ごとに違っていた。base_branch に戻すもの、止まるもの、JSON として読めないと落ちるものがあった。base_branch に戻すと、release/v1 に向いた PR に main を取り込んだり、main に対して先行を確かめて push したりする。これは #284 が直そうとしている取り違えそのものである。一方、レビューのように差分を読むだけの処理まで止めると、作業が進まなくなる。使えないときに戻すか止めるかを、どう決めるか。

## 判断の決め手

* マージ先を取り違えたまま、取り込みや push のような、GitHub やブランチに残る変更をしないこと
* 読むだけの処理は、マージ先が確かでなくても止めずに続けられ、確かでないことが人に伝わること
* 規則が1つで、処理ごとに食い違わないこと

## 検討した案

* どれも base_branch に戻す（警告だけ出す）
* どれも止める
* 変更を加える処理は止め、読むだけの処理は警告して base_branch で続ける

## 判断の結果

選んだ案：「変更を加える処理は止め、読むだけの処理は警告して base_branch で続ける」。理由は、取り違えると困る取り込みと push だけを止め、差分を読むだけのレビューや確認は、警告付きで進められるから。

* PR のマージ先をそのまま使えないときは、理由を `fallback` に出す。理由は `invalid_name`（ブランチ名として使えない。マージ先は base_branch）、`multiple_prs`（マージ先の違う開いた PR が複数ある。マージ先は最初の PR のもの）、`fetch_failed`（取得できず手元にも無い。マージ先は base_branch）の3つ。
* 変更を加える処理は、`fallback` があれば終了コード 2 で止まる。対象は、branch-update の取り込みに使う `branch-status.sh` と、`pr-create.sh` の push である。マージ先を取得できないときも、同じく終了コード 2 で止まる。gh で PR を読めない（gh が失敗した・JSON でない応答）ときも、PR が別のマージ先に向いているかが分からないので止まる（gh が入っていないときだけは、PR が無いものとして base_branch を使う）。
* `pr-create.sh --dry-run` も、本番と同じく止まる。dry-run は、本番で何が起きるかを先に見せるためのものだからである。dry-run ではマージ先を取得（fetch）しないので、手元の origin/<マージ先> で先行を数える。手元に無ければ、確認を飛ばして `ahead` を null にする。本番は取得し直して、push の前に確かめる。
* 読むだけの処理は、警告して続け、`fallback` を出力に出す。対象は、`merge-target.sh`・`review-perspectives.sh --auto`（`context.fallback`）・pr-create の手順2・task-auto の確認である。スキルは、`fallback` が null でなければ、その旨をユーザーに伝える。
* 次は `fallback` にしない。開いた PR が無いときは、base_branch を使う。PR の `baseRefName` が無いか空のときは、#178 のとおり base_branch を使う。マージ先が同じ PR が複数あるときは、そのマージ先を使う。
* 規則の正本は `plugins/dev-workflow/scripts/lib/common.sh` の「PR のマージ先」のコメントで、設計書 §10 に要約を書く。変更を加える処理は `dw_pr_pick_strict`・`dw_fetch_target_strict`、読むだけの処理は `dw_merge_target` を使う。

### 結果として起きること

* 良い点：マージ先を取り違えたまま、取り込みや push をしない。
* 良い点：レビューや確認は、マージ先が確かでなくても進み、確かでないことが警告と `fallback` で伝わる。
* 悪い点：`branch-status.sh` は、マージ先の名前が使えないときに、これまでは base_branch に戻していたが、止まるようになった。マージ先を取得できないときの終了コードは 1 から 2 になった。
* 悪い点：読むだけの処理は、取り違えたマージ先との差を読むことがある（警告と `fallback` で伝える）。

### 確認

`tests/common.bats`（`dw_pr_pick` の各場合）、`tests/merge-target.bats`（`fallback`・`from`）、`tests/branch-status.bats`・`tests/pr-create.bats`（終了コード 2 で止まること、dry-run の扱い）、`tests/review-perspectives.bats`（base_branch に戻して続けること）で確かめる。

## 各案の長所と短所

### どれも base_branch に戻す（警告だけ出す）

* 良い点：どの処理も止まらない。
* 悪い点：release/v1 に向いた PR に main を取り込むなど、#284 が直そうとしている取り違えが、マージ先を使えないときに残る。

### どれも止める

* 良い点：取り違えが起きない。
* 悪い点：差分を読むだけのレビューや確認まで止まり、人が PR のマージ先を直すまで作業が進まない。

### 変更を加える処理は止め、読むだけの処理は警告して base_branch で続ける

* 良い点：取り違えると困る処理だけを止め、ほかは進められる。
* 悪い点：処理ごとに、止める側か読むだけの側かを決めて守る必要がある（規則を1か所に書き、共通の関数で守る）。

## 補足

* 出典：Issue #284（https://github.com/nakayama-labs/agent-plugins/issues/284）、#178（既にある PR のマージ先を `pr_base` として使う）、設計書 §10「PR のマージ先」
* 関係する ADR：[ADR 000284 merge-target.sh](000284-merge-target-script.md)（読むだけの処理がマージ先を決めるスクリプト）
