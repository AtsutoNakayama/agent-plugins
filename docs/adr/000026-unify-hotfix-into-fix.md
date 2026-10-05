---
status: "accepted"
date: 2026-09-27
issue: 26
---

# 緊急の修正も type は fix にし、hotfix の type をなくす

## 背景と課題

type ラベルに `hotfix` があり、コミットと PR のタイトルでは `commit_type_map` で `fix` に読み替えていた。このプラグインが前提にする GitHub Flow には hotfix のための別の手順が無く、`fix` と `hotfix` の違いは緊急度だけだった。type ラベル・ブランチ名・PR のタイトル・コミットの type を、どう対応させるか。

## 検討した案

* `hotfix` をなくして `fix` に統一し、type を1対1に対応させる
* `hotfix` の type ラベルを残し、`commit_type_map` でコミットと PR のタイトルの type に読み替える（それまでの形）

## 判断の結果

選んだ案：「`hotfix` をなくして `fix` に統一し、type を1対1に対応させる」。理由は、GitHub Flow には緊急の修正のための別の手順が無く、違いは緊急度だけなので、type で区別する必要が無いから。type ラベル・ブランチ名・PR のタイトル・コミットの type を、同じ type で1対1に対応させ、読み替え（`commit_type_map`）をなくす。緊急度が必要なら、type とは別のラベル（`priority: high` など）で表す。

### 結果として起きること

* 良い点：type ラベルからブランチ名・PR のタイトル・コミットの type まで、読み替えなしで同じ type が流れる。

## 補足

* 出典：Issue #26（https://github.com/nakayama-labs/agent-plugins/issues/26）、PR #30（https://github.com/nakayama-labs/agent-plugins/pull/30）、設計書 §5
* PR #30 では、このリポジトリの GitHub 上の `hotfix` ラベルも削除した（使っている Issue・PR は無かった）。
