---
description: 止まる条件（breaking ラベル）に当たったら、着手せずに、理由を Issue にコメントして保留の列に移して止まる（task-auto の「止まる」）
tags: [task-auto]
max_turns: 30
timeout_seconds: 600
allowed_tools: [Bash, Read, Glob, Grep, Skill]
---

#2 を、確認なしで PR まで自動で進めて
