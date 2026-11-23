# デプロイ(CD・手動デプロイ・ロールバック)

web(Worker `kin-niku-log`)と api(Worker `kin-niku-log-api`)を Cloudflare Workers へデプロイする仕組みと手順。
決定の経緯は [`docs/issues/24-cd/design.md`](../issues/24-cd/design.md)、実装の方針は同じ場所の `impl.md` を参照。
CD で使う Cloudflare API トークンの仕様と入れ替えは [`cloudflare-api-token.md`](cloudflare-api-token.md)。

**トークンの値とアカウント ID は、この文書・issue・ログに書かない。**

## CD の仕組み

ワークフロー: `.github/workflows/deploy.yml`(名前は「Deploy」)。

### 起動条件

| 起動 | 動く範囲 |
|---|---|
| main への push(PR のマージ) | デプロイ前の確認 → デプロイ → デプロイ後の確認(下のとおり) |
| Actions の画面からの手動実行(`workflow_dispatch`)を main で行う | 同上 |
| 手動実行を main 以外のブランチで行う | デプロイ前の確認(`check` ジョブ)まで。デプロイとデプロイ後の確認はしない(トークンも使わない) |

- PR では動かない(PR ごとのプレビュー環境は作らない)
- 変更の内容による絞り込みはしない。起動のたびに web と api の両方をデプロイする(ドキュメントだけのマージもデプロイされる)
- main のデプロイは 1 本ずつ動く。実行中のものは最後まで走り、待っているものは最新の 1 本だけ残る。main 以外の実行は、この順番待ちに入らない

### 流れ

1. `check` ジョブ(Environment なし。すべての起動で動く)
   - `bun run lint` / `bun run check-types`
   - api と web を `cf build` で 1 回だけビルドする
   - 両アプリで `cf deploy --prebuilt --mode production --dry-run`
   - `scripts/cd/check-api-bundle.sh`: api の本番バンドルに、開発用のもの(`/doc`・`/openapi.yaml` のルートと中身、`localhost:3000`)が入っていないことを確かめる
   - 両アプリの Build Output をアーティファクトとして上げる(保持 1 日)
   - どれかが失敗したら、どちらの Worker もデプロイしない
2. `deploy` ジョブ(main だけ。Environment `production` のトークンを使う)。`check` が上げた Build Output を戻し、ビルドせずにデプロイする
   1. api をデプロイする
   2. api の確認(`scripts/cd/smoke.sh api`)
   3. web をデプロイする
   4. web の確認(`scripts/cd/smoke.sh web`)
   - 途中で失敗したら、後の step は動かない。api のデプロイまたは確認が失敗したら、web はデプロイされない

### デプロイ後の確認

| 対象 | 確認 |
|---|---|
| api | `GET /health` が 200 / `GET /doc` と `GET /openapi.yaml` が 404 / 許可オリジン以外の `Origin` を付けたリクエストに `Access-Control-Allow-Origin` が付かない |
| web | `GET /` が 200 |

確認ごとに、通るまで最大 10 回・6 秒間隔で再試行し、通らなければワークフローを失敗にする。

- 既知の制約: デプロイ直後に古い版が応答すると、404 や許可ヘッダーが無いことの確認は、新しい版が壊れていても通りうる。受け入れ済み(design.md の D20)

### デプロイが行われたことの確認

`cf deploy` は、条件によっては何も上げずに終了コード 0 で終わる。そのため各デプロイの前後で `cf workers deployments list` から最新のデプロイの ID を取り、同じままなら「何も上げずに終わった」として失敗にする。

### 失敗したとき

