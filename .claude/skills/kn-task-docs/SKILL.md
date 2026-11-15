---
name: kn-task-docs
description: |
  タスクの開発コンテキストを design.md(仕様・要件)/ acceptance.md(受け入れ要件)/ impl.md(実装方針と現在地)の 3 文書で管理する規約。各文書の書式・編集者・読める人、ドキュメントレビューを走らせる契機、決定事項の転記手順を定める。フローの手順そのものは kn-dev-workflow が持つ。

  TRIGGER: タスク開始時の文書作成・確認、仕様・要件の議論や決定が発生したとき、「design.md に書いた」「acceptance.md 確認して」「impl.md 更新して」など文書を起点とした指示、セッション再開時。design.md / acceptance.md / impl.md というファイル名が会話に出たら必ずこのスキルに従う。

  SKIP: 開発タスクと無関係な操作(一般的な質問応答、リポジトリ運用コマンドの実行のみ)。
---

# タスク文書(design.md / acceptance.md / impl.md)

## 目的

仕様・受け入れ要件・実装方針を 3 文書に分けて常に最新化し、セッション再開とサブエージェントへの受け渡しをファイルだけで完結させる。

## 参照

- ルール本体は `references/rules.md`。文書を書く・読む前に必ず読むこと。

## 実行手順

1. `references/rules.md` を読む
2. 該当タスクの文書を読む(無ければ rules.md の「配置」に従って作る)
3. rules.md の書式・編集者・読める人に従って書く。acceptance.md は実装エージェントに渡さない
4. 書いた内容が rules.md の「ドキュメントレビューの契機」に当たれば、kn-doc-reviewer にレビューさせる
5. 仕様の空白に気づいたら、決めずに design.md の未決事項に書く
