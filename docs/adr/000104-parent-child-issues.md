---
status: "accepted"
date: 2026-10-04
issue: 104
---

# ざっくりした仕様を GitHub のサブ Issue で親子に分けて管理し、Story Point は子にだけ付ける

## 背景と課題

ざっくりした仕様を、着手できる大きさに分けて管理したい。Issue の親子（GitHub のサブ Issue）を、起票からどう扱うか。#103 で `issue-create.sh` が親への紐付け（`--parent N`）に対応し、#104 で `task-create` から親子の Issue をまとめて起票できるようにした。

## 判断の決め手

* 同じ作業を、親と子とで二重に数えないこと
* 親子の全体を見通せる深さにとどめること
* 親子をまとめて起票するときも、確認で全体を見られること

## 検討した案

* GitHub のサブ Issue で親子を紐付ける
  * 深さの上限：既定 3 層（設定 `sub_issues.max_depth` で 1〜3）、目安は 2 層
  * GitHub が作れる 8 層までを許す

## 判断の結果

選んだ案：「GitHub のサブ Issue で親子を紐付け、深さは既定 3 層（目安 2 層）までにする」。

* 親の Issue の下に、子の Issue を GitHub のサブ Issue として紐付ける（REST の `issues/{親の番号}/sub_issues`）。親は同じリポジトリの Issue に限る。
* 親と子は `task-create` でまとめて下書きし、確認の preview に親子の木と各 Issue の本文を入れる。確認を取ってから、親 → 子の順に起票して紐付ける。既にある Issue を親に指定して、子だけを足して起票することもできる。
* **Story Point は子にだけ付ける**。親にも付けると、同じ作業を親と子とで二重に数えることになり、親の大きさは子の合計で分かるため。親にする Issue に Story Point が付いていたら、子を足すときに `issue-create.sh` が空欄にする。
* 深さは「仕様 → 着手できる作業」の 2 層を目安にし、必要なら 3 層まで作れる。GitHub は 8 層まで作れるが、深いと全体を見通せなくなるので、3 層より深くはしない。目安より深い Issue を作るときは警告し、`task-create` は起票の前にユーザーに確認する。上限を超える紐付けと、存在しない親は、起票の前に止める。

### 結果として起きること

* 良い点：大きな仕様を、着手できる作業の単位に分けたまま、親の Issue で進み具合を見られる。
* 悪い点：子が全部閉じても、GitHub は親を自動で閉じない。親は、最後の子を閉じた後に人が閉じる。
* 親子をまとめて起票すると続けて起票するので、Project の自動追加と `gh project item-add` が重なって「Content already exists」で失敗しやすい。この失敗のときだけ、待って最大 3 回まで再試行する（PR #146）。

### 確認

`tests/issue-create.bats` で、`--parent` の紐付け・深さの上限・存在しない親・親の Story Point を空欄にすることを確かめる。`tests/skills.bats` で、`task-create` の手順（親から先に起票・親は Story Point なし・既存の親）を確かめる。

## 補足

* 出典：Issue #103（https://github.com/nakayama-labs/agent-plugins/issues/103）、PR #130（https://github.com/nakayama-labs/agent-plugins/pull/130）、Issue #104（https://github.com/nakayama-labs/agent-plugins/issues/104）、PR #146（https://github.com/nakayama-labs/agent-plugins/pull/146）、設計書 §4「親子の Issue（サブ Issue）」
* #103 と #104 の判断を1つの ADR にまとめた。date と issue は #104 のもの。
* 後に、親には着手しない（`task-start` は親で止まり、開いている子を案内する）ことと、親を取りやめるときに開いている子孫の扱いを選ばせることを決めた（設計書 §4）。
* 大きな依頼を分割する手順（詰める・縦に切る）は、#104 の範囲外とした。
