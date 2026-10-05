---
status: "accepted"
date: 2026-10-03
issue: 65
---

# Issue の終わり方を完了とやめたの2つに分け、やめた Issue は task-cancel で閉じて作業も片付ける

## 背景と課題

誤って起票した Issue や、やらないことにした Issue を閉じる手順が、プラグインにも設計書にも無かった（#63 は手で閉じた）。着手した後にやめたときは、ワークツリー・ブランチ・PR も残る。`task-finish` はマージされた作業の片付けなので、やめた作業には使えない。やめた Issue を、どう閉じ、残った作業をどう片付けるか。

## 判断の決め手

* やめた理由と経緯が、後から分かること
* マージした後の片付け（`task-finish`）と取り違えないこと
* マージしていない作業を、黙って失わないこと
* 途中で止まっても、やり直せること

## 検討した案

* 名前：`task-close`・`issue-close.sh`（最初の形）
* 名前：`task-cancel`・`issue-cancel.sh`

## 判断の結果

Issue の終わり方を、完了（completed。PR のマージで閉じる）とやめた（not planned・duplicate）の2つに分ける。完了は PR が閉じ、やめたときは `task-cancel` が閉じる。`task-finish` は Issue を閉じたり変えたりせず、マージした後の手元を片付ける。

選んだ案（名前）：「`task-cancel`・`issue-cancel.sh`」。理由は、close は完了で閉じるときにも使う言葉で、`task-finish` と混同しやすいから。

やめるときの決まりは次のとおり。

* 閉じる前に、理由と参照先（代わりに作業する Issue など）を `#N` でコメントする。理由が空（空白だけを含む）なら閉じない。
* not planned で閉じる。重複のときは、元の Issue の番号が分かるときだけ duplicate で閉じて元の Issue に紐付ける。誤って紐付けると影響が大きいので、迷うときは not planned にする。
* Project からは外さない。後からボードで経緯を参照できるようにするため。
* Story Point は残す。見積もりも記録の一部で、集計する仕組みも無いので、消す理由が無い。
* 着手した後にやめたときは、開いている PR に同じ理由をコメントしてマージせずに閉じ、リモートのブランチ・手元のワークツリーとブランチを削除する。マージしていない作業は消すと戻せないので、失うもの（base_branch に無いコミット・未コミットの変更・git が無視するファイル・サブモジュールのリモートに無いコミット）を確認に出す。
* Issue → PR とリモートのブランチ → 手元の順に行う。どのスクリプトも何度実行しても同じ結果になるので、途中で止まっても再実行で続きから進む。

### 結果として起きること

* 良い点：やめた Issue にも理由と参照先が残り、ボードからも経緯を追える。
* 良い点：やめた作業の片付けと、マージした作業の片付けが、別のスキルに分かれる。
* Project の自動化（Item closed）が有効なら、やめた Issue も完了した Issue と同じく Done に移る。

### 確認

`tests/issue-cancel.bats` と `tests/cleanup.bats`（`--abandon`）で、理由が空なら閉じないこと、再実行で同じ結果になること、失うものが一覧に出ることを確かめる。

## 補足

* 出典：Issue #65（https://github.com/nakayama-labs/agent-plugins/issues/65）、PR #90（https://github.com/nakayama-labs/agent-plugins/pull/90）、設計書 §4「やらない Issue を閉じる」
* 作業の途中で Issue の範囲を広げた。最初は not planned で閉じるだけの `task-close` だったが、名前を変え、duplicate と、やめた作業の片付けを足した（PR #90）。
* GitHub の操作を gh のサブコマンドと REST に寄せる方針は、この Issue の範囲から外し、#89 で決めた（[000089](000089-prefer-gh-and-rest-over-graphql.md)）。
