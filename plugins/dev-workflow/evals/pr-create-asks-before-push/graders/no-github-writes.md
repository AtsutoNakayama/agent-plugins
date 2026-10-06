---
type: regex
target: { source: file, path: .fake-gh/calls }
pattern: '^(issue (create|edit|comment|close)|pr (create|edit|comment)|project item-(add|edit)|api graphql [A-Za-z]*(Add|Set|Update|Create))'
flags: m
match: not_contains
---
