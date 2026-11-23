# #32 CD のデプロイ後の確認が失敗したら自動でロールバックする — impl.md

- 仕様: `docs/issues/32-cd-auto-rollback/design.md`(決定事項 D1〜D18)
- ブランチ: `feat/32-cd-auto-rollback`
- PR は `Refs #32` で作り、issue を自動で閉じない(D14)

---

## 実装状況

| # | 項目 | 担当 | 状態 |
|---|---|---|---|
| 1 | ワークフロー `.github/workflows/deploy.yml` の変更(下の「ワークフロー」の節。D1〜D9・D11・D13・D15〜D17) | kn-implementer | 未着手 |
| 2 | スクリプト `scripts/cd/current-deployment.sh` と `scripts/cd/rollback.sh` を新しく作る(下の「スクリプト」の節。D2〜D5・D15・D18) | kn-implementer | 未着手 |
| 3 | 運用文書 `docs/operations/deploy.md` を直す(下の「文書」の節) | kn-implementer | 未着手 |
| 4 | 検証(下の「検証方法」) | メイン | 未着手 |
| 5 | コードレビュー(kn-code-reviewer)→ コミット | メイン | 未着手 |
| 6 | 理解度チェック → PR(`Refs #32`)→ マージ | メイン・ユーザー | 未着手 |
| 7 | マージ後の本番での確認(D6・D10。権限が足りなければ D12) | **ユーザー**(メインがログの読み取りを手伝う) | 未着手 |
| 8 | 7 の結果を記録し、issue #32 を閉じる(D14)。`deployments create` が今のトークンで通ったら、`docs/operations/cloudflare-api-token.md` の「トークンの仕様」の、Editor だけで足りることを書いた箇条(通った操作を挙げている)に足す。足りずに権限を足したら、D12 のとおり同じ文書と #23 の design.md に書く。`docs/operations/deploy.md` の「手でのロールバック」の注意も、確認の結果に合わせて確定させる | メイン・ユーザー | 未着手 |

---

## 構成

```
.github/workflows/deploy.yml     # 変更: 入力・戻し先の記録・失敗扱い・ロールバック・issue のジョブ・コメントの更新
scripts/cd/current-deployment.sh # 新規: Worker の今の先頭のデプロイ(ID と versions)を 1 行の JSON で出す
scripts/cd/rollback.sh           # 新規: 戻す → 一覧で確かめる → 戻した後の確認 → 結果を出力
scripts/cd/smoke.sh              # 変更なし(戻した後の確認にもそのまま使う)
docs/operations/deploy.md        # 変更: 自動ロールバックの説明
```

---

## 技術的判断

### 共通

