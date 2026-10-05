---
status: "accepted"
date: 2026-10-03
issue: 89
---

# GitHub の操作は gh のサブコマンドと REST で行い、GraphQL は他に手段が無いときだけ使う

## 背景と課題

#65 で、`issue-cancel.sh` を GraphQL から gh のサブコマンドと REST に置き換えた。あわせて、gh は新しいものを前提にし、古い gh のための回り道はせず、古ければ更新を促すことにした。これはリポジトリ全体の方針なので、#65 の範囲から外して決める。既にあるスクリプト（`issue-create.sh`・`status-set.sh`・`setup/setup-project.sh`・`lib/common.sh`）には、GraphQL を使っている箇所がまだあった。

## 判断の決め手

* 何をしているかが読んで分かること
* ページ送りやスキーマの変化への対応を、自分で書かずに済むこと
* 偽物の gh でテストしやすいこと
* Issue や Project を、node id ではなく番号・URL で指定できること

## 検討した案

* GitHub の操作は gh のサブコマンドと REST で行い、GraphQL は他に手段が無いときだけ使う
* GraphQL を使い続ける（それまでの形）

## 判断の結果

選んだ案：「GitHub の操作は gh のサブコマンドと REST で行い、GraphQL は他に手段が無いときだけ使う」。理由は次の4つ。

* 読みやすい：クエリの文字列が無く、何をしているかがコマンド名で分かる。
* 保守しやすい：ページ送りやスキーマの変化への対応を gh に任せられる。
* テストしやすい：偽物の gh は、コマンドの名前ごとに応答を切り替えるだけで済む（GraphQL では、クエリの文字列から操作名を読み取らなければならない）。
* node id を引き回さなくてよい：Issue や Project を番号・URL で指定できる。

速さや API の負荷のためではない。GraphQL は入れ子のデータを1回で取れるので、呼び出しの回数はむしろ少ないことが多い。`gh project` のサブコマンドも内部では GraphQL を使う。レート制限は GraphQL と REST で別々に数えられ、このワークフローの回数ではどちらも上限に届かない。

GraphQL を使う箇所には、理由をコメントに書く。gh は新しいものを前提にし、要る機能が無い gh では止まって更新を促す（`common.sh` の `DW_GH_MIN_VERSION`。`doctor.sh` も更新を促す）。

### 結果として起きること

* 良い点：GitHub を使うスクリプトのテストで、偽物の gh をコマンドの名前で切り替えられる（`tests/fake_gh_project.bash` にまとめた）。
* 悪い点：GraphQL の1回の呼び出しで済んでいた操作が、複数の呼び出しに分かれることがある。たとえば `setup-project.sh` の Project の作成とリポジトリへの紐付けは別の呼び出しになり、紐付けだけ失敗したときは、Project を作ったことと再実行で紐付くことを伝えて止まる。
* 悪い点：古い gh の利用者は、更新するまで一部の操作を使えない。
* gh にも REST にも手段が無い操作には、GraphQL が残る（Issue から Project の項目を引く、Project の並び順で読む、Project の詳細、単一選択の項目の選択肢を足す）。残す箇所と理由は設計書 §10 に書く。

### 確認

GraphQL（`gh api graphql`）を使う箇所に、他に手段が無い理由のコメントがあるかを、レビューで確かめる。

## 補足

* 出典：Issue #89（https://github.com/nakayama-labs/agent-plugins/issues/89）、PR #95（https://github.com/nakayama-labs/agent-plugins/pull/95）、設計書 §10
