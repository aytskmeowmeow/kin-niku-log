# #33 vite の dev サーバーの脆弱性(GHSA-p4f5-76q4-ffq7)に対応する — acceptance.md

- 状態: 承認済み(2026-11-19)
- テスト基盤は Phase 3 の最初の issue で入るため、まだ無い。すべての要件を ② Claude が localhost で確認する とし、受け入れテスト(フローの 2)は作らない
- D1 の「絞る」に従い、受け入れ要件は R1〜R4 と完了条件の確認にとどめる。画面や API の個別の振る舞いの確認は足さない

---

### AC-1. vite と Rolldown が修正版になっている

- 種別: 機能
- 出典: design.md R1・仕様、D2
- 確認方法: ② Claude が localhost で確認
- Given 依存を入れ直した作業ツリー(`bun install --frozen-lockfile` が通る)
- When `bun.lock` と `bun pm ls --all` で、vite・`rolldown`・使っているプラットフォームの `@rolldown/binding-*` のバージョンを確認する
- Then lock に入っている vite はすべて `^8.3.8` を満たす
- And `rolldown` と `@rolldown/binding-*` はすべて 1.2.17 以上
- And `apps/web/package.json` と `apps/api/package.json` の vite の指定が `^8.3.8` になっている

### AC-2. GHSA-p4f5-76q4-ffq7 に該当しない

- 種別: 機能
- 出典: design.md R1、完了条件
- 確認方法: ② Claude が localhost で確認
- Given AC-1 の状態
- When `bun audit` を実行し、GitHub のアドバイザリのページ(https://github.com/vitejs/vite/security/advisories/GHSA-p4f5-76q4-ffq7)で影響範囲を確認する
- Then `bun audit` の出力に GHSA-p4f5-76q4-ffq7 が含まれない
- And lock の vite のバージョンが、アドバイザリのページに書かれた影響範囲に入っていない

### AC-3. build が成功する

- 種別: 非機能
- 出典: design.md R2
- 確認方法: ② Claude が localhost で確認
- Given AC-1 の状態
- When リポジトリのルートで `bun run build` を実行する
- Then web と api の build がどちらもエラーなく終わる

### AC-4. web の dev サーバーが起動して応答する

- 種別: 非機能
- 出典: design.md R3
- 確認方法: ② Claude が localhost で確認
- Given AC-1 の状態
- When `apps/web` で `bun run dev` を実行し、ブラウザで `http://localhost:3000/` を開く
- Then dev サーバーの起動ログにエラーが出ない
- And 見出し「Hello World」が表示され、ブラウザのコンソールにエラーが出ない

### AC-5. api の dev サーバーが起動して応答する

- 種別: 非機能
- 出典: design.md R3
- 確認方法: ② Claude が localhost で確認
- Given AC-1 の状態で、ポート 8080 が空いている
- When `apps/api` で `bun run dev` を実行し、起動ログに出たポートが 8080 であることを確かめてから、`GET http://localhost:8080/health` を送る
- Then dev サーバーの起動ログにエラーが出ない
- And 200 が返り、本文が `{"status":"ok"}` である

### AC-6. lint と型検査が通る

- 種別: 非機能
- 出典: design.md R4
- 確認方法: ② Claude が localhost で確認
- Given AC-1 の状態
- When リポジトリのルートで `bun run lint` と `bun run check-types` を実行する
- Then どちらもエラーなく終わる