- 式の値(入力・step の出力・シークレット)は `run:` に `${{ }}` で直接埋め込まず、step の `env` を経由してシェルに渡す(`cf-token-expiry-reminder.yml` と同じ書き方)
- `cf` を呼ぶ step(戻し先の記録・デプロイ・ロールバック)の `env` にだけ、`CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` を渡す(#24 と同じ)
- `cf` を呼ぶ step は、#24 と同じく `working-directory: apps/<app>` で動かし、そのアプリの `node_modules/.bin/cf` を使う。スクリプトは `bash ../../scripts/cd/<名前>.sh` で呼ぶ
- 一覧の JSON には `author_email` などが含まれる。**ログにも step の出力にも、ID と `versions`(`version_id` と `percentage`)以外を出さない**(#24 と同じ)

### ワークフロー(`.github/workflows/deploy.yml`)

- **入力**: `workflow_dispatch` に `simulate_check_failure`(`type: choice`、選択肢 `none` / `api` / `web`、既定 `none`、説明は「動作確認用: デプロイ直後の確認を失敗扱いにする Worker。main からの実行でだけ効く」)を足す。push では値が空になるので、空も `none` と同じに扱う(D6)
- `check` ジョブは変えない。入力を見ない(main 以外からの実行は、入力を指定しても `check` までで成功して終わる。#24 D12)
- **`deploy` ジョブ**(main だけ。#24 と同じ):
  - `timeout-minutes: 40`(D16)
  - `permissions` は書かない(ワークフロー単位の `contents: read` のまま)。issue の権限は付けない(D13)
  - step の順:
    1. checkout / Node / Bun / install / アーティファクトの取り出しと確認(今のまま)
    2. **「Record api's current deployment」**(`id: api_before`、`working-directory: apps/api`): `bash ../../scripts/cd/current-deployment.sh kin-niku-log-api` の結果(1 行の JSON)を、出力 `deployment` に、その `id` を出力 `id` に書く。取れなければ step を失敗にし、デプロイに進まない(D11)
    3. **「Deploy api」**(`id: deploy_api`): `cf deploy` の前の ID は、2 の出力 `id` を env で受け取って使う(今は step の中で取っている)。デプロイの後に `current-deployment.sh` で先頭の ID を取り直し、同じなら失敗にする(#24 D18。判定は今のまま)
    4. **「Smoke test api」**(`id: smoke_api`): env `SIMULATE`(入力の値)が `api` なら、`::error::` で「確認を失敗扱いにした(main からの手動実行の入力 simulate_check_failure)」と出して終了コード 1。それ以外は今のまま `smoke.sh`(D6・D15)
    5. **「Record web's current deployment」**(`id: web_before`)、**「Deploy web」**(`id: deploy_web`)、**「Smoke test web」**(`id: smoke_web`): api と同じ(Worker は `kin-niku-log`、`working-directory: apps/web`、`SIMULATE` が `web` のとき失敗扱い)
    6. **「Roll back」**(`id: rollback`): 下の条件で動く。`scripts/cd/rollback.sh` を呼ぶ
  - ジョブの `outputs`: `rollback_status: ${{ steps.rollback.outputs.status }}`、`rollback_worker: ${{ steps.rollback.outputs.worker }}`、`rollback_version: ${{ steps.rollback.outputs.version }}`
- **ロールバックの step**(D1・D2・D11):
  - 対象は step の結果から決める:
    - `deploy_api` か `smoke_api` の `outcome` が `failure` → api(web はまだデプロイしていない)
    - `deploy_web` か `smoke_web` の `outcome` が `failure` → web(api は戻さない。D1)
    - それ以外(戻し先の記録の失敗、アーティファクトの失敗など)→ 動かない。その Worker はまだデプロイしていないので issue も作らない(D11)。知らせは失敗のメールとログだけ。web の戻し先の記録で失敗した場合、api は新しい版のまま(確認は通っている)
  - `if:` は `failure()` と、上の 4 つの `outcome` のどれかが `failure` であることの組み合わせ
  - 対象(`api` / `web`)、Worker 名、確認の URL(`API_URL` / `WEB_URL`)、戻し先の JSON(`steps.api_before.outputs.deployment` か `steps.web_before.outputs.deployment`)は、式で選んで step の `env` に入れる
  - `working-directory` も「共通」の規則どおり、式で対象のアプリを選ぶ(`apps/api` か `apps/web`。api の step が失敗していれば `apps/api`、そうでなければ `apps/web`)。`rollback.sh` は `bash ../../scripts/cd/rollback.sh` で呼び、`cf` は既定の `node_modules/.bin/cf`(対象のアプリのもの)を使う
  - 「デプロイの step が失敗したが、新しいデプロイが作られていた」かの判断(D2)は、`rollback.sh` の中で、今の先頭の ID を戻し先の ID と比べて行う。デプロイの step の中でデプロイ後の一覧を取れずに失敗した場合も、`rollback.sh` が一覧を取り直し、取れれば判断を続ける。D2 の「判断できないとき」は、ロールバックの時点で一覧を取れず、新しいデプロイの有無を決められないこと(`rollback.sh` の手順 1・4 の失敗)と解釈した。取り直しで決められるなら、戻すかどうかを正しく判断できるため
- **`report-rollback` ジョブ**(D5・D7・D8・D9・D13・D17):
  - `needs: deploy`、`runs-on: ubuntu-latest`、`timeout-minutes: 5`
  - `if: ${{ !cancelled() && contains(fromJSON('["failed","unhealthy"]'), needs.deploy.outputs.rollback_status) }}`(`deploy` が動かなかったとき・ロールバックが動かなかったときは outputs が空で、偽になる。実行を Cancel したときは、ロールバックの途中でも issue を作らない)
  - `permissions: contents: read` と `issues: write`(このジョブにだけ `issues: write` を付ける。D13。`contents: read` は手本の reminder と同じにするため)
  - checkout はしない。step の `env` に `GH_TOKEN: ${{ github.token }}`、タイトル、ジョブの outputs の 3 つ、実行の URL(`${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}`)、運用文書の URL(`.../blob/main/docs/operations/deploy.md`)を渡す。`gh` には `--repo "${GITHUB_REPOSITORY}"` を付ける
  - 中身は `cf-token-expiry-reminder.yml` と同じ形(D10): `set -o pipefail`。open な issue を `gh issue list --state open --limit 1000 --json number,title` で全件取り、タイトルの完全一致で絞る(`--search` は使わない、ラベルで絞らない)。0 件なら `gh issue create --title "[運用] CD の自動ロールバックに失敗した" --label human --label ops --body ...`。1 件以上なら、番号が最も大きい 1 件に `gh issue comment ... --body ...`(D7・D8)
  - 本文・コメント(D17): 対象の Worker、状況(`failed` は「戻せなかった」、`unhealthy` は「戻したが確認が通らない」と戻した版)、実行の URL、手でのロールバックの手順(運用文書の URL)への案内。末尾は、本文では「この issue は .github/workflows/deploy.yml が自動で作成しました」、コメントでは「このコメントは .github/workflows/deploy.yml が自動で付けました」
  - `gh` が失敗したら step を失敗にする(ワークフローは `deploy` の失敗ですでに失敗で終わる)
  - 重複の判定は「数えてから作る」なので、同時に動くと 2 件作られうる。main の実行はワークフロー単位の `concurrency` で 1 本ずつ動く(#24 D10)ので、`report-rollback` 同士は並行しない
- 失敗を成功に変える指定(`continue-on-error`)は使わない。ロールバックの step は(引数の誤りと予期せず止まった場合を除き)終了コード 0 で終わる。どちらで終わっても、前の step がすでに失敗しているので、ジョブは失敗で終わる
- **既存のコメントを直す**: 冒頭の「仕様: docs/issues/24-cd/design.md(D1〜D21)」に #32 の design.md を足す。`deploy` ジョブの「continue-on-error や if: always() は使わない(どこかで失敗したら、後の step は動かない)」を、ロールバックの step(`if: failure()`)と `report-rollback`(`always()`)が入ったことに合わせて直す

### スクリプト

- **`scripts/cd/current-deployment.sh <Worker 名>`**:
  - 使う `cf` は環境変数 `CF`(既定: `node_modules/.bin/cf`。`apps/<app>` で動かす前提)。ローカルの検証で、偽の `cf` に差し替えるため
  - `cf workers deployments list --worker <名前>` の先頭のデプロイから、`{"id": ..., "versions": [{"version_id": ..., "percentage": ...}, ...]}` を 1 行の JSON で標準出力に出す。`versions` は `version_id` で並べ替える(比較を並び順に左右されないようにする)。ほかのフィールドは出さない
  - `cf` の失敗、JSON でない、先頭が無い、`id` か `versions` が空、のどれでも終了コード 1(理由は標準エラー。一覧の JSON そのものは出さない)
- **`scripts/cd/rollback.sh <api|web> <Worker 名> <戻し先の JSON(current-deployment.sh の出力)> <確認の URL>`**:
  - 使う `cf` は `CF`(既定は同上)。`current-deployment.sh` と `smoke.sh` は、このスクリプトと同じディレクトリのものを使う
  - スクリプトは `set -euo pipefail` で動かす。そのうえで、`cf`(create)・`current-deployment.sh`・`smoke.sh` の失敗は、`set -e` に任せず、戻り値で受けて結果を決める(失敗しても後の処理と出力まで進むように)。それ以外(戻し先の JSON からの `id`・`versions` の取り出しなど)で失敗したときは `set -e` で止まり、下の「予期せず止まったとき」になる
  - 結果は変数に持ち、**終了時に `trap ... EXIT` で `GITHUB_OUTPUT` に 1 回だけ書く**(`status`・`worker`・`version`)。変数の初期値は `status=failed`、`worker` は第 2 引数(無ければ空)。同じキーを 2 回書くことはしない
  - 途中で予期せず止まったとき(注記と実行の概要をまだ出していないとき)は、`trap` の中で `status` を `failed` に置き換え(`version` は空にする)、`failed` の注記(`::error::`)と実行の概要への記載も出してから、`GITHUB_OUTPUT` に書く。D5 の「戻せなかった」の表示がこの経路でも出るように
  - 引数の確認はこの後に行う。誤りは終了コード 2(`status=failed` のまま出力され、issue の対象になる。ワークフローの不具合に気づけるように)
  - 1. 今の先頭を取る(`current-deployment.sh`)。取れなければ `failed`(D2 の「判断できない」)
  - 2. 今の先頭の ID が戻し先の ID と同じなら、新しいデプロイは作られていない。戻すものが無いので `status=not_needed` で終わる(デプロイの step が、デプロイを作る前に失敗した場合)。本番は変わっていないので、D11(本番に触れていなければ issue を作らない)と同じく、`::warning::` と実行の概要への記載だけで、issue の対象にしない
  - 3. `cf workers deployments create --worker <名前> --strategy percentage --versions '<戻し先の versions>'` を実行する。`--bypass-deployment-checks` は付けない(D4)。**標準出力は捨てる**(作られたデプロイの JSON に余計な値が入りうるため)。標準エラーはそのまま流す(失敗の理由を残す)。0 以外で終わったら `failed`(Cloudflare に止められた場合を含む)
  - 4. 一覧を読み直す。取れなければ `failed`(D18)。先頭の ID が 1 の ID から変わっていて、かつ先頭の `versions` が戻し先の `versions` と同じなら「戻した」。そうでなければ `failed`(`cf` が何もせず 0 で終わった場合を含む。D3)。**比べた値(戻し先の ID と `versions`、1 の ID、読み直した先頭の ID と `versions`)と判定をログに出す**(issue の完了条件の「確かめている」がログで見えるように)
  - 5. 戻した後の確認: `smoke.sh <api|web> <URL>` をそのまま流す(入力の失敗扱いは効かない。D15)。通れば `status=rolled_back`、通らなければ `status=unhealthy`
  - 結果ごとに、注記(`rolled_back`・`failed`・`unhealthy` は `::error::`、`not_needed` は `::warning::`)と、`GITHUB_STEP_SUMMARY` への記載(どの結果でも書く)を出す。中身は対象の Worker、結果、戻した版(戻した場合)(D5)
  - `version` は、戻した版の `version_id` を `,` でつないだもの(戻していなければ空)
  - 終了コードは、引数の誤りと予期せず止まった場合を除き 0(結果は出力で伝える)

### 文書(`docs/operations/deploy.md`)

- 「CD の仕組み」に自動ロールバックの節を足す(design.md の要件の「運用文書」と、上のワークフロー・スクリプトの振る舞いを説明する): きっかけ(D2)、戻す範囲(D1)、戻し先(上の「Record … current deployment」の step で取る、その実行のデプロイの前の一覧の先頭のデプロイの `versions`)、戻したことの確かめ方と戻した後の確認(D3・D15)、戻し先を取れないときはデプロイしないこと(D11)、Cloudflare に止められても強制しないこと(D4)
- 今の deploy.md の「流れ」の番号付きの手順に、各 Worker のデプロイの前の「戻し先の記録」と、失敗したときの「ロールバック」と「issue の作成」を足す。同じ節の「途中で失敗したら、後の step は動かない」は、ロールバックが失敗の後に動くので、事実に合わせて直す
- 今の deploy.md の「失敗したとき」を、`rollback.sh` の結果ごとに書き直す(D5・D7〜D9・D11):
  - 戻した: 失敗のメール・実行の概要。main と本番がずれているので、原因を直して main にマージする
  - 戻せなかった・戻したが確認が通らない: 失敗のメール・実行の概要・issue `[運用] CD の自動ロールバックに失敗した`。手でのロールバックへ
  - 戻すものが無かった(`not_needed`): 失敗のメールと実行の概要。その Worker は変わっていない(web の場合、api は新しい版のまま)
  - 戻し先を取れなかった: 失敗のメールとログだけ。その Worker は変わっていない(web の場合、api は新しい版のまま)
  - 同じ節の、自動では戻さないことと「自動ロールバックは #32」を書いた記述は、上と矛盾するので消す
- 確認を失敗扱いにする入力の使い方(D6・D15): main からの手動実行でだけ効く、選んだ Worker のデプロイ直後の確認が失敗扱いになり、その Worker だけがデプロイの前のバージョンに戻る、戻した後の確認は本物、ワークフローは失敗で終わる。訓練やロールバックの確かめに使う
- 「手でのロールバック」は、自動で戻せなかったときの手順として残す。「手でのロールバック」の「注意:」の 2 つ目の箇条(`cf` で戻す場合の注意。「この方法は未検証」で終わる)は、CD が `cf workers deployments create` で戻すようになるので、「CD は `cf workers deployments create` で戻す。本番での確認はマージ後」の形に直す(検証済みとは書かない。手で `cf` を使う場合は、人間がログインする点は残す)。手順 2 の判断の軸の見直し(#24 の impl.md の既知の制約)は、この issue では扱わない
- 時間の上限は、今の deploy.md に記述が無いので、足さない

### 使うアクション

新しいアクションは使わない。`report-rollback` は `gh`(ランナーに入っている)だけを使う。

---

## 検証方法

テスト基盤が無いので、kn-dev-workflow の「5. 検証」に従い、lint / check-types / build に加えて次を行う。2 はメインが行う(kn-implementer も VM で同じ確かめをしてよい。報告に結果を書く)。

1. `bun run lint` / `bun run check-types` / `bun run build`
2. スクリプトを **偽の `cf`(一時ディレクトリに置くシェルスクリプト。環境変数 `CF` で差し替える)** で動かす。偽の `cf` と手順はコミットしない(結果をこの文書に残す)
   - 偽の `cf` は、受け取った引数をファイルに記録する。list と create の両方が返す JSON に `author_email` を含める
   - `GITHUB_OUTPUT` と `GITHUB_STEP_SUMMARY` は一時ファイルに向ける。`SMOKE_ATTEMPTS=1`・`SMOKE_INTERVAL=0` で確認を短くする
   - `current-deployment.sh`: 正常 / 一覧が取れない / JSON が壊れている / 先頭が無い / `id` か `versions` が空 → 正常のときだけ終了コード 0 で、出力に `author_email` が無い
   - `rollback.sh`:
     - 先頭が戻し先と同じ → `not_needed`
     - 最初の一覧が取れない → `failed`
     - create が 0 以外で終わる → `failed`
     - create が何もせず 0 で終わる(一覧が変わらない)→ `failed`
     - 戻した後の一覧の取得に失敗 → `failed`
     - 戻した後の先頭の `versions` が戻し先と違う → `failed`
     - 戻せて、戻した後の確認が通る → `rolled_back`(確認の URL は、web の dev サーバー(`smoke.sh web` で通る)か本番の web の URL。api の dev サーバーは `/doc` が 200 なので `smoke.sh api` が通らない)
     - 戻せて、戻した後の確認が通らない → `unhealthy`(接続できない URL)
     - 引数の誤り → 終了コード 2、`status=failed`
     - 途中で予期せず止まる(例: 戻し先の JSON を、`id` はあるが `versions` が JSON として壊れている形にし、`versions` の取り出しの jq を失敗させる)→ `status=failed`(1 回だけ)、`version` は空、`failed` の注記と実行の概要が出る
   - `versions` の並びが違うだけの一覧(戻し先と同じ中身)が、`current-deployment.sh` で同じ JSON になり、`rollback.sh` で「戻した」と判定される
   - 各経路で、`GITHUB_OUTPUT` に `status`・`worker`・`version` が 1 回ずつ書かれ、値が経路に合う(`rolled_back`・`unhealthy` は `version` に戻した版、それ以外は空)。注記の種類(`::error::` / `::warning::`)と中身(Worker・結果・版)、`GITHUB_STEP_SUMMARY` の中身も経路に合う
   - 記録した引数で、create に `--bypass-deployment-checks` が付いていないことと、`--versions` に戻し先の `versions` が渡っていることを確かめる
   - どの経路でも、`GITHUB_OUTPUT`・`GITHUB_STEP_SUMMARY`・標準出力・標準エラーに `author_email` が出ない
3. ワークフローの YAML は、`check`・`deploy`・`report-rollback` の条件式・outputs・permissions を読み合わせる(機械的な構文検証は無い。#24 と同じ)
4. D10 の経路ごとの確かめ方:

   | 経路 | 確かめ方 |
   |---|---|
   | 確認の失敗で戻して、戻した後の確認が通る(api・web) | マージ後に本番で(D6・D10)。スクリプトは 2 でも通す |
   | デプロイの step の失敗後に戻す(D2) | 判定は 2(`not_needed` と戻す経路)。step の条件はコードレビュー |
   | 戻し先を取れない(D11) | `current-deployment.sh` は 2。デプロイに進まないことはコードレビュー |
   | Cloudflare に止められる・強制しない(D4) | 2(create の失敗、引数の記録)。本番ではコードレビュー |
   | 戻せなかった・戻した後の確認の失敗(D3・D9・D18) | 2。本番ではコードレビュー |
   | issue の作成・コメント(D5・D7・D8・D17) | コードレビューだけ(D10)。`report-rollback` は本番では動かさない。偽の `gh` でのローカルの確かめは足さない。処理は YAML の `run:` の中にあり、ローカルで動かすには写しを作るしかなく、確かめるのが本物でなくなるため。手本の reminder と同じ形(D10)であることをレビューで見る |

5. 本番での確認はマージ後(実装状況 7。D14)

---

## 既知の制約・未解決の疑問

- **未確認:** `cf workers deployments create` が、今のトークン(2 つの Worker の Editor)で通るか。足りなければ D12
- `cf workers deployments create` には、確認を省くフラグ(`-f, --force` など)が無い(2026-11-23 に `--help` で確認。確認を求める `cf workers delete` には `-f, --force` がある)。確認を求めずに動くコマンドと考えられる。何もせず終わっても、一覧の読み直しで `failed` になる(D3)
- 本番で通るのは「戻した後の確認が通る」経路だけ(D10)。`failed`・`unhealthy`・`not_needed` の経路と、`report-rollback` の本体(条件式が真の側)と `issues: write` の権限は、マージ前にも本番でも GitHub Actions の上では動かず、スクリプトの検証(偽の `cf`)とコードレビューで確かめる
- 実行を Cancel したときは、自動では戻さず、issue も作らない(手でのロールバックの手順 2 の、人間の判断に任せる)。ロールバックの step より前の Cancel では `failure()` が偽なので、ロールバックの step は動かない。ロールバックの step の実行中の Cancel では、戻しが途中で止まりうるが、`report-rollback` は `!cancelled()` で動かない
- ジョブが時間切れで止まると、ロールバックの step が動かない恐れがある。上限を 40 分にして避ける(D16)。`report-rollback` は別のジョブなので、40 分の外で動く
- 戻した後も、反映が全拠点に届くまでは新しい版が応答しうる。戻した後の確認は再試行で吸収する
- シークレットとデータは戻らない(design.md の調査結果)
- 一覧の JSON の形に依存している(`cf` は beta)。`cf` を上げるときは、戻し先の記録と戻したことの確かめが動くかを見る

---

## レビュー指摘と対応

### ドキュメントレビュー第 1 回(2026-11-23、impl.md、22 件: 記述 20 / 仕様 2)

仕様の 2 件は、design.md の決定から読み取れる範囲と判断し、根拠を本文に書いた(未決事項には上げない)。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| P1 | 確認を省く指定が D4 とぶつかるかを確かめていない | `--help` で、`deployments create` に確認を省くフラグが無いことを確かめ、既知の制約に書いた | 対応済み |
| P2 | 新しいデプロイが作られていないときの知らせ方を impl.md が決めている | 本番が変わっていないので D11 と同じ扱い(issue なし)、と根拠を書いた | 対応済み |
| 1 | ジョブの outputs の名前が食い違う | `rollback_status`・`rollback_worker`・`rollback_version` に決めた | 対応済み |
| 2 | 新しい step にシークレットを渡すことが無い | 「共通」に書いた | 対応済み |
| 3 | どの `cf` をどのディレクトリで使うかが曖昧 | `working-directory: apps/<app>` とそのアプリの `cf` に決めた | 対応済み |
| 4 | create の標準出力の扱いが無い | 標準出力は捨て、標準エラーは流す。検証で create にも `author_email` を含める | 対応済み |
| 5 | 一覧で確かめた結果をログに出すことが無い | 手順 4 に書いた | 対応済み |
| 6 | 記録の出力の名前と、ロールバックの step への渡し方が無い | 出力 `deployment`・`id`、env 経由で渡す、と書いた | 対応済み |
| 7 | D10 の経路ごとの確かめ方が無い | 検証方法 4 に表を足した | 対応済み |
| 8 | `report-rollback` の権限が手本と違う | `contents: read` も付ける | 対応済み |
| 9 | `report-rollback` の `GH_TOKEN`・`--repo`・`number` など | 書いた | 対応済み |
| 10 | `GITHUB_OUTPUT` を 2 回書く前提と、引数の確認の順 | `trap EXIT` で 1 回だけ書く形にし、初期値に `worker` を含め、引数の確認を後にした | 対応済み |
| 11 | `deploy.yml` の古くなるコメント | 直すことを書いた | 対応済み |
| 12 | 検証の細部(引数の記録、空の経路、URL、短縮、担当) | 検証方法 2 に足した | 対応済み |
| 13 | 実装状況の決定事項の参照 | 直した | 対応済み |
| 14 | 実装状況 7 と文言が受け入れ要件に寄っている | 7 を D6・D10 の参照だけにし、文言を design.md の言い方にした | 対応済み |
| 15 | D12 の更新先と、通った場合の扱い | 実装状況 8 に書いた | 対応済み |
| 16 | `not_needed` で実行の概要に書くか | どの結果でも書く | 対応済み |
| 17 | 手でのロールバックの手順 2 の見直しを扱うか | 扱わないと書いた | 対応済み |
| 18 | `report-rollback` が並行しない前提 | 書いた | 対応済み |
| 19 | 時間の上限の記述と「流れ」に足すもの | 時間の上限は足さない、「流れ」に足すものを書いた | 対応済み |
| 20 | 本番で通らない経路の制約 | 既知の制約に足した | 対応済み |

### ドキュメントレビュー第 2 回(2026-11-23、impl.md、11 件: 記述 10 / 仕様寄り 1)

仕様寄りの #4 は、D2 の解釈を本文に書いて閉じた(未決事項には上げない)。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | ロールバックの step の cwd と `rollback.sh` の呼び方が 2 通り | `working-directory` を式で対象のアプリに選び、`../../scripts/cd/rollback.sh` で呼ぶ、に決めた | 対応済み |
| 2 | 戻し先を取れないときの知らせ方と「本番は変わっていない」 | 戻し先を取れないときはメールとログだけ、`not_needed` は実行の概要あり、と分けた。「その Worker は変わっていない」に直した | 対応済み |
| 3 | 予期せず止まったときに注記と実行の概要が出ない。`set -e` の扱い | 失敗は戻り値で受ける。`trap` でも `failed` の注記と実行の概要を出す。終了コードの記述を限定した | 対応済み |
| 4 | D2 の「判断できない」の解釈 | ロールバックの時点で一覧を取れないこと、と解釈した根拠を書いた | 対応済み |
| 5 | 検証で出力・注記・実行の概要の中身を見ていない | 検証方法 2 に足した | 対応済み |
| 6 | 並べ替えと予期せず止まる経路の検証 | 検証方法 2 に足した | 対応済み |
| 7 | `report-rollback` のローカルの確かめ | 足さない理由を検証方法 4 に書いた | 対応済み |
| 8 | Cancel したとき | 既知の制約に足した | 対応済み |
| 9 | 文書の節が受け入れの判定項目に近い | 各項目に出典(D 番号・今の deploy.md の該当箇所)を添えた | 対応済み |
| 10 | コメントの末尾の文 | 本文とコメントで分けた | 対応済み |
| 11 | 「Editor で通った操作」という見出しは無い | 実在する箇所に直した | 対応済み |

### ドキュメントレビュー第 3 回(2026-11-23、impl.md、9 件: すべて記述。確度「中」1 / 「低」8)

仕様の指摘は無し。すべて直し、記述だけの修正なので第 4 回は回さない。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | 予期せず止まる経路の検証の例が本文と食い違う。`set -e` の扱いが無い | `set -euo pipefail` で動かすことと、戻り値で受けない処理の失敗が「予期せず止まる」になることを書き、検証の例を壊れた `versions` に直した | 対応済み |
| 2 | 止まったときに出力が `rolled_back` のまま残りうる | `trap` で `failed` に置き換え、`version` を空にする | 対応済み |
| 3 | ワークフローの節の終了コードの記述 | スクリプトの節に揃えた | 対応済み |
| 4 | ロールバックの途中の Cancel で issue ができうる | `report-rollback` の条件を `!cancelled()` にし、既知の制約を直した | 対応済み |
| 5 | 本番で動かないものの範囲 | `report-rollback` の本体と権限に限定した | 対応済み |
| 6 | 「直前の版」の参照先が impl.md に無い | 戻し先の取り方を impl.md の中で示し、design.md の言い方に寄せた | 対応済み |
| 7 | deploy.md の文言の引用が実物と違う | 場所と実際の文言で示した | 対応済み |
| 8 | 直した後の書き方と、マージ後の確定 | 実装時点の書き方を指定し、実装状況 8 に deploy.md の確定を足した | 対応済み |
| 9 | `not_needed` の括弧書き | 足した | 対応済み |
