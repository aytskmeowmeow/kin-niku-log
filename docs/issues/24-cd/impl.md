# #24 GitHub Actions から本番環境へ自動デプロイ(CD) — impl.md

- 仕様: `docs/issues/24-cd/design.md`(決定事項 D1〜D22)
- ブランチ: `feat/24-cd`
- PR は `Refs #24` で作り、issue を自動で閉じない(D17)

---

## 実装状況

| # | 項目 | 担当 | 状態 |
|---|---|---|---|
| 1 | ワークフロー `.github/workflows/deploy.yml`(D1〜D6・D9・D10・D12・D14・D15・D18) | kn-implementer | 完了(2026-11-19、実装第 2 回まで。以後は変更なし) |
| 2 | スクリプト `scripts/cd/check-api-bundle.sh`(D5 の (3)・D21)と `scripts/cd/smoke.sh`(D6) | kn-implementer | 完了(2026-11-19、実装第 2 回まで。以後は変更なし) |
| 3 | 運用文書 `docs/operations/deploy.md` を新規に作り、README と `docs/project-overview.md` からリンクする。`docs/project-overview.md` の CI/CD の現状の記述を直す(D11・D16 の (1)) | kn-implementer | 完了(2026-11-23、実装第 5 回まで) |
| 4 | 運用文書 `docs/operations/cloudflare-api-token.md` を直す(下の「文書」の節。D1・D8・D16 の (3)・#23 D4) | kn-implementer | 完了(2026-11-19、実装第 1 回。以後は変更なし) |
| 5 | 検証(下の「検証方法」) | メイン | 完了(2026-11-19。「検証の結果」) |
| 6 | コードレビュー(kn-code-reviewer)→ コミット | メイン | 完了(2026-11-23。コードレビューは第 5 回で終了) |
| 7 | 理解度チェック → PR(`Refs #24`)→ マージ | メイン・ユーザー | 理解度チェックは完了(2026-11-23)。PR は進行中 |
| 8 | マージ後の本番での確認: 最初の CD の実行とトークンの権限(#23 D6・D19)/ main からの手動実行(D1)/ main 以外からの手動実行(D12)/ わざと壊した検証用のブランチからの実行(D13 の抜き取り: lint・型・`localhost:3000`)/ main の順番待ち(D10)/ main 以外が順番待ちに入らないこと(D15)/ PR で動かないこととプレビュー URL(D9) | **ユーザー**(メインがログの読み取りを手伝う) | 未着手 |
| 9 | 最初の CD の実行の結果で、トークンの権限の記述を確定させる後続の PR(D16 の (2)・D17・D19)。権限を足した場合は #23 の design.md にも追記する | メイン | 未着手 |
| 10 | ローカルの `cf` のログアウト(#23 D4) | **ユーザー** | 未着手 |
| 11 | 8〜10 の結果を記録し、issue #24 を閉じる(D17) | メイン・ユーザー | 未着手 |

---

## 構成

| ファイル | 種別 | 役割 |
|---|---|---|
| `.github/workflows/deploy.yml` | 新規 | CD のワークフロー。ジョブ `check`(デプロイ前の確認とビルド)と `deploy`(main だけ。デプロイとデプロイ後の確認) |
| `scripts/cd/check-api-bundle.sh` | 新規 | api の Build Output のバンドルに、開発用のもの(`/doc` のルート・`openapi.yaml` の中身・`localhost:3000`)が含まれていないかを調べる。含まれていれば終了コード 1 |
| `scripts/cd/smoke.sh` | 新規 | デプロイ後の確認。対象(api / web)と URL を引数で受け取り、決めた回数・間隔で再試行して判定する |
| `docs/operations/deploy.md` | 新規 | CD の仕組み・手動デプロイの手順・手でのロールバックの手順・手動デプロイと CD の関係(D11) |
| `docs/operations/cloudflare-api-token.md` | 変更 | CD に合わせて古い記述を直す(下の「文書」) |
| `docs/project-overview.md` | 変更 | CI/CD の現状の記述(「未設定」)を直し、「2. CI/CD」から `docs/operations/deploy.md` にリンクする |
| `README.md` | 変更 | `docs/operations/deploy.md` へのリンク |

---

## 技術的判断

### ジョブを `check` と `deploy` に分ける

- Environment `production` はジョブ単位で指定する。Deployment branches が `main` だけなので、`environment: production` を付けたジョブは main 以外から動かすと、ジョブが始まる前に止まる。1 つのジョブにすると、main 以外からの実行でデプロイ前の確認まで動かせない(D12)
- `check`: Environment なし。すべての起動で動く。lint・型チェック・ビルド・dry-run・api のバンドルの確認を行い、両アプリの Build Output をアーティファクトとして上げる
- アーティファクト(`actions/upload-artifact` v7.0.2 と `actions/download-artifact` v8.0.2。VM からはアクションの説明を見られないので、メインとレビュアーが各アクションの action.yml・README で確かめた挙動を書く):
  - **アプリごとに 1 つずつ上げる**(名前は固定: `build-output-api` と `build-output-web`)。それぞれ `path` は 1 つ(`apps/api/.cloudflare/output` / `apps/web/.cloudflare/output`)。複数のパスを 1 つにまとめると、全パスの最も近い共通の祖先(ここでは `apps`)がアーティファクトのルートになり、戻す場所を取り違えやすいため
  - `include-hidden-files: true`。既定は false で、ドットで始まるファイル・ディレクトリが落ちる(api の Build Output には `bundle/.vite/manifest.json` がある)。落ちると、確かめた成果物と上げる成果物が同じでなくなる(D4)
  - `if-no-files-found: error`。既定は warn で、0 件でもアップロードが成功する
  - `retention-days: 1`(実行の中で受け渡すだけなので、長く残さない)
  - 戻すときは、download に **`name` を指定し**(省くと全部を `<path>/<アーティファクト名>/` の下に展開する)、`path` を元の場所(`apps/api/.cloudflare/output` / `apps/web/.cloudflare/output`)にする。パスを 1 つで上げたアーティファクトは、その中身がルートに置かれる
  - `deploy` の step の順: checkout → setup(Node・bun)→ `bun install --frozen-lockfile` → download(2 つ)→ 元の場所に Build Output(`config.json` など)があるかの確認(無ければ失敗)→ デプロイ。download を checkout より先にしない(checkout が作業ディレクトリを片付け、ignore されている `.cloudflare/` も消しうる)
- `deploy`: `needs: check`、`if: github.ref == 'refs/heads/main'`、`environment: production`。アーティファクトを元の場所に戻し、ビルドせずに上げる(D4。ビルドは実行全体で 1 回)
- `cf` を動かすため、`deploy` でも checkout と `bun install --frozen-lockfile` は行う(ビルドはしない)
- シークレット(`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID`)は、`cf` で Cloudflare の API を呼ぶ step の `env` にだけ渡す。ジョブ全体の `env` には置かない

### 起動条件・順番待ち

- `on: push: branches: [main]` と `workflow_dispatch`(入力なし)。`pull_request` は付けない(D1・D9)
- `paths` / `paths-ignore` は付けない。変更の内容で絞り込まない(D2)
- `concurrency` はワークフロー単位で付け、`cancel-in-progress: false`。グループ名は、`github.ref` が `refs/heads/main` なら固定の名前(例: `deploy-production`)、それ以外は実行ごとに一意(`github.run_id` を含める)にする(D10・D15)。push と手動実行は、main なら同じグループに入る
- ジョブ単位の `concurrency` にしない理由: `check` が終わる順は起動の順と限らず、古い実行の `deploy` が新しい実行の後に走ると、古い版で上書きしうる。ワークフロー単位なら、起動の順に 1 本ずつになる
- GitHub の `concurrency` は、待ちが 1 本だけ残る(新しい待ちが来ると古い待ちは取り消される)。D10 の「待っているものは最新の 1 本だけ」はこの仕様どおり

### 実行環境

- Node は `actions/setup-node`(入力 `node-version`)で 22.23.5(ルートの `volta.node` と同じ)。`cf` の実行ファイルは `#!/usr/bin/env node` で Node で動き、`cf` の engines(`^22.23.0 || ^24.22.0 || ^26.12.0`)に合う版に固定する
- bun は `oven-sh/setup-bun`(入力 `bun-version`)で 1.4.4(ルートの `packageManager` と同じ)。依存は `bun install --frozen-lockfile`
- `cf` は各アプリの devDependency で、ルートの `node_modules/.bin` には無い。各アプリのディレクトリ(`working-directory: apps/api` など)で `node_modules/.bin/cf` を実行する
- ワークフロー単位の `env` に `CF_SEND_TELEMETRY: "false"`
- `permissions: contents: read` だけ。`actions/checkout` は `persist-credentials: false`
- アクションはコミット SHA で固定する(既存の `cf-token-expiry-reminder.yml` と同じ)。実装エージェントの VM は GitHub に通信できないので、メインが調べた次の値を使う(2026-11-19 確認。いずれも公開から 1 か月以上たった安定版):

| アクション | 版 | コミット SHA |
|---|---|---|
| `actions/checkout` | v7.0.1 | `3d3c42e5aac5ba805825da76410c181273ba90b1` |
| `actions/setup-node` | v7.1.0 | `949feb2413d6458794dcd2491c4babbbce0c15c1` |
| `oven-sh/setup-bun` | v2.2.0 | `0c5077e51419868618aeaa5fe8019c62421857d6` |
| `actions/upload-artifact` | v7.0.2 | `cf430e030ddbb5b0abf93d22962f4752f3646cd9` |
| `actions/download-artifact` | v8.0.2 | `9000827ccba6bdab643e8b6fd33ac0654aef8333` |

- 各ジョブに `timeout-minutes` を付ける(`check` 15 分、`deploy` 25 分。`deploy` はデプロイ後の確認の再試行が最悪の場合に長くかかるため、余裕を持たせる)

### デプロイ前の確認(`check` ジョブ、D5)

順に実行し、どれかが失敗したらジョブを失敗にする(後の step は動かない。`deploy` も動かない):

1. `bun run lint` / `bun run check-types`(turbo 経由。ビルドには依存しない)
2. api と web のそれぞれで `cf build`。`bun run build`(turbo の `vite build`)は使わない。理由: #20 の手動デプロイと公式の CI の例が `cf build` → `cf deploy --prebuilt` の組み合わせで、この組み合わせで確かめられている。turbo のキャッシュから成果物を復元する経路も通さない(ビルドは毎回その場で行う)。mode は Vite のビルドが既定で `production` を記録し、`--prebuilt --mode production` がそれと照合する(D4)
3. api と web のそれぞれで `cf deploy --prebuilt --mode production --dry-run`(認証不要。API を呼ばない)
4. `scripts/cd/check-api-bundle.sh`

`scripts/cd/check-api-bundle.sh`:

- 対象は、api の **実行されるバンドルだけ**(D21): `apps/api/.cloudflare/output/v0/workers/default/bundle/` の下の、`.map` 以外の `.js`・`.mjs`・`.cjs` ファイルすべてと、`mainModule` が指すファイル(拡張子によらず)。今は `index.js` だけ。将来チャンクに分かれたり拡張子が変わったりしても調べ漏らさないため。調べたファイルが 0 個なら失敗にする。同じディレクトリの `index.js.map`(ソースマップ)には元のソースが入っていて、本番のビルドでも `/doc` や `localhost:3000` を含むので対象にしない。`bundle/` の外(アセットなど)も対象にしない
- メインモジュールがあることも確かめる: `worker.config.json` の `manifest.mainModule`(`bundle/` からの相対パス。今の値は `index.js`)が指すファイルが無ければ失敗にする(調べるものが無いのに通さない)
- 調べるもの: `localhost:3000` / `/doc` のルートの登録 / `/openapi.yaml` のルートの登録 / `openapi.yaml` の中身(ファイルに特有の文字列で判定する)。ルートのパスは、バンドラの更新で引用符が変わっても見逃さないよう、引用符の種類(二重・単一・バッククォート)によらず拾う
- 注意(#20 impl.md): `@hono/swagger-ui` の import は本番のバンドルにも残り、モジュールの定数がバンドルに入る。判定の文字列は、今の本番ビルドでは通り、開発用のビルドでは失敗するものを選ぶ。実際のバンドルを見て決め、選んだ理由をスクリプトのコメントに 1〜2 行で残す
- 開発用のビルドの作り方: api の `isDev` は `import.meta.env.DEV` で、Vite はこれを `--mode` ではなく `NODE_ENV` で決める(`NODE_ENV` が `production` でなければ DEV が true。build の既定の `NODE_ENV` は production)。`vite build --mode development` だけでは `isDev` は false のまま。`NODE_ENV=development` を付けて api をビルドし、そのバンドルに `/doc` のルートなどが実際に入ったことを先に確かめてから、判定の文字列を選ぶ。確かめた後は、通常の `cf build` で本番のビルドに戻す
- `.cloudflare/` は gitignore されている。VM の作業場所にはビルドの成果物が無いので、VM の中で `cf build` してバンドルを作る(`cf build` は認証不要)
- 見つかったときは、何が見つかったかを標準エラーに出す

### デプロイと、デプロイが行われたことの確認(`deploy` ジョブ、D3・D14・D18)

順に実行する。どれかが失敗したら後の step は動かない:

1. api のデプロイ
2. api のデプロイ後の確認(`scripts/cd/smoke.sh` の api)
3. web のデプロイ
4. web のデプロイ後の確認(`scripts/cd/smoke.sh` の web)

各デプロイ(1・3)は次の形にする:

- `cf deploy` の前に、その Worker の最新のデプロイの ID を `cf workers deployments list --worker <Worker 名>` で取る(一覧の先頭が、今トラフィックを受けているデプロイ)
- `cf deploy --prebuilt --mode production` を実行する。終了コードが 0 以外なら失敗
- 終了コードが 0 でも、もう一度最新のデプロイの ID を取り、前と同じなら「何も上げずに終わった」として失敗にする(D18)
- 出力の形(2026-11-19 にメインがローカルで実物を確かめた。`cf` 1.0.0-beta.26、非対話で整形済みの JSON が標準出力に出る): `{"deployments": [{"id": "<UUID>", "source": "...", "versions": [{"version_id": "<UUID>", "percentage": 100}], "created_on": "...", ...}, ...]}`。ID は `.deployments[0].id`(GitHub ホストランナーには `jq` がある)。取り出せなかったとき(空・`null`・形が違う)も失敗にする
- 応答には `author_email` などが含まれる。一覧の JSON をそのままログに出さない(取り出した ID だけを出す)
- この一覧の取得に、トークンの権限(2 つの Worker の Editor)が足りるかは未確認。足りなければ最初の CD の実行で分かり、読み取り系から最小限足す(#23 D6・D19。実装状況 9 で扱う)

`continue-on-error` は使わない。`if: always()` などで失敗の後に step を動かすこともしない。

### デプロイ後の確認(`scripts/cd/smoke.sh`、D6・D14)

- 引数で対象(`api` / `web`)と URL を受け取る(本番の URL はワークフローの `env` に書く。api は `https://kin-niku-log-api.aya-ayatsuki.workers.dev`、web は `https://kin-niku-log.aya-ayatsuki.workers.dev`。web の URL は api の `PRODUCTION_WEB_ORIGIN` と同じ)。URL を引数にするのは、ローカルの dev サーバーに向けて失敗の判定を確かめるため(検証方法)
- api: `GET /health` が 200 / `GET /doc` が 404 / `GET /openapi.yaml` が 404 / 許可オリジン以外の `Origin` を付けた `GET /health` の応答に `Access-Control-Allow-Origin` が無い
- 許可オリジン以外の `Origin` は、既定を `https://example.com` とし、環境変数で差し替えられるようにする(ローカルの dev サーバーに `http://localhost:3000` を付けて向け、許可ヘッダーで失敗する判定を確かめるため。検証方法 5)
- web: `GET /` が 200
- 再試行: 確認ごとに、通るまで **最大 10 回、6 秒間隔**(最初の試行を含めて 10 回)で繰り返す。最後まで通らなければ、何を期待して何が返ったかを出して終了コード 1。#20 ではデプロイ直後の 1 回目だけ `/openapi.yaml` が 500 だった。回数・間隔は環境変数で上書きできるようにしてよい(ローカルの検証を短くするため。ワークフローでは上書きしない)。値を変えたい事情があれば、変えずに報告する
- 既知の制約(D20): デプロイ直後に古い版が応答すると、404 や許可ヘッダーが無いことの確認は、新しい版が壊れていても通りうる。受け入れ済みで、対策は入れない
- `curl` は応答コードとヘッダーだけを見る。接続の失敗も「通らない」として再試行の対象にする
- 1 回の試行の時間に上限を付ける: `curl --connect-timeout 5 --max-time 10`。上限が無いと、接続が固まったときに 1 回で数分かかり、再試行の想定とジョブの `timeout-minutes` が崩れる

### 文書

- `docs/operations/deploy.md`(D11): CD の仕組み(起動条件、main 以外からの手動実行の振る舞い、デプロイの順序と確認の時点、デプロイ前・後の確認の中身、失敗したときの扱い(通知だけで、戻すかは人間が判断する。自動ロールバックは #32))/ 手動デプロイの手順(CD が使えないとき(トークンの期限切れ・障害時)の予備。#20 の impl.md の「デプロイ手順」を今の形に直す: 人間が `cf auth login` でログインして行い、終わったらログアウトする、順序は api → web、確認は CD と同じスクリプトを使える)/ 手でのロールバックの手順(ダッシュボードの Deployments から戻す方法を主にする。手で戻しても、次に main の CD が動くと(古い実行の Re-run を含む)そのときの成果物で上書きされる、という注意を添える。CD のやり直しは main からの手動実行で行い、Re-run は使わない(アーティファクトの保持は 1 日で、1 日を過ぎて失敗したジョブだけを Re-run すると `deploy` が成果物を取れずに失敗する。全ジョブの Re-run は、その実行の古いコミットで作り直して上書きする))/ 手動デプロイと CD の関係。手でのロールバックは、コードレビューを受けて、CD を止める(Disable)→ 実行中・待ちの run の Cancel → 戻す → 原因を直した PR のマージ → CD を再開(Enable)→ main からの手動実行、の流れにした
- `docs/operations/cloudflare-api-token.md`:
  - 「入れ替え」の手順 3: CD を動かす方法を、Actions のワークフロー「Deploy」(名前は実装に合わせる)を main で手動実行する形で書く
  - 「ローカルの認証情報」: 「#24 で CD が動くまでは〜」の記述を外し、ふだんはログアウトしておくことを今の運用として書く
  - 「初回の発行」の手順 5 の「Required reviewers は今は付けない(付けるかは #24 で決める)」を、アプリのデプロイには付けない(#24 の D8)に書き換える
  - 「トークンの仕様」の「権限はまだ確定していない」は**この PR では変えない**。最初の CD の実行の結果を受けて後続の PR で直す(D17、実装状況 9)
- `docs/project-overview.md`: 「リポジトリの現状(2026-10-03 時点)」の表の CI/CD の行(「未設定」)を、CD が入った状態に直す。見出しの時点はほかの行に関わるので変えず、この行に「(#24 で導入)」と時点を添える。「2. CI/CD」の節に `docs/operations/deploy.md` へのリンクを足す
- `README.md`: `docs/operations/deploy.md` へのリンクを足す(置き場所は README の構成に合わせる)
- `docs/issues/20-initial-deploy/` の文書は直さない(タスクの記録として残す)

---

## 検証方法

テスト基盤が入るまでは、`bun run lint` / `bun run check-types` / `bun run build` を検証とし、テスト(単体テスト・受け入れテスト)は省く(kn-dev-workflow の「5. 検証」)。ワークフローは main に入るまで動かせないので(D17)、マージ前はワークフローの中で動くコマンドとスクリプトをローカルで確かめる。

メインがローカル(macOS)で行う:

1. `bun run lint` / `bun run check-types` / `bun run build`
2. `bun install --frozen-lockfile` が通る(lock を変えていない)
3. `check` ジョブと同じ順で、api と web の `cf build` → `cf deploy --prebuilt --mode production --dry-run` が通る
4. `scripts/cd/check-api-bundle.sh` が、今の本番ビルドで通る。`NODE_ENV=development` を付けてビルドした api のバンドル(`/doc` のルートなどが実際に入ったことを先に確かめる)では失敗し、何が見つかったかを出す。バンドルが無いときも失敗する。確かめた後は本番ビルドに戻す
5. `scripts/cd/smoke.sh` を本番の URL に向けると、api・web とも通る(今の本番は #20 のデプロイのまま)。ローカルの dev サーバー(`bun dev`。api は 8080、web は 3000)に向けると、api は `/doc`・`/openapi.yaml` が 200 なので、再試行の後に失敗する。許可オリジン以外の `Origin` を `http://localhost:3000` に差し替えて dev サーバーに向けると、許可ヘッダーが付くので失敗する。web を止めた状態で web に向けると、接続の失敗が再試行の後に失敗になる。再試行の回数・間隔は短くして確かめる
6. ワークフローの YAML: actionlint は入っていない(ローカルにも無い)ので、機械的な構文検証はしない。レビューとマージ後の実行で代える
7. D13 の (1)〜(6)(本番を壊さないと起きない失敗の経路)は、コードレビューで確かめる。うち (4)(デプロイ後の確認の判定)は上の 5 でも、(5) のうち `/doc`・`openapi.yaml` の混入の検出は上の 4 でも確かめる。(5) の dry-run の失敗の検出(失敗したら後の step が動かないこと)、(6)(D18)、(1)〜(3) の失敗の後に後の step・ジョブが動かないことは、ローカルでは確かめられない

kn-implementer にも、VM の中(認証情報なし、`.cloudflare/` と turbo のキャッシュが無い作業場所。CI の `check` ジョブに近い)で、`check` ジョブと同じ順(`bun install --frozen-lockfile` → lint → check-types → api と web の `cf build` → dry-run → `scripts/cd/check-api-bundle.sh`)を通しで流させ、結果を報告させる。

マージ後の本番での確認はユーザーが行い、メインが実行ログの読み取りを手伝う(実装状況 8)。

### 検証の結果(2026-11-19)

kn-implementer(VM、Linux、認証情報なし。VM に Node が無かったため Node 24.22.3 を入れた。CI は 22.23.5):

- `.cloudflare/` と turbo のキャッシュを消した作業場所で、`bun install --frozen-lockfile` → lint → check-types → api と web の `cf build` → dry-run → `check-api-bundle.sh` を通しで流し、すべて通った。`bun run build` も通った
- `check-api-bundle.sh` の判定の文字列は `localhost:3000` / `"/doc"` / `"/openapi.yaml"` / `openapi: ` の 4 つ(固定文字列。実装第 1 回の時点。第 2 回でルートのパスは引用符によらない正規表現に変えた)。`swagger` は本番にも `@hono/swagger-ui` の import で残るため使わない
- `smoke.sh`: VM の dev サーバーに向けて、api の `/doc`・`/openapi.yaml` が 200 で失敗、`SMOKE_FOREIGN_ORIGIN=http://localhost:3000` で許可ヘッダーにより失敗、web は通る、サーバーの無いポートは `000` で失敗、引数が不正なら終了コード 2。本番の URL には VM から届かなかった(プロキシが 403)

メイン(macOS):

1. `bun install --frozen-lockfile`(変更なし)/ `bun run lint` / `bun run check-types` / `bun run build`: 成功
2. api と web の `cf build` → `cf deploy --prebuilt --mode production --dry-run`: 成功(api 62.00 KiB、web 0.00 KiB、ともに `No bindings found.`)
3. `check-api-bundle.sh`: 本番ビルドで `ok`(.js 1 個)。`NODE_ENV=development` のビルド(バンドルに `"/doc"` が入ったことを先に確かめた)では 4 つとも報告して終了コード 1。Build Output が無いディレクトリでは終了コード 1。確かめた後に本番ビルドに戻し、`ok` を確かめた
4. `smoke.sh` を本番の URL に向けて、api(4 項目)・web とも通った。ローカルの dev サーバーの api に向けて `/doc`・`/openapi.yaml` が 200 で失敗、`SMOKE_FOREIGN_ORIGIN=http://localhost:3000` で許可ヘッダーにより失敗。サーバーの無いポートの web は `000` で失敗。引数が不正なら終了コード 2
5. ワークフローの YAML は機械的な構文検証をしていない(actionlint なし)


### 文書の読み合わせ(2026-11-23、メイン。マージ前に確かめる文書の項目)

- `docs/operations/deploy.md`: D11 の 3 項目(CD の仕組み / 手動デプロイの手順 / 手でのロールバックの手順)と「手動デプロイと CD の関係」がある。CD の仕組みに、起動条件と main 以外からの手動実行の振る舞い、デプロイの順序と確認の時点、デプロイ前・後の確認の中身、失敗したときの扱い(通知だけ。戻すかは人間が判断。自動ロールバックは #32)がある
- README と `docs/project-overview.md` から `docs/operations/deploy.md` へのリンクがある。`docs/project-overview.md` の CI/CD の現状は「CD は導入済み。PR 時の CI は未設定」に直っている(D16)
- `docs/operations/cloudflare-api-token.md`: 入れ替えの手順 3 が main からの手動実行、ローカルの認証情報が現在の運用(ふだんはログアウト)、Required reviewers が D8 に合わせた記述になっている。「権限はまだ確定していない」はマージ後の最初の CD の結果を受けて後続の PR で直す(D17)ため、今は残している

---

## 既知の制約・未解決の疑問

- ワークフローは main に入るまで動かせない。`workflow_dispatch` も、ワークフローが main にあって初めて Actions の画面に出る
- 最小権限のトークン(2 つの Worker の Editor)で、`cf deploy`(workers.dev のサブドメインを取るアカウント単位の API を呼ぶ)と `cf workers deployments list` が通るかは未確認(#23 D6)。最初の CD の実行で分かる
- `cf` は beta(1.0.0-beta.26)。出力の形やコマンドが変わりうる。D18 の確認が出力の形に依存するので、`cf` を上げるときは確認が動くかを見る
- **未確認:** 前回と同じ内容のまま `cf deploy` したときに、新しいデプロイが作られるか。`cf` が「変更なし」として新しいデプロイを作らずに終了コード 0 で終わると、ドキュメントだけのマージ(D2 でデプロイの対象)や main からの手動実行の連続のたびに、D18 の確認で失敗する。最初の CD と、その直後の main からの手動実行で分かる。省かれると分かったら、D2 と D18 の関係を design.md の未決事項に上げる
- デプロイ直後に古い版が応答すると、デプロイ後の確認の一部(404・許可ヘッダーが無いこと)は新しい版が壊れていても通りうる(D20。受け入れ済み)
- 本番の URL はワークフローと api の `PRODUCTION_WEB_ORIGIN` の 2 か所にある。Worker 名や workers.dev のサブドメインを変えるときは両方を直す
- deploy.md の手でのロールバックの手順 2(D22。コードレビュー第 5 回の指摘で、実装に戻さず記録したもの):
  - 戻す対象は「Cancel した run が出したデプロイが Deployments の先頭にあるか」で決めるが、先頭のデプロイがどの run のものかを見分ける方法は書いていない(ダッシュボードの時刻と run の step の時刻を突き合わせるしかない)。また、Cancel の前に Success で終わった run の版も戻す対象になり、不要な戻しが 1 回増えることがある。本番は壊れない(戻し先は人が選び、手順 5 の smoke.sh で確かめ、手順 6〜8 で main の版に戻る)。見直すときは、判断の軸を「両 Worker の先頭が、戻したい(正常と分かっている)バージョンか」に変えると run の見分けがいらなくなる(#32 で手でのロールバックを見直すときの候補)
  - 手順 2 の「最後に、…もう一度確かめる」の後ろに Deployments で判断する項目があり、「最後に」が手順 2 の最後ではない(読みやすさだけ。順番は読み取れる)

---

## レビュー指摘と対応

### ドキュメントレビュー第 1〜3 回(2026-11-17、acceptance.md)

- acceptance.md のレビュー。第 1 回 17 件、第 2 回 15 件、第 3 回 6 件
- 仕様に関わる指摘は、ユーザーの判断を受けて design.md の D13 の変更と D14〜D18、D17 の追記として決定した(内容は design.md の決定事項と変更履歴)
- 記述の指摘は acceptance.md の文面で対応した。第 3 回の対応は文面の修正だけで要件の追加・変更を伴わないため、第 4 回は行っていない

### ドキュメントレビュー第 1 回(2026-11-19、impl.md、17 件: 記述 14 / 仕様 3)

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| A1 | 開発用のビルドを `--mode development` で作れるとしていたが、`import.meta.env.DEV` は `NODE_ENV` で決まる | `NODE_ENV=development` で作り、`/doc` が入ったことを先に確かめる手順に直した(技術的判断・検証方法 4) | 対応済み |
| A2 | アーティファクトの既定(隠しファイルを落とす、0 件でも成功、brace 展開しない)を書いていない | 入力(`path` 2 行、`include-hidden-files`、`if-no-files-found`、`retention-days`)と戻し方を書いた | 対応済み |
| A3 | `cf schema` で応答の形が見られるとしていたが、出るのはリクエストの定義だけ | メインがローカルで一覧の実物を確かめ、形と ID の取り出し方を書いた。一覧の JSON をログに出さないことも足した | 対応済み |
| A4 | Build Output を広く調べると、ソースマップに元のソースがあり本番でも失敗する | 対象を実行されるバンドルに限った(仕様 B3 → D21) | 対応済み |
| A5 | 実装状況 4 の「D4」が #24 の D4 と読める | 「#23 D4」に直した | 対応済み |
| A6 | `cf build` を使う理由(mode の記録)が不正確 | 実際の理由(#20 と公式の例の組み合わせ、turbo のキャッシュを通さない)に直した | 対応済み |
| A7 | 検証方法で D13 の (1)〜(6) との対応が書かれていない | 検証方法 7 に対応を書いた | 対応済み |
| A8 | 実装状況 8 の確認項目が「など」に埋もれている | design.md の決定を出典にして列挙した | 対応済み |
| A9 | setup-node / setup-bun の入力名が無い | 入力名を足した | 対応済み |
| A10 | 「Node 22 以上」が不正確 | `cf` の engines に合う版に固定する、に直した | 対応済み |
| A11 | 再試行の回数・間隔が「目安」 | 最大 10 回・6 秒間隔に確定させた | 対応済み |
| A12 | D2(絞り込まない)が書かれていない | `paths` / `paths-ignore` を付けないと書いた | 対応済み |
| A13 | 手でのロールバックが次の CD で上書きされる注意が無い | deploy.md に添えるよう書いた | 対応済み |
| A14 | 許可ヘッダーで失敗する判定をローカルで確かめる手段 | 許可オリジン以外の `Origin` を環境変数で差し替えられるようにし、検証方法 5 に足した | 対応済み |
| B1 | D18 の確認に使うデプロイの一覧の権限を、#23 D6 の枠で足してよいか | ユーザーの判断で D19 として決定 | 対応済み |
| B2 | 古い版の応答で 404・許可ヘッダーの確認が通りうる | ユーザーの判断で D20(既知の制約として受け入れる) | 対応済み |
| B3 | バンドルの確認にソースマップを含めるか | ユーザーの判断で D21(実行されるバンドルだけ) | 対応済み |

### ドキュメントレビュー第 2 回(2026-11-19、impl.md、10 件: 記述 9 / 仕様 1)

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | 複数のパスのアーティファクトは共通の祖先(`apps`)がルートになり、リポジトリのルートに戻すと元の場所に置かれない | アプリごとに 1 つずつ上げ、名前を指定して元の場所に戻す形に変えた | 対応済み |
| 2 | download で `name` を指定するかが無い | `name` を固定して指定すると書いた | 対応済み |
| 3 | `deploy` の checkout と download の順が無い | step の順を書いた | 対応済み |
| 4 | `curl` の 1 回の試行に時間の上限が無い | `--connect-timeout 5 --max-time 10` を書いた | 対応済み |
| 5 | バンドルの確認をメインモジュール 1 つに限ると、チャンクが分かれたときに漏れる。`mainModule` の起点が曖昧 | `bundle/` の下の `.map` 以外の `.js` すべてを対象にし、メインモジュールの有無も確かめる形にした。起点(`bundle/`)を書いた | 対応済み |
| 6 | 同じ内容の `cf deploy` で新しいデプロイが作られるかが未確認 | 未解決の疑問に足した。最初の CD とその直後の手動実行で確かめる | 対応済み(確認はマージ後) |
| 7 | メインのローカルはログイン済みで、CI の `check` と条件が違う | kn-implementer に VM の中で `check` と同じ順を通しで流させる、と書いた | 対応済み |
| 8 | project-overview の表の見出しに時点がある | 行に「(#24 で導入)」を添える、と書いた | 対応済み |
| 9 | アーティファクトの保持 1 日と Re-run の関係 | deploy.md に、やり直しは main からの手動実行で行うと添える、と書いた | 対応済み |
| S1 | 同じ内容のデプロイが省かれる場合、D2 と D18 がぶつかる | 6 の確認の結果を待つ。省かれると分かったら design.md の未決事項に上げる | 保留(条件付き) |

- 指摘以外: design.md の決定事項の表の並び(D18〜D21 が D13 の後にあった)を番号順に直した

### コードレビュー第 1 回(2026-11-19、7 件。すべて実装で閉じる)

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | `check-api-bundle.sh` は調べたファイルが 0 個でも通る。`.mjs`/`.cjs` に変わると何も調べずに通る | 0 個なら失敗にし、`mainModule` が指すファイルを必ず対象に含め、`.mjs`/`.cjs` も対象にする。実装に戻す | 実装第 2 回で対応 |
| 2 | `"/doc"` などの判定が二重引用符に依存している | 引用符の種類に依存しない判定にする。実装に戻す | 実装第 2 回で対応 |
| 3 | `deploy` の `timeout-minutes: 15` が、デプロイ後の確認の最悪の所要時間に対して短い | `deploy` を 25 分にする(impl.md も直した)。実装に戻す | 実装第 2 回で対応 |
| 4 | impl.md の `CF_SEND_TELEMETRY` の置き場所の記述が実装とずれている | impl.md を「ワークフロー単位の `env`」に直した | 対応済み |
| 5 | スクリプトを実行ビットに頼って直接実行している。既存のワークフローは `bash <スクリプト>` の形 | 既存に合わせて `bash scripts/cd/...` で呼ぶ。実装に戻す | 実装第 2 回で対応 |
| 6 | deploy.md の「CD が動かないようにしてから戻す」の方法が無い | 方法(Actions でワークフローを Disable にし、直したら Enable に戻す)を書く。実装に戻す | 実装第 2 回で対応 |
| 7 | 「Deploy api」と「Deploy web」の `run` が同じ内容で重複している | 対応見送り。重複は 2 か所で、共通化の目安(3 回以上)に届かない。`cf` を上げたときは両方を見る(既知の制約に `cf` の出力への依存を書いてある) | 対応見送り |

- lint 化の候補: なし

### 実装第 2 回の検証(2026-11-19、メイン、macOS)

- `bun run lint` / `bun run check-types` / `bun run build`: 成功
- `check-api-bundle.sh`: 本番ビルドで `ok`(1 個)、`NODE_ENV=development` のビルドで 4 つとも報告して終了コード 1、本番ビルドに戻して `ok`
- kn-implementer(VM)の報告: 一時ディレクトリに写した Build Output で、単一引用符・バッククォートの混入、`.mjs` への変更、拡張子の無い `mainModule`、`mainModule` の欠落をいずれも検出した。調べるファイルが 0 個になる前に `mainModule` の確認で止まるため、0 個の判定は単独では再現できない(防御として残す)

### コードレビュー第 2 回(2026-11-19、3 件。すべて実装で閉じる)

第 1 回の修正 1・2・3・5 は妥当と確認された。AC の失敗時の経路(D13)も修正の後も保たれている。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | deploy.md の「CD を止めてから戻す」で、Enable に戻した後のデプロイが無い。無効の間のマージはデプロイされず、main と本番がずれたまま残る(D2) | Enable に戻したら main からの手動実行で 1 回デプロイする、と書き足す。実装に戻す | 実装第 3 回で対応 |
| 2 | 同じ箇所で、Disable しても実行中・待ちの run は取り消されない。手で戻した後にその run が上書きしうる | Disable の後に、実行中・待ちの「Deploy」の run が無いことを確かめ、あれば Cancel してから戻す、と書き足す。実装に戻す | 実装第 3 回で対応 |
| 3 | impl.md の技術的判断(バンドルの確認の対象と判定)が、第 1 回の修正後の実装とずれている | impl.md を実装に合わせて直した | 対応済み |

- lint 化の候補: なし

### 実装第 3 回の検証(2026-11-19、メイン)

- 変更は `docs/operations/deploy.md` の「手でのロールバック」だけ(番号付きの手順 8 つに組み直し、Disable の後の run の確認と Cancel、Enable の後の main からの手動実行を足した)。コード・設定に触れていないので、lint / check-types / build は前回の結果のまま

### コードレビュー第 3 回(2026-11-19、4 件。すべて実装で閉じる)

第 2 回の指摘 1・3 の対応は妥当と確認された。ワークフローとスクリプトは第 2 回から変わっておらず、D13 の失敗時の経路は保たれている。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | deploy.md の手でのロールバックの手順 2 に、Cancel の順が無い。実行中の run を先に Cancel すると、待っていた run が走り出す | 順番待ちの run を先に、実行中の run を後に Cancel し、最後に 1 本も残っていないことを確かめる、と書く。実装に戻す | 実装第 4 回で対応 |
| 2 | 手順 2 の「どちらの Worker のデプロイも終わっていないことを確かめてから次へ進む」が、何をすればよいか分からない | Cancel した run が止まったことを確かめ、その run がデプロイの step を終えていたら、そのデプロイも戻す対象に含める、と書く。実装に戻す | 実装第 4 回で対応 |
| 3 | impl.md の技術的判断の deploy.md の要旨に、手でのロールバックの流れが無い | impl.md に流れを足した | 対応済み |
| 4 | impl.md のバンドルの確認の「調べるもの」に `/openapi.yaml` のルートが無い。検証の結果の判定の文字列の記述が、今の判定と読み違えられる | 「調べるもの」に足し、検証の結果に時点の注記を添えた | 対応済み |

- lint 化の候補: なし

### 実装第 4 回の検証(2026-11-19、メイン)

- 変更は `docs/operations/deploy.md` の手でのロールバックの手順 2 だけ(Cancel の順、止まったことの確認、最後の確認、終えていたデプロイの扱い)。コード・設定に触れていないので、lint / check-types / build は前回の結果のまま
- 実装に戻した回数は 3 回(第 2〜4 回)で、上限に達した

### コードレビュー第 4 回(2026-11-19、2 件)

第 3 回の指摘 1〜4 の対応は妥当と確認された。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | deploy.md の手でのロールバックの手順 2 で、戻す対象を「run がデプロイの step を終えていたか」で決めている。step の途中で Cancel が効いても、新しい版が出ていることがある | 実装の戻りが上限(3 回)に達したため design.md の U12 に上げた。ユーザーが ① を選び(D22)、実装第 5 回で対応 | 実装第 5 回で対応 |
| 2 | 同じ手順で「Cancelled になったことを確かめる」とあるが、Cancel の前に終わった run は Success / Failure になり、先へ進めない | 同上 | 実装第 5 回で対応 |

- lint 化の候補: なし

### 実装第 5 回の検証(2026-11-23、メイン)

- U12 でユーザーが ① を選び(D22)、上限を超える 1 回として実装に戻した
- 変更は `docs/operations/deploy.md` の手でのロールバックの手順 2 だけ(止まったことの確認を Cancelled・Success・Failure のいずれでもよいとし、戻す対象は Cancel の後に両 Worker の Deployments の先頭を見て判断する)。コード・設定に触れていないので、lint / check-types / build は前回の結果のまま
- D22 により、この節へのこの後のレビュー指摘は実装に戻さず、既知の制約として記録する

### コードレビュー第 5 回(2026-11-23、3 件)

第 4 回の指摘 1・2 は D22 のとおりに直ったと確認された。本番を壊しうる問題は無い。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | deploy.md の手でのロールバックの手順 2 で、先頭のデプロイがどの run のものかを見分ける方法が無い。Cancel の前に Success で終わった run の版も戻す対象になる(重大さ: 低。本番は壊さない) | D22 により実装に戻さず、既知の制約に記録した | 既知の制約 |
| 2 | 同じ手順 2 で「最後に」が最後の項目ではなくなった(重大さ: なし。読みやすさだけ) | 同上 | 既知の制約 |
| 3 | impl.md の冒頭(D1〜D21)と実装状況の表(各項目の回数・日付、コードレビューが未着手のまま)が実態とずれている | impl.md を直した | 対応済み |

- lint 化の候補: なし

---

## 理解度チェック(2026-11-23)

質問は HTML のページで出した(ユーザーの依頼)。2 回のやり取りで、4 問とも説明できるようになった。

| # | 質問 | 観点 | 回答の要点 | 解説した点 |
|---|---|---|---|---|
| 1 | ワークフローを `check` と `deploy` の 2 つのジョブに分けたのはなぜか。分けなかったら何ができなくなるか | なぜこの設計か | 1 回目: check はすべてのブランチで、deploy は main だけで動かすため。手動実行の余地を残すため(理由の核が無い)。再質問(1 ジョブに `environment: production` を付けて main 以外から実行したら): main 以外は production ではないので失敗する | Environment はジョブ単位でしか指定できない。production(トークンあり)は main に絞ってあるので、1 ジョブだと main 以外からの実行は確認ごと弾かれる。分ければ check はトークン無しでどこからでも動く(D12)。起動は main への push と手動実行だけで、ほかのブランチへの push では動かない |
| 2 | api のデプロイは成功し、直後の確認が失敗したら、ワークフロー・web・本番の api・通知はどうなるか | 異常系 | web はデプロイしない。失敗のメールが届く。api は確認に通らなかった新しい版のままで、戻すかは人間が判断する。1 回で完了 | 後の step が動かないのは `continue-on-error` や `if: always()` を使っていないため(D3・D7・D14)。メールは実行した人へ(通知設定による) |
| 3 | README だけを直した PR をマージすると本番で何が起きるか。この動きで未確認のことは何で、どう確かめるか | 影響範囲 | 1 回目: ワークフローは動き、変更が無ければ失敗扱いになる。同じ内容の `cf deploy` の動きは未確認(両方がデプロイされる点と、確かめ方が無い)。再質問: 動作確認で同じ内容のまま動かし、ID が変わるかを見る | api と web の両方がデプロイされ、両方の確認も走る(D2)。確かめるのはマージ後の main からの手動実行で、Deploy の step のログの `before:` / `after:` と Cloudflare の Deployments を見る。作られないなら D2 と D18 がぶつかるので、design.md の未決事項に上げてユーザーが決める(この点は再質問の回答に無く、解説で補った) |
| 4 | 何も上げずに終わった `cf deploy` を、どこでどう見分けているか。それが動かなくなりうるのはどんな変更のときか | どこを見れば挙動が分かるか | 1 回目: デプロイの前後で ID を取って比べる。ID が取れないときや、ID の取得を外したときに動かなくなる(取れないときは安全側に倒れる点と、`cf` の更新の影響が無い)。再質問: `cf` のアップデートで動作が変わる場合 | 場所は `.github/workflows/deploy.yml` の「Deploy api」「Deploy web」の step で、`cf workers deployments list` の先頭の ID を比べる(D18)。ID が取れないときは step を失敗にするので素通りしない。`cf` は beta で、上げると出力の形や並び順が変わりうる。先頭が最新でなくなると誤判定する(既知の制約) |

- ユーザーの判断: このまま進む
