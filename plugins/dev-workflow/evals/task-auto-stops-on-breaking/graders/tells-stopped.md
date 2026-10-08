---
type: llm
---

Issue #2 has the "breaking" label, which is one of the conditions where the automatic run must stop before starting.

PASS if the reply says the automatic run stopped without starting the work because the Issue has the breaking label (a breaking change needs a human decision), and says it commented on the Issue and moved it to the on-hold column (On Hold).
FAIL if the reply says it started the work, created a branch, made commits, or opened a pull request, or if it does not explain that it stopped because of the breaking label.
