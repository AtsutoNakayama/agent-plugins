---
status: "accepted"
date: 2026-10-03
issue: 57
---

# release-please に GitHub App のトークンを渡し、リリース PR でも CI を動かす

## 背景と課題

release-please は `GITHUB_TOKEN` でリリース PR を作っていた（[000050](000050-release-please-versioning.md)）。`GITHUB_TOKEN` が起こしたイベントでは新しいワークフローが動かないので、リリース PR にはマージ前のチェック（Lint・Test）が付かない。マージ後の main への push で確かめていたが、そのときには release-please がタグと GitHub Release を作り終えているので、CI が落ちてもリリースは出てしまう。また、このままでは Lint・Test をルールセットの必須のチェックにできない（リリース PR がマージできなくなる）。

## 判断の決め手

* リリース PR でも、マージの前に Lint・Test が動くこと
* Lint・Test を、ルールセットの必須のチェックにできること
* トークンの期限を管理しなくて済むこと

## 検討した案

* GitHub App のトークンを使う
* PAT（個人のアクセストークン）を使う
* `GITHUB_TOKEN` のまま、マージ後の CI で確かめる（それまでの形）

## 判断の結果

選んだ案：「GitHub App のトークンを使う」。理由は、App のトークンで作った PR では `pull_request` のトリガーで CI が動き、PAT と違って期限の管理が要らず、PR の作者が bot（`<App名>[bot]`）になるから。公開リポジトリなので、App・Actions とも料金はかからない。

* App は Webhook なし・このアカウントだけにインストールできる設定で作り、Repository permissions は Contents・Issues・Pull requests を Read and write にする（Issues はリリース PR のラベルに要る）。インストール先はこのリポジトリだけにする。
* リポジトリの Variables の `RELEASE_APP_ID` に App ID を、Secrets の `RELEASE_APP_PRIVATE_KEY` に App の秘密鍵を登録する。ワークフローは実行ごとに 1 時間で切れるトークンを作る（`actions/create-github-app-token`）。
* `GITHUB_TOKEN` を使わなくなったので、ワークフローの `permissions` を `{}` にする。リポジトリの設定の「Allow GitHub Actions to create and approve pull requests」も要らなくなる。

### 結果として起きること

* 良い点：CI を通らないままリリースが出ることが無くなる。
* 良い点：Lint・Test を必須のチェックにできる（後に [000112](000112-require-ci-on-latest-main.md) で必須にした）。
* 悪い点：GitHub App を作り、その ID と秘密鍵をリポジトリに登録して管理する手間が増える。

### 確認

リリース PR が `<App名>[bot]` で作られ・更新され、その PR で Lint と Test が動くことを確かめる。

## 補足

* 出典：Issue #57（https://github.com/nakayama-labs/agent-plugins/issues/57）、PR #79（https://github.com/nakayama-labs/agent-plugins/pull/79）、設計書 §1「配布の対象とバージョン」
* `actions/create-github-app-token@v3` では `app-id` が非推奨で `client-id` が推奨だが、CI の actionlint 1.7.12 が `client-id` を知らずにエラーにするので、`app-id` を使っている。actionlint が対応したら `client-id` に替える（PR #79）。
