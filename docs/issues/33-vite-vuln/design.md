# #33 vite の dev サーバーの脆弱性(GHSA-p4f5-76q4-ffq7)に対応する — design.md

- issue: https://github.com/aytskmeowmeow/kin-niku-log/issues/33
- 状態: 2026-11-19 にメインが影響範囲を調査。同日、ユーザーが進め方(D1)と更新先(D2)・作業ブランチ(D3)を決定。acceptance.md のレビューで出た 2 点(D1 の「絞る」の範囲、完了条件の「GitHub のアドバイザリ」の意味)を、同日の acceptance.md の承認で決定し、D1 の補足と D4 に転記済み。未決事項なし
- 調査結果は 2026-11-19 時点の記録
- ルート: 通常のフロー(依存ライブラリの更新)。ただし D1 のとおり受け入れ要件を絞る

---

## 目的・背景

- ユーザーから「vite と nginx に脆弱性が出ているので、影響範囲を調査して対応してほしい」と依頼があった
- vite の dev サーバーに critical の脆弱性 GHSA-p4f5-76q4-ffq7 が公開された。`apps/web` と `apps/api` が使っている vite 8.3.5 は影響を受けるバージョンなので、修正版に上げる

### 完了条件(issue より)

- lock の vite が 8.3.7 以上、Rolldown が 1.2.17 以上になっている
- `bun audit` と GitHub のアドバイザリで、GHSA-p4f5-76q4-ffq7 に該当しない(意味は D4)
- web と api の build と dev サーバーが今までどおり動く

### 範囲外

- `bun audit` で残る js-yaml / esbuild / minimatch。#26 で見送ったもので、親パッケージがバージョンを固定している
- vite 以外の依存の更新(vite が依存する Rolldown など、vite の更新に伴って上がるものを除く)
- vite の設定(`vite.config.ts`)の変更。今の設定は攻撃の成立条件に当たらない(調査結果 2)

---

## 調査結果(2026-11-19 確認)

### 1. vite の脆弱性 GHSA-p4f5-76q4-ffq7

- 公開: 2026-11-10。深刻度は critical(CVSS v4 9.1)。CVE は未採番
- 内容: `__vite-browser-external:<suffix>` / `__vite-optional-peer-dep:<suffix>` の仮想モジュールが、URL から作ったモジュール ID をエスケープせずにコードへ埋め込んでいた。dev サーバーへの HTTP リクエストで次のことができた
  - `server.fs` の許可外にあるファイルの読み出し(注入した `import` の参照先が許可扱いになる)
  - dev サーバー上での任意のコード実行(`new Worker` / `import.meta.glob` の解析に使う `eval` を経由する)
- 影響を受けるバージョン: 8.3.0〜8.3.6 / 8.2.0〜8.2.4 / 8.0.0〜8.1.6 / 7.x 〜7.3.7 / 4.0.0〜6.4.5
- 修正版: 8.3.7。v8 では問題のコードが Rolldown のバイナリにあり、8.3.7 は Rolldown 1.2.17 の修正に依存する
- 攻撃の成立条件: dev サーバーを `--host` か `server.host` でネットワークに公開していること
- 最新版は 8.3.8(2026-11-11 公開。Rolldown `~1.2.18` に依存)

出典:
- https://github.com/vitejs/vite/security/advisories/GHSA-p4f5-76q4-ffq7
- `npm view vite time` / `npm view vite@8.3.8 dependencies`

### 2. このリポジトリへの影響

| 項目 | 状態 | 出典 |
|---|---|---|
| 使っている vite | 8.3.5(`apps/web`・`apps/api` とも `^8.3.5`)。影響を受ける | `apps/*/package.json`、`bun.lock` |
| Rolldown | 1.2.16。修正(1.2.17)より古い | `bun.lock` |
| dev サーバーの公開 | どちらの `vite.config.ts` にも `server.host` が無く、`dev` スクリプトにも `--host` が付いていない。localhost でしか待ち受けない | `apps/*/vite.config.ts`、`apps/*/package.json` |
| 本番 | Cloudflare Workers には `vite build` の成果物だけが載り、dev サーバーは動かない。影響を受けない | #20 |
| `vite preview` | `apps/web` に `preview` スクリプトがある。アドバイザリが対象にしているのは dev サーバー | `apps/web/package.json` |

**結論:** 今の設定のままなら外から狙われることはない。ただ、`--host` を付けて起動したときや、同じマシンで動く別のプロセスからは攻撃が成立しうる。critical なので修正版に上げる。

### 3. nginx

- 追跡されているファイルに、nginx の設定・Dockerfile・compose ファイル・nginx の利用箇所は無い(`git grep -i nginx` が 0 件)
- 配信は Cloudflare Workers で、nginx を経由しない
- **結論:** このリポジトリは影響を受けない。リポジトリの外(ローカル環境など)で nginx を使っているかは、このタスクでは確認していない

### 4. その他の `bun audit` の結果

- js-yaml(high 3 件・moderate 1 件)、esbuild(moderate)、minimatch(moderate)が出る。いずれも #26 で見送ったもので、範囲外とする

---

## 要件

### 機能要件

- R1. `apps/web` と `apps/api` が使う vite を、GHSA-p4f5-76q4-ffq7 の修正版にする(D2)

### 非機能要件

- R2. web と api の `vite build` が今までどおり成功する
- R3. web と api の dev サーバー(`bun run dev`)が今までどおり起動し、ページ・API に応答する
- R4. lint / check-types が今までどおり通る

## 仕様

- 外から観測できる振る舞い(画面・API)は変わらない
- `apps/web/package.json` と `apps/api/package.json` の vite の指定を `^8.3.8` にし、lock を更新する。lock の vite は 8.3.8 以上、Rolldown は 1.2.17 以上になる

---

## 未決事項

なし

## 決定事項

| ID | 決定日 | 内容 | 理由 |
|---|---|---|---|
| D1 | 2026-11-19 | 通常のフローを縮めて進める。issue を作り、design.md / acceptance.md / impl.md を置き、実装は kn-implementer、検証は lint / check-types / build と dev サーバーの起動確認、その後にコードレビュー・コミット・PR。受け入れ要件は R1〜R4 と完了条件の確認(バージョン・`bun audit`・lint と型検査・build・dev サーバーの起動)にとどめ、画面や API の個別の振る舞いの確認は足さない | ユーザーが選択。パッチバージョンを 1 つ上げるだけで、外から見た振る舞いは変わらない。全段階を規約どおり踏む案と、#26 のように文書を作らない案もあった。「絞る」の範囲は、acceptance.md のレビューで出た確認を受けて、承認の際にユーザーがこの解釈を承認した(当初の文言は「build と dev サーバーが動くことに絞る」。R1・R4 に対応する受け入れ要件が無くなるため範囲を明確にした) |
| D2 | 2026-11-19 | vite を `^8.3.8`(現時点の最新)に上げる。他の依存は上げない | ユーザーが承認。8.3.7 が修正版で、8.3.8 はその後のパッチ |
| D3 | 2026-11-19 | main から `fix/33-vite-vuln` を切って作業する。#24 のブランチ(`feat/24-cd`)には入れない | ユーザーが選択。#24 の PR と混ぜない |
| D4 | 2026-11-19 | 完了条件の「GitHub のアドバイザリで GHSA-p4f5-76q4-ffq7 に該当しない」は、アドバイザリのページに書かれた影響範囲に lock の vite のバージョンが入らないこと、と読む。Dependabot のアラートが閉じることは含めない | acceptance.md の承認の際にユーザーが承認。Dependabot のアラートはマージ後にしか確かめられない |
