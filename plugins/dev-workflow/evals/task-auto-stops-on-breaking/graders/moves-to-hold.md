---
# Issue #2 の項目（IT2）を、保留の列（On Hold の選択肢 OH）に移したか
type: regex
target: { source: file, path: .fake-gh/writes }
pattern: '^project item-edit .*--id IT2 .*--single-select-option-id OH'
flags: m
match: contains
---
