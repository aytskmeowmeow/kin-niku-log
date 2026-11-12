# CLAUDE.md

このファイルは入口だけを置く。ルール本体はスキルにある(二重管理しない)。

## 開発フロー

- コード・スキル・設定を変える開発タスクは、着手する前に **`kn-dev-workflow` スキル**を読んで従う
- タスクの文書(design.md / acceptance.md / impl.md)は **`kn-task-docs` スキル**に従う
- コミットは **`kn-commit-workflow` スキル**に従う
- グローバルにある元のスキル(`subagent-orchestration` / `design-impl-docs` / `implement-review-loop` / `code-review-agent` / `commit-workflow`)は、このリポジトリでは使わない

## 文書の置き場所

- GitHub issue のあるタスク: `docs/issues/<番号>-<slug>/`
- issue にしないタスク(エージェント運用など): `docs/<slug>/`

## サブエージェント

`.claude/agents/` の 3 つだけを使う。使う場面は `kn-dev-workflow` に書いてある。

- `kn-implementer`: 実装。受け入れ要件と受け入れテストは読めない(hook で止まる)
- `kn-doc-reviewer`: acceptance.md / impl.md のレビュー
- `kn-code-reviewer`: コードレビュー
