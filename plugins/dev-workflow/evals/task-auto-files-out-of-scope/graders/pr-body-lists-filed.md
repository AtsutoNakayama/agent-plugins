---
# 作った PR の本文に、起票した Issue と範囲外の指摘の内訳が書かれているか（偽の gh が、gh pr create の本文を .fake-gh/pr-body に残す）。
# 起票して最後の報告に書いても、PR の本文に「起票した Issue：なし」と書けば、PR を見る人には伝わらない（#307）。
# 本文の書き方（見出し・言い回し）は色々あり、正規表現では内訳が合うかを判断できないので、judge に読ませる
type: llm
focus: { source: file, path: .fake-gh/pr-body }
---

This is the body of the pull request that the automatic run (task-auto) created for Issue #2. The fake GitHub answers every new Issue with number 99.

During the run's review, the typo "Helo" in the pre-existing script bin/greet.sh was found. It is outside the scope of Issue #2, so the run should have filed it as a new Issue (#99) and recorded that in the pull request body, in its section about automatic decisions.

PASS if the body says the out-of-scope finding about the "Helo" typo in bin/greet.sh was filed as Issue #99, and the number of out-of-scope findings it reports matches its breakdown (filed, duplicate, not filed because of the limit, and so on).
FAIL if the file is missing or empty, if the body says no Issue was filed (for example "filed Issues: none" or "起票した Issue：なし"), if it does not mention #99, or if the reported count does not match the breakdown.
