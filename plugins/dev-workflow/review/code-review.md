---
title: 一般的なバグ（組み込みの /code-review）
builtin: code-review
---

review スキルは、この観点では観点ごとのレビュー用サブエージェントを起動せず、代わりに組み込みの `/code-review` を呼ぶ（`/code-review` は自分でコンテキストを分けて、ほかの観点と並行して動く）。止めるときは、上の層に同じ名前のファイル（`code-review.md`）を置き、`enabled: false` と書く。条件（`paths` など）を足すときも、上の層に同じ名前のファイルを置き、`builtin: code-review` と条件を書く。
