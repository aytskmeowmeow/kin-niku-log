# #33 vite の dev サーバーの脆弱性(GHSA-p4f5-76q4-ffq7)に対応する — impl.md

- design.md: `docs/issues/33-vite-vuln/design.md`
- ルート: 通常のフロー(design.md D1 のとおり、受け入れ要件を絞っている)。D5 により、この impl.md のドキュメントレビュー、kn-implementer による実装、理解度チェックは省き、メインが直接実装する

---

## 実装状況

| 項目 | 状態 | 確認した事実 |
|---|---|---|
| I1. `apps/web` と `apps/api` の vite の指定を `^8.3.8` にする | 完了 | 着手前は両方とも `^8.3.5` |
| I2. lock を更新し、vite を 8.3.8、Rolldown を 1.2.17 以上にする | 完了 | vite 8.3.5 → 8.3.8、`rolldown`・`@rolldown/binding-*` 1.2.16 → 1.2.19 |
| I3. 検証(lint / check-types / build、dev サーバーの起動) | 完了 | 「検証の結果」のとおり。web のブラウザでの確認はユーザーが行った(D6) |

## 構成

| ファイル | 変更 |
|---|---|
| `apps/web/package.json` | devDependencies の vite の指定を `^8.3.8` にする |
| `apps/api/package.json` | 同上 |
| `bun.lock` | vite と、vite の更新に伴って上がる依存(`rolldown`・`@rolldown/binding-*` など)だけが変わる |

アプリのソース・`vite.config.ts`・ほかの依存の指定は変えない(design.md の範囲外)。

## 技術的判断

### lock の更新方法

- 2 つの `package.json` の vite の指定を書き換えてから、リポジトリのルートで `bun install` を実行し、lock を更新する
- `bun update` と `bun audit fix` は使わない。どちらも vite 以外の依存まで範囲内の最新に上げてしまい、design.md D2 の「他の依存は上げない」に反する
- 更新後に `git diff bun.lock` を見て、変わったのが vite と、vite が依存するパッケージ(`rolldown`・`@rolldown/binding-*`・`@oxc-project/types` など)、およびそれに伴う推移的依存だけであることを確かめる。関係の無いパッケージが変わっていたら、その理由を報告する

### Rolldown の版

- vite 8.3.8 は `rolldown: ~1.2.18` に依存するので、vite を 8.3.8 にすれば Rolldown は 1.2.17 以上(修正版)になる。Rolldown を直接の依存として指定する必要はない

### 依存を共有するプラグイン

- `@vitejs/plugin-react`(peer: `vite ^8.0.0`)、`@tailwindcss/vite`(peer: `^5.2.0 || ^6 || ^7 || ^8`)、`@cloudflare/vite-plugin`(peer: `^7.0.0 || ^8.0.0`)は、どれも 8.3.8 を許している。プラグインの更新は要らない

## 検証方法

テスト基盤が無いため、kn-dev-workflow の 5 のとおり、lint / check-types と `bun run build` を検証とし、単体テスト・受け入れテストは省く。

1. `bun install --frozen-lockfile`
2. `bun run lint` / `bun run check-types`
3. `bun run build`
4. `bun audit`(GHSA-p4f5-76q4-ffq7 が出ないこと)
5. web と api の dev サーバーを起動し、web はブラウザで、api は `/health` で応答を確かめる

### 検証の結果(2026-11-19、メイン、macOS)

