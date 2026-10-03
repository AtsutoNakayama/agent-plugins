---
title: 一般的なバグ（組み込みの /code-review）
builtin: code-review
---

review スキルは、この観点ではサブエージェントを起動せず、組み込みの `/code-review` を実行する。止めるときは、上の層に同じ名前のファイル（`code-review.md`）を置き、`enabled: false` と書く。条件（`paths` など）を足すときも、上の層に同じ名前のファイルを置き、`builtin: code-review` と条件を書く。
