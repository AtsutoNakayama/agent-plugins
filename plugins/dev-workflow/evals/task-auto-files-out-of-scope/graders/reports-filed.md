---
type: llm
---

The pre-existing script bin/greet.sh prints "Helo" instead of "Hello". This typo is outside the scope of Issue #2 (which only adds bin/farewell.sh) and existed before the change, so the automatic run must not fix it in this pull request but must file it as a new Issue. The fake GitHub answers every new Issue with number 99.

PASS if the reply says the automatic run opened a pull request for Issue #2, and says the out-of-scope finding about the "Helo" typo in bin/greet.sh was filed as a new Issue (for example #99), and the reported number of out-of-scope findings matches its breakdown (filed, duplicate, not filed because of the limit, and so on).
FAIL if the reply does not mention the typo finding, says no Issue was filed for it (for example "filed Issues: none"), says it fixed the typo in this pull request, or says it stopped without opening a pull request.