| 項目 | 結果 |
|---|---|
| `bun install --frozen-lockfile` | 変更なしで通る |
| `bun pm ls --all` | vite@8.3.8、rolldown@1.2.19、@rolldown/binding-darwin-arm64@1.2.19 |
| lock の差分 | vite と `rolldown`・`@rolldown/binding-*` の版が上がった。ほかに `@rolldown/binding-wasm32-wasi` とその依存(`@napi-rs/wasm-runtime`・`@emnapi/core`・`@emnapi/wasi-threads`・`@tybys/wasm-util`)が増え、`@emnapi/runtime` の巻き上げ版が 2.0.0-beta.2 になった。sharp の wasm 版は従来の 1.11.3 を入れ子で使い続ける。いずれも rolldown 1.2.19 の optional な wasm 向けバインディングによるもの。lock 上 `@rolldown/binding-wasm32-wasi` は `"cpu": "none"` なので、macOS・Linux など通常のプラットフォームではインストールされない(macOS では `node_modules/.bun` でも確かめた) |
| `bun run lint` / `bun run check-types` | 成功 |
| `bun run build` | web・api とも成功 |
| `bun audit` | 6 件(js-yaml / esbuild / minimatch。更新前と同じ)。GHSA-p4f5-76q4-ffq7 は出ない。なお更新前の 8.3.5 でも `bun audit` はこのアドバイザリを出していなかった(GitHub の全体のアドバイザリ DB にまだ載っていない)ため、該当しないことはアドバイザリのページの影響範囲(8.3.0〜8.3.6、修正版 8.3.7)と lock の 8.3.8 の突き合わせで確かめた |
| api の dev サーバー | 8080 が空いていることを確かめてから起動。起動ログは `VITE v8.3.8`、`Local: http://localhost:8080/`、エラーなし。`GET /health` は 200 `{"status":"ok"}` |
| web の dev サーバー | 起動ログは `VITE v8.3.8`、`Local: http://localhost:3000/`、エラーなし(api と同時に起動したため inspector のポートが 9230 になった旨の通知だけ出た)。`GET /` は 200 |
| web のブラウザでの確認 | このセッションにはブラウザを操作するツールが無く、見出しの表示とコンソールは見ていない。代わりに `/src/main.tsx`・`/src/routes/index.tsx`・`/@vite/client` が dev サーバーで 200 の JavaScript に変換され、`index.tsx` の変換結果に「Hello World」が含まれることを確かめた |
| web のブラウザでの確認(ユーザー、D6) | ユーザーが `bun run --cwd apps/web dev` で起動し、ブラウザで http://localhost:3000/ を開いた。見出し「Hello World」が表示され、コンソールにも問題は無かった |

## 既知の制約・未解決の疑問

- `bun audit` には js-yaml / esbuild / minimatch の指摘が残る(design.md の範囲外)
- メインのセッションにはブラウザを操作するツールが無いため、AC-4 のブラウザでの確認はユーザーが行った(D6)

## レビュー指摘と対応

### レビュー第 1 回(2026-11-19、ドキュメント: acceptance.md の初版)

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | D1 の「build と dev サーバーが動くことに絞る」と、バージョン・audit・lint の受け入れ要件が食い違う | 「絞る」を「R1〜R4 と完了条件の確認にとどめる」と解釈し、ユーザーが acceptance.md の承認で了承。design.md の D1 に転記 | 対応済み |
| 2 | 「lock に入っているバージョンは 1 つだけ」は design.md に無い | 「lock に入っているものはすべて下限以上」に変更 | 対応済み |
| 3 | 完了条件の「GitHub のアドバイザリで該当しない」が、Dependabot のアラートまで指すか曖昧 | アドバイザリの影響範囲との突き合わせと解釈し、ユーザーが了承。design.md の D4 に転記 | 対応済み |
| 4 | 「vite についての指摘が出ない」は過剰 | 「GHSA-p4f5-76q4-ffq7 が出力に含まれない」に変更 | 対応済み |
| 5 | 影響範囲との比較が AC-1 と重複している | 見るものをアドバイザリのページにした | 対応済み |
| 6 | api のポートに `strictPort` が無く、別のプロセスの応答で誤って合格しうる | Given に「8080 が空いている」、When に起動ログのポートの確認を追加。Then に本文 `{"status":"ok"}` を追加 | 対応済み |
| 7 | web のトップページの合格条件が曖昧 | 「見出し『Hello World』が表示される」に変更 | 対応済み |
| 8 | 起動ログのエラーを見ていない | AC-4・AC-5 の Then に追加 | 対応済み |
| 9 | Given の `bun install --frozen-lockfile` は design.md に無い | 前提の確認として Given に残す | 対応見送り(前提であり、判定条件に数えない) |
| 10 | 「8.x」が design.md に無い | 「`^8.3.8` を満たす」に変更 | 対応済み |
| 11 | どの Rolldown のパッケージを見るか曖昧 | `rolldown` と `@rolldown/binding-*` を明記 | 対応済み |

### レビュー第 1 回(2026-11-19、コード)

- **指摘:** AC-4 のブラウザでの確認を、モジュールの変換の確認で代えている。描画時の例外や HMR の接続失敗を見つけられず、承認済みの確認方法を変えることになる(仕様・設計)
  - **対応:** ユーザーに確認し、ユーザーが自分のブラウザで確認することになった(design.md D6)
  - **状態:** 対応済み(ユーザーの確認で問題なし。「検証の結果」に記録)
- **指摘:** wasm 系の依存がインストールされない根拠が macOS での確認だけで、Linux などで入るのかが読み取れない(実装判断)
  - **対応:** lock 上 `@rolldown/binding-wasm32-wasi` が `"cpu": "none"` であることを根拠に書き足した
  - **状態:** 対応済み
- lint 化の候補: なし
