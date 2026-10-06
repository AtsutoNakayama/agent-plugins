---
type: regex
target: { source: file, path: bin/farewell.sh }
pattern: '[ \t]\$\{?(name|1)\}?[ \t]*$'
flags: m
match: not_contains
---
