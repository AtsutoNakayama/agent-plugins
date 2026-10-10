---
status: "accepted"
date: 2026-10-10
issue: 338
---

# proposed の ADR を採択するときは、status と date の行だけを書き換える

## 背景と課題

#243 で、採択した ADR の本文は書き換えず、変えてよいのは置き換えたときの `status` の行だけと決めた。また、front matter の `date` は「判断をした日」にし、判断がまだなら `status` を `proposed` にして作る。

一方で、`proposed` で作った ADR を後で `accepted` にするときに、`status` と `date` をどう直すか（採択した ADR を書き換えない決まりとの関係を含む）は、どこにも書かれていなかった（#311）。採択するときに、どの行を書き換えてよいか。

## 検討した案

* その ADR の `status` を `accepted` に、`date` を採択した日に書き換える（書き換えない決まりは、採択した後の ADR に当てる）
* `status` だけを書き換え、`date` は `proposed` で作った日のままにする
* `proposed` の ADR は書き換えず、採択するときは新しい ADR を作って置き換える（`superseded`）

## 判断の結果

選んだ案：「その ADR の `status` を `accepted` に、`date` を採択した日に書き換える（書き換えない決まりは、採択した後の ADR に当てる）」。理由は、採択した日が判断をした日なので、`date` を判断をした日にする決まりと合い、同じ判断の ADR を2つに分けずに済むから。

* 採択した ADR を書き換えない決まりは、`accepted` 以降の ADR に当てる。`proposed` の ADR を採択するときに書き換えるのは、`status` と `date` の2つの行だけで、ほかの行は書き換えない。採択した後は、置き換えたときの `status` の行のほかは書き換えない
* adr-create の SKILL.md・設計書・テンプレートの README に書き、`tests/skills.bats` で書かれていることを確かめる

### 結果として起きること

* 良い点：`proposed` の ADR を採択したときの直し方が1つに決まり、`date` を見れば判断をした日が分かる
* 悪い点：`proposed` で作った日は、ADR の中には残らない（git の履歴で分かる）
