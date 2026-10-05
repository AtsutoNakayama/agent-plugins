---
status: "accepted"
date: 2026-10-04
issue: 142
---

# herdr との連携（task-start-parallel）をやめ、並列の着手は task-next の提案だけにする

## 背景と課題

複数の Issue を並列で進めたい。task-start はブランチとワークツリーの作成まで自分で行うので、Issue ごとに別のセッションを `claude "/dev-workflow:task-start 12"` で起動すれば、並列で着手できる。そこで #142 では、起動するコマンドの一覧を作り、herdr があればタブに展開して起動する task-start-parallel スキルを足そうとした。

動作確認で、task-start-parallel で起動コマンドの一覧を作り、herdr のタブに展開して、Issue ごとのセッションを起動した。そこで次のことが分かった。

* 開発中のプラグインでは `--plugin-dir` が要る。
* auto mode では、herdr の操作に許可のルールが要る。
* 親の Issue に着手すると止まる。

並列の着手を、プラグインでどこまで手伝うか。

## 判断の決め手

* 自動でできることが、手間に見合うか
* 並列に進められる Issue の組を、既に知る手段があるか

## 検討した案

* task-start-parallel スキルを足し、起動コマンドの一覧を出して、herdr があればタブに展開して起動する
* task-start-parallel は足さず、並列の着手は task-next の提案だけにする

## 判断の結果

選んだ案：「task-start-parallel は足さず、並列の着手は task-next の提案だけにする」。理由は、herdr との連携は利点が少ないから。自動でできるのはタブの起動までで、起動した後のセッションの質問・許可・レビューは、人がタブを切り替えて行う必要がある。その割に、権限の設定や herdr の skill の導入の手間がかかる。並列に進められる Issue の組は、task-next が既に出す。

## 補足

* 出典：Issue #142（https://github.com/nakayama-labs/agent-plugins/issues/142）の取りやめのコメント、Issue #154 のコメント「ADR にする判断の追加」（https://github.com/nakayama-labs/agent-plugins/issues/154）
* #142 は not planned で閉じた。doctor が herdr の権限を知らせる #189 も、あわせて取りやめた。
* 動作確認で見つけた、親の Issue を着手の対象から外す修正は、#190 に移した。
* task-next は、herdr などの並列実行の仕組みが無くても使える、読み取り専用のスキル（設計書 §8「次に着手する Issue の提案（task-next）」）。
