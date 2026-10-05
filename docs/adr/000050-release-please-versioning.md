---
status: "accepted"
date: 2026-09-28
issue: 50
---

# dev-workflow の version を release-please で上げ、手で変えない

## 背景と課題

dev-workflow の version は、`plugins/dev-workflow/.claude-plugin/plugin.json` に手で書いていた。

* PR ごとに上げると、並行する PR どうしがコンフリクトする。
* 上げ忘れると、Claude Code は更新を検出しない。Claude Code は plugin.json の version → marketplace.json のエントリの version → コミット SHA の順に version を決め、git のタグは読まない。
* `refactor:` や `docs:` でも、`plugins/dev-workflow/` の中（SKILL.md の文章など）を変えると、プラグインの動きや AI への指示が変わる。

version をどう上げ、どの変更を利用者に届けるか。

## 判断の決め手

* 並行する PR どうしが version でコンフリクトしないこと
* 上げ忘れで、利用者に変更が届かないことが無いこと
* SKILL.md の文章だけの変更も、利用者に届くこと

## 検討した案

* version を手で上げる（それまでの形）
* release-please で上げる
  * プラグインの中の文章の変更を届ける方法として、次の2つを比べた
    * 動きが変わる SKILL.md の変更は、`docs` ではなく `fix` か `feat` にする運用ルールにする
    * `changelog-sections` で全ての type を表示にし、プラグインの中を変えたら type を問わずリリースの対象にする

## 判断の結果

選んだ案：「release-please で上げる」と「`changelog-sections` で全ての type をリリースの対象にする」。理由は、version を書き換えるのがボットだけになり、並行する PR どうしがコンフリクトせず、上げ忘れも起きないから。また、SKILL.md の文章だけの変更も AI への指示を変えるので、type を問わず利用者に届ける。type は上げ幅だけを決める。

* main へのマージごとに、ボットがリリース PR に version の変更をためる。リリース PR をマージすると、plugin.json の version が上がり、`dev-workflow-v<version>` のタグと GitHub Release が作られる。
* パッケージは `plugins/dev-workflow` だけ。外だけを変えたコミットでは version は上がらない。このリポジトリ専用の作業は `ci` / `test` / `docs` / `chore` の type を使う。
* version は plugin.json だけに書き、marketplace.json のエントリには書かない。
* 1.0 より前は、`feat` と破壊的変更で minor、それ以外は patch を上げる（`bump-minor-pre-major`）。
* CHANGELOG.md は配布物に入れないため作らない（履歴は GitHub Release に残る。`skip-changelog`）。
* 0.3.0 から始める（#49 のマージコミットに `dev-workflow-v0.3.0` のタグと GitHub Release を作って起点にした）。
* 1.0.0 などの破壊的変更を伴わない節目は、非推奨の設定の `release-as` ではなく、PR の本文の `Release-As:` で上げる。

### 結果として起きること

* 良い点：version を手で変えないので、PR どうしが version でコンフリクトせず、上げ忘れも無くなる。
* 良い点：SKILL.md の文章だけの変更も、次のリリースで利用者に届く。
* 悪い点：release-please はコミットのメッセージを「空行の次が `feat: ` などで始まる段落」で分けて読むので、PR の本文の段落を type で始めると、意図しない上げ幅になる。
* 悪い点：`Release-As:` はメッセージの最後の段落でしか読まれず、ほかの位置に書くと何も言わずに無視される。

### 確認

CI で、plugin.json と `.release-please-manifest.json` の version が同じかを確かめる（手で plugin.json だけを変えた PR を止める）。

## 補足

* 出典：Issue #50（https://github.com/nakayama-labs/agent-plugins/issues/50）、PR #53（https://github.com/nakayama-labs/agent-plugins/pull/53）、設計書 §1「配布の対象とバージョン」・§11
* トークンは、最初は GITHUB_TOKEN を使い、リリース PR の中身はマージ後の CI で確かめることにしていた。これは、リリース PR でも CI を動かすために、GitHub App のトークンに変えた（[000057](000057-github-app-token-for-release.md)）。
* 最初は `googleapis/release-please-action` を使っていたが、Action の v5 が同梱する release-please 17.6.0 がリリース PR の本文に `closes #N` と書き写し、閉じたばかりの Issue を Project の In Progress に戻してしまうので、版を固定した release-please の CLI（`npx release-please@<版>`）を直接実行するようにした（PR #68、https://github.com/nakayama-labs/agent-plugins/pull/68）。
