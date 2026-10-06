---
type: regex
target: { source: file, path: bin/greet.sh }
pattern: '[ \t]\$\{?(name|1)\}?[ \t]*$'
flags: m
match: not_contains
---