- ワークフローが失敗になり、GitHub から実行した人へメールが届く(通知設定による)。**自動では戻さない**。戻すかどうかは人間が判断し、必要なら下の手順で手でロールバックする(自動ロールバックは #32)
- 失敗した step を実行ログで確認する。`check` ジョブの失敗ならデプロイは行われていない
- 直して再びデプロイするときは、**main からの手動実行**(Actions の「Deploy」→ Run workflow → ブランチ main)か、修正の PR のマージで行う。失敗した実行の **Re-run は使わない**。アーティファクトの保持は 1 日で、1 日を過ぎて失敗したジョブだけを Re-run すると `deploy` が成果物を取れずに失敗する。全ジョブの Re-run は、その実行の古いコミットで作り直して上書きする

## 手動デプロイ(予備の手段)

CD が使えないとき(トークンの期限切れ・障害時)の予備。人間が行う。エージェントは本番への `cf deploy` を実行しない。

`cf` は、`apps/api` などのディレクトリで `node_modules/.bin/cf` として呼ぶ(グローバルには入れていない。シェルに同じ名前のエイリアスや関数があると、`cf` だけではそちらが動く)。

1. `cf auth login` でログインする(ふだんはログアウトしている。[`cloudflare-api-token.md`](cloudflare-api-token.md) の「ローカルの認証情報」)
2. 依存を入れ、api と web を `cf build` する(`apps/api` と `apps/web` のそれぞれで)
3. api の本番バンドルの確認: リポジトリのルートで `scripts/cd/check-api-bundle.sh`
4. 両アプリで `cf deploy --prebuilt --mode production --dry-run` を実行し、検証が通ることを確かめる
5. **api → web** の順に、それぞれ `cf deploy --prebuilt --mode production` を実行する
6. 確認は CD と同じスクリプトを使える
   - `scripts/cd/smoke.sh api https://kin-niku-log-api.aya-ayatsuki.workers.dev`
   - `scripts/cd/smoke.sh web https://kin-niku-log.aya-ayatsuki.workers.dev`
7. 終わったら `cf auth logout` でログアウトする

## 手でのロールバック

主にダッシュボードで行う。手で戻しても、次に main の CD が動くと、そのときの成果物で上書きされる(古い実行の Re-run を含む)。そのため、CD を止めてから戻し、原因を直したら CD を再開して 1 回デプロイする。

1. CD を止める: リポジトリの **Actions** でワークフロー「Deploy」を開き、右上の **⋯ → Disable workflow** にする
2. 実行中・順番待ちの「Deploy」の run を Actions で確かめ、あれば **Cancel** する。Disable にしても、すでに実行中の run や順番待ちの run は取り消されず、手で戻した後にそのデプロイが動いて戻した版を上書きしうるため
   - **順番待ちの run を先に Cancel し、その後に実行中の run を Cancel する。** 実行中の run を先に Cancel すると、待っていた run がすぐ走り出す
   - Cancel した run が止まった(Cancelled・Success・Failure のいずれかで終わった)ことを確かめる
   - 最後に、「Deploy」の run が 1 本も実行中・順番待ちに無いことをもう一度確かめる
   - Cancel が済んだ後に、両 Worker の Deployments の先頭(手順 3 で開く画面)を見て判断する。Cancel した run(Cancel の前に終わった run を含む)が出したデプロイが先頭にあれば、そのデプロイも手順 3〜4 で戻す対象に含める。「Deploy api」/「Deploy web」の step の途中で止まった場合も、ここで判断する(step は完了と表示されなくても、Cloudflare 側ではアップロードが済んで新しい版が出ていることがある)
3. Cloudflare のダッシュボードで、戻したい Worker(`kin-niku-log` か `kin-niku-log-api`)の **Deployments** を開く
4. 戻したいバージョンを選び、ロールバックする
5. 上の `scripts/cd/smoke.sh` で、戻した後の状態を確かめる
6. 原因を直した PR を main にマージする(Disable の間は、push では何も動かない)
7. **Enable workflow** で CD を再開する。戻し忘れると、以降のマージでデプロイされない
8. **main からの手動実行**(Actions の「Deploy」→ Run workflow → ブランチ main)で 1 回デプロイする。Disable の間のマージは、Enable に戻しても後から実行されない。手動実行をしないと、本番はロールバックした版のまま、main と本番がずれて残る

注意:

- web と api は別々にデプロイされる。片方だけ戻すか、両方戻すかは状況で判断する
- `cf` で戻す(`cf workers versions list` / `cf workers deployments create`)場合は、その時だけ人間が `cf auth login` でログインする。この方法は未検証

## 手動デプロイと CD の関係

- 通常のデプロイは CD で行う。手動デプロイは、CD が使えないときの予備
- 手動デプロイの手順は、#20 の初回デプロイの手順(`docs/issues/20-initial-deploy/impl.md` の「デプロイ手順」)を CD に合わせて直したもの。#20 の文書はタスクの記録として残し、直さない
- 手動でデプロイしても、次に main の CD が動くと、その時点の main で上書きされる
