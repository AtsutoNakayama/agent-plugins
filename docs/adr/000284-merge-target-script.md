---
status: "accepted"
date: 2026-10-10
issue: 284
---

# スキルがマージ先との差を読むときは、マージ先を merge-target.sh で決め、自分で組み立てない

## 背景と課題

pr-create の手順2（PR に入る変更を読む）と task-auto の確認（コミットがあるか）は、SKILL.md の手順として `origin/<base_branch>..HEAD` を読んでいた。#284 で、既にある PR のマージ先が設定の `base_branch` と違うときは、PR のマージ先を使うことにした。

このマージ先を SKILL.md の文章で決めさせると、次の値の組み合わせを AI が組み立てることになる。開いた PR があるか、fork の PR か、`baseRefName` が空か、名前が使えるか、取得できるか。どれも gh と git の出力だけで決まる判断なのに、bats で確かめられない。また、スクリプトの側（`branch-status.sh`・`pr-create.sh`・`review-perspectives.sh`）にも同じ判断があり、少しずつ食い違っていた（#284 のレビュー）。スキルにマージ先をどう渡すか。

## 判断の決め手

* gh と git の出力だけで決まる判断は、スクリプトに置き、bats で確かめられること
* マージ先の決め方が1か所にあり、スキルとスクリプトで食い違わないこと
* スキルが使う前に、マージ先が最新になっていること（取得していない ref で差分を読まない）

## 検討した案

* SKILL.md に決め方を書き、AI に組み立てさせる（`gh pr list` の出力を読ませる）
* 既にあるスクリプトの出力に、マージ先を足す（`branch-status.sh` など）
* マージ先を決めて取得するだけの、新しいスクリプト `merge-target.sh` を足す

## 判断の結果

選んだ案：「マージ先を決めて取得するだけの、新しいスクリプト `merge-target.sh` を足す」。理由は、pr-create の手順2と task-auto の確認は、差分を読む前にマージ先だけが要り、既にあるスクリプトはどれも別の目的（`branch-status.sh` は取り込みの計画、`pr-create.sh` は push と PR の作成）で、読むだけの用途に使うと余計な処理や止まる条件が付くから。

* `plugins/dev-workflow/scripts/merge-target.sh` は、今のブランチのマージ先を決めて origin から取得し、JSON で出力する。出力は `branch`・`base_branch`・`target`・`ref`（`origin/<target>`）・`from`（`pr` か `base_branch`）・`pr`・`fetched`・`fallback` である。git の操作は fetch だけで、GitHub には書き込まない。
* 本体は `lib/common.sh` の `dw_merge_target` で、`review-perspectives.sh --auto` も同じものを呼ぶ。マージ先の選び方は `dw_pr_pick` にまとめる。
* pr-create の SKILL.md の手順2と task-auto の SKILL.md の確認は、`merge-target.sh` の `ref` を使って差分やコミットを読む。マージ先を自分で組み立てない。`fallback` が null でなければ、その旨を伝える。
* PR のマージ先を使えないときの扱いは、[ADR 000284 の規則](000284-pr-base-fallback-rule.md)に従う。`merge-target.sh` は読むだけの側である。
* レビューの観点の担当者（`perspective-reviewer`）への依頼には、`review-perspectives.sh --auto` が決めたマージ先（`context.target`）を足す。担当者がマージ先を決め直さないためである（main-drift の観点が使う）。

### 結果として起きること

* 良い点：マージ先の決め方が bats で確かめられ、スキルとスクリプトで食い違わない。
* 良い点：スキルが読む前に、マージ先が取得されている。
* 悪い点：スクリプトが1つ増え、出力の項目（`fallback`・`from` など）は、スキルが使う形式として、後から変えにくくなる。

### 確認

`tests/merge-target.bats` で、PR が無い・同じリポジトリの PR・fork の PR だけ・`baseRefName` が空・使えない名前・複数の PR・取得できない・設定を読めない場合の出力を確かめる。`tests/skills.bats` で、pr-create・task-auto の SKILL.md が `merge-target.sh` を使い、`origin/<base_branch>` が残っていないことを確かめる。

## 各案の長所と短所

### SKILL.md に決め方を書き、AI に組み立てさせる

* 良い点：スクリプトが増えない。
* 悪い点：bats で確かめられず、空の値や fork の PR のような境目を AI が取り違えることがある。取得もしないので、手元に無い・古い ref を読む。

### 既にあるスクリプトの出力に、マージ先を足す

* 良い点：スクリプトが増えない。
* 悪い点：`branch-status.sh` は取り込みの計画のために遅れや衝突を調べ、`pr-create.sh` は push の前の検証で止まる。読むだけの用途に使うと、余計な処理と止まる条件が付く。

### マージ先を決めて取得するだけの、新しいスクリプト `merge-target.sh` を足す

* 良い点：目的が1つで、読むだけの側の規則（警告して続ける）を守れる。
* 悪い点：スクリプトと出力の形式が増える。

## 補足

* 出典：Issue #284（https://github.com/nakayama-labs/agent-plugins/issues/284）、設計書 §10
* 関係する ADR：[ADR 000284 の規則](000284-pr-base-fallback-rule.md)（PR のマージ先を使えないときの扱い）
