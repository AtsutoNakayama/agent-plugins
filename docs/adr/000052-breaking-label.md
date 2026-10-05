---
status: "accepted"
date: 2026-10-03
issue: 52
---

# 破壊的変更を type とは別の breaking ラベルで表し、PR のタイトルに ! を付ける

## 背景と課題

Conventional Commits では、破壊的変更を `feat!:` のように type の後の `!`（または本文の `BREAKING CHANGE:`）で表す。`commit.pattern` と `pr.title_pattern` は `!` を許していたが、自動で `!` が付く流れは無く、スキルにも破壊的変更の扱いが書かれていなかった。このままでは、破壊的変更でも `feat:` としてマージされ、release-please（[000050](000050-release-please-versioning.md)）で version を決めるときに、上げ幅が足りなくなる。破壊的変更を、Issue から PR・コミットまでどう伝えるか。

## 判断の決め手

* 破壊的変更はどの type にも起こりうること
* 「type ラベルは1つだけ」という決まりを変えないこと
* `!` の付け忘れが起きないこと

## 検討した案

* type とは別の `breaking` ラベルで表す
* `feat!` のような、type ごとのラベルで表す

## 判断の結果

選んだ案：「type とは別の `breaking` ラベルで表す」。理由は、破壊的変更はどの type にも起こりうるから。ラベル → PR のタイトル（`<type>!: …`）→ スカッシュのコミットと情報が流れるので、Issue の段階で付けておけば `!` の付け忘れが無くなる。

* `breaking` は `labels.types` に入れない。type ラベルは1つだけという決まりはそのまま。
* Issue に `breaking` ラベルがあれば、`pr-create.sh` がタイトルを `<type>!: <Issueのタイトル>` にする。タイトルに `!` が無い、または本文に `BREAKING CHANGE: <移行のしかた>` が無いときは、push する前に止める（スカッシュマージでは PR のタイトルと本文がそのままコミットになるので、ここで止めないと付け忘れたままマージされる）。PR が既にあるときは、その PR のタイトルと本文を確かめる。
* 破壊的変更とは、既存の利用者が設定やコマンドを直さないと動かなくなる変更（設定キーやプレースホルダの名前の変更、スクリプトの引数の変更・削除、スキル名の変更など）。version を上げたいから付けるものではない。破壊的変更を伴わない節目（1.0.0 など）は、release-please の `Release-As:` で上げる。

### 結果として起きること

* 良い点：Issue にラベルを付けておけば、PR のタイトルの `!` と本文の `BREAKING CHANGE:` が付け忘れなく入る。
* 悪い点：既にあるリポジトリでは、`setup-labels.sh` を実行し直して `breaking` ラベルを作らないと使えない（無ければ起票の前に止まる）。

### 確認

`pr-create.sh` が、`breaking` ラベルの付いた Issue の PR で、タイトルの `!` と本文の `BREAKING CHANGE:` を確かめる（`tests/pr-create.bats`）。

## 補足

* 出典：Issue #52（https://github.com/nakayama-labs/agent-plugins/issues/52）、PR #72（https://github.com/nakayama-labs/agent-plugins/pull/72）、設計書 §5・§6
