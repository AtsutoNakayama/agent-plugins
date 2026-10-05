---
status: "accepted"
date: 2026-10-03
issue: 93
---

# dev-workflow の設定・ガイド・観点の置き場所を .claude/dev-workflow/ の1か所にまとめる

## 背景と課題

dev-workflow の設定・ガイド・観点・ラベルの定義の置き場所（`.claude/workflow.json`、`.claude/workflow/`、`~/.claude/workflow/`、`.claude/review/`、`.claude/labels.json` など）は、`.claude/` の下にばらばらに置かれ、一般的な名前を使っていた。特に `.claude/workflow/` と `~/.claude/workflow/` は、Claude Code 本体の dynamic workflows が使う `.claude/workflows/` と `~/.claude/workflows/` と1文字しか違わず、人も Claude も取り違える。

## 判断の決め手

* Claude Code 本体が使う `.claude/` の下の名前と取り違えないこと
* リポジトリとホームで、同じ形で置けること
* 破壊的変更なので、1.0.0 の前に済ませること

## 検討した案

* `.claude/dev-workflow/`（リポジトリ）と `~/.claude/dev-workflow/`（ホーム）の1か所にまとめる
* `.claude/` の下のばらばらの置き場所のまま使う（それまでの形）

## 判断の結果

選んだ案：「`.claude/dev-workflow/` と `~/.claude/dev-workflow/` の1か所にまとめる」。理由は、Claude Code 本体が使う `.claude/` の下の名前（`.claude/workflows/` など）と取り違えないため。どちらも同じ形にする。

| 前 | 後 |
|---|---|
| `<repo>/.claude/workflow.json` | `<repo>/.claude/dev-workflow/config.json` |
| `<repo>/.claude/workflow.local.json` | `<repo>/.claude/dev-workflow/config.local.json` |
| `<repo>/.claude/workflow/*.md` | `<repo>/.claude/dev-workflow/*.md` |
| `<repo>/.claude/review/*.md` | `<repo>/.claude/dev-workflow/review/*.md` |
| `<repo>/.claude/labels.json` | `<repo>/.claude/dev-workflow/labels.json` |
| `~/.claude/workflow/workflow.json` | `~/.claude/dev-workflow/config.json` |
| `~/.claude/workflow/*.md` | `~/.claude/dev-workflow/*.md` |
| `~/.claude/review/*.md` | `~/.claude/dev-workflow/review/*.md` |

### 結果として起きること

* 良い点：dev-workflow のファイルがどれか、名前で分かる。
* 悪い点：破壊的変更で、利用者は上の表のとおりにファイルを移す必要がある。古い場所に残ったファイルは使われなくなる。そのため `doctor.sh` が、古い置き場所にファイルがあれば移すよう促し、個人の設定（`config.local.json`）が git に無視されていなければ `.gitignore` に足すよう促す。
* ユーザーの観点の置き場所は `~/.claude/dev-workflow/review/` に固定し、置き場所を変える環境変数 `WORKFLOW_USER_REVIEW_DIR` を廃止した。

### 確認

`git grep` で、`.claude/workflow`・`.claude/review`・`.claude/labels.json` を参照する箇所が、`doctor.sh` の古い置き場所の確認（とそのテスト）のほかに無いことを確かめる。

## 補足

* 出典：Issue #93（https://github.com/nakayama-labs/agent-plugins/issues/93）、PR #102（https://github.com/nakayama-labs/agent-plugins/pull/102）、設計書 §6「書き方の設定」
