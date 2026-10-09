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

* その ADR の `status` を `accepted` に、`date` を採択した日に書き換え、これを書き換えない決まりの例外にする
* `status` だけを書き換え、`date` は `proposed` で作った日のままにする
* `proposed` の ADR は書き換えず、採択するときは新しい ADR を作って置き換える（`superseded`）

## 判断の結果

選んだ案：「その ADR の `status` を `accepted` に、`date` を採択した日に書き換え、これを書き換えない決まりの例外にする」。理由は、採択した日が判断をした日なので、`date` を判断をした日にする決まりと合い、同じ判断の ADR を2つに分けずに済むから。

* 採択した ADR を書き換えない決まりの例外は、置き換えたときの `status` の行のほかは、採択のときの `status` と `date` の2つの行の書き換えだけにする。ほかの行は書き換えない
* adr-create の SKILL.md・設計書・テンプレートの README に書き、`tests/skills.bats` で書かれていることを確かめる

### 結果として起きること

* 良い点：`proposed` の ADR を採択したときの直し方が1つに決まり、`date` を見れば判断をした日が分かる
* 悪い点：`proposed` で作った日は、ADR の中には残らない（git の履歴で分かる）
