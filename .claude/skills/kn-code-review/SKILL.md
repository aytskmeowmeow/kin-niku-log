---
name: kn-code-review
description: |
  実装差分のコードレビューで見る観点のチェックリストと、指摘の出し方の規約。観点は (1) 外部仕様遵守 / (2) impl.md との整合 / (3) バグ・エッジケース / (4) デグレ影響 / (5) 保守性・可読性 / (6) コーディング規約 の 6 つで、1 人のレビュアーが全部見る。kn-code-reviewer エージェントが使う。

  TRIGGER: kn-code-reviewer としてコードレビューを行うとき。kn-dev-workflow の「6. レビュー」「軽量ルート」「運用ルート」「運用ルートの小さな修正」のレビュー。

  SKIP: GitHub PR に対するレビュー(公式 code-review プラグインを使う)、タスク文書(design.md / acceptance.md / impl.md)のレビュー(kn-doc-reviewer が kn-task-docs の観点で行う)。運用ルートとその小さな修正でスキル・ドキュメントの差分を見るレビューは SKIP しない(通常フローのタスクの小さな修正で design.md などを直した差分も含む)。
---

# コードレビュー観点

## 目的

1 人のレビュアーが、仕様との乖離からデグレ・可読性まで、観点の抜けなく差分を見る。

## 参照

- ルール本体は `references/rules.md`。レビューを始める前に必ず読むこと。

## 実行手順

1. `references/rules.md` を読む
2. design.md / acceptance.md(あれば)/ impl.md と、レビュー対象の差分を読む
3. rules.md の 6 観点を順に全部見る。気づいたものは確度が低くても挙げる
4. rules.md の「出力形式」で返す。仕様への疑問は指摘とは別に先頭に出す
