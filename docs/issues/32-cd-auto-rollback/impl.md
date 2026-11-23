# #32 CD のデプロイ後の確認が失敗したら自動でロールバックする — impl.md

- 仕様: `docs/issues/32-cd-auto-rollback/design.md`(決定事項 D1〜D18)
- ブランチ: `feat/32-cd-auto-rollback`
- PR は `Refs #32` で作り、issue を自動で閉じない(D14)

---

## 実装状況

| # | 項目 | 担当 | 状態 |
|---|---|---|---|
| 1 | ワークフロー `.github/workflows/deploy.yml` の変更(下の「ワークフロー」の節。D1〜D9・D11・D13・D15〜D17) | kn-implementer | 完了(2026-11-23。VM で実装、collect 済み) |
| 2 | スクリプト `scripts/cd/current-deployment.sh` と `scripts/cd/rollback.sh` を新しく作る(下の「スクリプト」の節。D2〜D5・D15・D18) | kn-implementer | 完了(2026-11-23。VM で実装、collect 済み) |
| 3 | 運用文書 `docs/operations/deploy.md` を直す(下の「文書」の節) | kn-implementer | 完了(2026-11-23。VM で実装、collect 済み) |
| 4 | 検証(下の「検証方法」) | メイン | 完了(2026-11-23。下の「検証の結果」) |
| 5 | コードレビュー(kn-code-reviewer)→ コミット | メイン | 完了(2026-11-23。コードレビュー 4 回、実装の戻し 3 回) |
| 6 | 理解度チェック → PR(`Refs #32`)→ マージ | メイン・ユーザー | 理解度チェックは完了(2026-11-24。下の「理解度チェック」)。PR は未作成 |
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
    6. **「Decide the rollback target」**(`id: rollback_target`、`if: failure()`): 下の規則で対象を 1 か所で決め、出力 `target`(api / web / 空)・`app`・`worker`・`url`・`prior`(戻し先の JSON)にする。4 つの outcome と 2 つの戻し先の JSON は env で受け取る
    7. **「Roll back」**(`id: rollback`、`if: failure() && steps.rollback_target.outputs.target != ''`): `working-directory` と env は 6 の出力を参照し、`scripts/cd/rollback.sh` を呼ぶ
  - ジョブの `outputs`: `rollback_target`(6 の `target`)、`rollback_status`(7 の `status`)、`rollback_worker`(7 の `worker`。空なら 6 の `worker`)、`rollback_version`(7 の `version`)
  - step 単位の `timeout-minutes`(コードレビュー第 1 回 #2): 戻し先の記録 2 分、デプロイ 5 分、api の確認 12 分、web の確認 4 分、Roll back 15 分。`cf` が応答しないまま止まっても、ジョブの時間切れより先に step が失敗して Roll back が動くようにする。根拠: `smoke.sh` の最悪の所要時間は api が約 10.3 分、web が約 2.6 分。api が失敗する経路は 2+5+12+15=34 分に準備の時間を足して 40 分に収まる
- **ロールバックの対象**(D1・D2・D11。6 の step が決める):
    - `deploy_api` か `smoke_api` の `outcome` が `failure` → api(web はまだデプロイしていない)
    - `deploy_web` か `smoke_web` の `outcome` が `failure` → web(api は戻さない。D1)
    - それ以外(戻し先の記録の失敗、アーティファクトの失敗など)→ 動かない。その Worker はまだデプロイしていないので issue も作らない(D11)。知らせは失敗のメールとログだけ。web の戻し先の記録で失敗した場合、api は新しい版のまま(確認は通っている)
  - 対象の Worker、確認の URL(`API_URL` / `WEB_URL`)、戻し先の JSON(`steps.api_before.outputs.deployment` か `steps.web_before.outputs.deployment`)、アプリのディレクトリも、6 の step がシェルの中で 1 回だけ判定して出力にする(式を何か所にも書かない)
  - Roll back の `working-directory` は「共通」の規則どおり対象のアプリ(6 の `app`)。`rollback.sh` は `bash ../../scripts/cd/rollback.sh` で呼び、`cf` は既定の `node_modules/.bin/cf`(対象のアプリのもの)を使う
  - 「デプロイの step が失敗したが、新しいデプロイが作られていた」かの判断(D2)は、`rollback.sh` の中で、今の先頭の ID を戻し先の ID と比べて行う。デプロイの step の中でデプロイ後の一覧を取れずに失敗した場合も、`rollback.sh` が一覧を取り直し、取れれば判断を続ける。D2 の「判断できないとき」は、ロールバックの時点で一覧を取れず、新しいデプロイの有無を決められないこと(`rollback.sh` の手順 1・4 の失敗)と解釈した。取り直しで決められるなら、戻すかどうかを正しく判断できるため
- **`report-rollback` ジョブ**(D5・D7・D8・D9・D13・D17):
  - `needs: deploy`、`runs-on: ubuntu-latest`、`timeout-minutes: 5`
  - `if: ${{ !cancelled() && needs.deploy.outputs.rollback_target != '' && !contains(fromJSON('["rolled_back","not_needed"]'), needs.deploy.outputs.rollback_status) }}`(コードレビュー第 2 回 #1)。対象が決まっていて、結果が「戻した」「戻すものが無い」以外なら作る。結果が空(ロールバックの step が時間切れなどで結果を書かずに止まった)も「戻せなかった」として拾う。`deploy` が動かなかったとき・対象が無いときは `rollback_target` が空で、偽になる。実行を Cancel したときは、ロールバックの途中でも issue を作らない
  - `permissions: contents: read` と `issues: write`(このジョブにだけ `issues: write` を付ける。D13。`contents: read` は手本の reminder と同じにするため)
  - checkout はしない。step の `env` に `GH_TOKEN: ${{ github.token }}`、タイトル、ジョブの outputs の 3 つ、実行の URL(`${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}`)、運用文書の URL(`.../blob/main/docs/operations/deploy.md`)を渡す。`gh` には `--repo "${GITHUB_REPOSITORY}"` を付ける
  - 中身は `cf-token-expiry-reminder.yml` と同じ形(D10): `set -o pipefail`。open な issue を `gh issue list --state open --limit 1000 --json number,title` で全件取り、タイトルの完全一致で絞る(`--search` は使わない、ラベルで絞らない)。0 件なら `gh issue create --title "[運用] CD の自動ロールバックに失敗した" --label human --label ops --body ...`。1 件以上なら、番号が最も大きい 1 件に `gh issue comment ... --body ...`(D7・D8)
  - 結果が空のときは、`rollback.sh` が注記と実行の概要を出していないので、このジョブの step で `::error::` と実行の概要に状況と Worker を出す(コードレビュー第 3 回 #1)
  - 本文・コメント(D17): 対象の Worker、状況(`failed` は「戻せなかった」、空は「戻せなかった(ロールバックの step が結果を出さずに止まった。戻せたか分からない)」、`unhealthy` は「戻したが確認が通らない」と戻した版)、実行の URL、手でのロールバックの手順(運用文書の URL)への案内。末尾は、本文では「この issue は .github/workflows/deploy.yml が自動で作成しました」、コメントでは「このコメントは .github/workflows/deploy.yml が自動で付けました」
  - `gh` が失敗したら step を失敗にする(ワークフローは `deploy` の失敗ですでに失敗で終わる)
  - 重複の判定は「数えてから作る」なので、同時に動くと 2 件作られうる。main の実行はワークフロー単位の `concurrency` で 1 本ずつ動く(#24 D10)ので、`report-rollback` 同士は並行しない
- 失敗を成功に変える指定(`continue-on-error`)は使わない。ロールバックの step は(引数の誤りと予期せず止まった場合を除き)終了コード 0 で終わる。どちらで終わっても、前の step がすでに失敗しているので、ジョブは失敗で終わる
- **既存のコメントを直す**: 冒頭の「仕様: docs/issues/24-cd/design.md(D1〜D21)」に #32 の design.md を足す。`deploy` ジョブの「continue-on-error や if: always() は使わない(どこかで失敗したら、後の step は動かない)」を、ロールバックの step(`if: failure()`)と `report-rollback`(`!cancelled()`)が入ったことに合わせて直す

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

### 検証の結果(2026-11-23)

- 1: `bun run lint` / `bun run check-types` / `bun run build` はメインの環境で通った(VM では Node が無いので build が通らない。変更前でも同じ)。テスト基盤が無いので、単体テスト・受け入れテストは省いた
- 2: 偽の `cf` での確かめは、ユーザーの了承を得て、メインがスクラッチパッドの使い捨てのスクリプトで行った(コミットしない)。kn-implementer も VM で同じ経路を通している
  - `current-deployment.sh`: 正常は終了コード 0 で、出力は ID と `versions`(`version_id` 順)だけ。一覧の失敗・JSON の破損・先頭なし・`versions` が空は、どれも終了コード 1
  - `rollback.sh`(結果は `GITHUB_OUTPUT` の `status` / `version`):
    - 先頭が戻し先と同じ → `not_needed` / 空(`::warning::`、create は呼ばない)
    - 最初の一覧の失敗 → `failed` / 空
    - create の失敗 → `failed` / 空
    - create が何もせず 0 → `failed` / 空
    - 戻した後の一覧の失敗 → `failed` / 空
    - 戻した後の `versions` の不一致 → `failed` / 空
    - 並びだけ違う一覧で戻せて確認が通る → `rolled_back` / `va,vb`
    - 戻せたが確認が通らない → `unhealthy` / `va,vb`
    - 引数の誤り → 終了コード 2、`failed`
    - 戻し先の `versions` が壊れている(予期せず止まる)→ 終了コード 5、`failed`(1 回だけ)、`version` は空
  - どの経路でも `status`・`worker`・`version` は 1 回ずつ書かれた。注記の種類と、実行の概要の中身(Worker・結果・戻した版)は経路に合っていた
  - create の引数に `--bypass-deployment-checks` は無く、`--versions` には戻し先の `versions` が渡っていた。`author_email` は、出力・実行の概要・ログのどこにも出なかった
  - 確認が通る経路の URL には本番の web(`GET /` だけ)を使った
- 3: ワークフローの条件式・outputs・permissions はメインが読み合わせた。kn-code-reviewer でも見る
- 補足: kn-implementer は VM の中で、deploy.md の編集に一時的な Python スクリプトを使ったと報告した(作業ツリーには残っていない)。成果物には影響しない

---

## 既知の制約・未解決の疑問

- **未確認:** `cf workers deployments create` が、今のトークン(2 つの Worker の Editor)で通るか。足りなければ D12
- `cf workers deployments create` には、確認を省くフラグ(`-f, --force` など)が無い(2026-11-23 に `--help` で確認。確認を求める `cf workers delete` には `-f, --force` がある)。確認を求めずに動くコマンドと考えられる。何もせず終わっても、一覧の読み直しで `failed` になる(D3)
- 本番で通るのは「戻した後の確認が通る」経路だけ(D10)。`failed`・`unhealthy`・`not_needed` の経路と、`report-rollback` の本体(条件式が真の側)と `issues: write` の権限は、マージ前にも本番でも GitHub Actions の上では動かず、スクリプトの検証(偽の `cf`)とコードレビューで確かめる
- 実行を Cancel したときは、自動では戻さず、issue も作らない(手でのロールバックの手順 2 の、人間の判断に任せる)。ロールバックの step より前の Cancel では `failure()` が偽なので、ロールバックの step は動かない。ロールバックの step の実行中の Cancel では、戻しが途中で止まりうるが、`report-rollback` は `!cancelled()` で動かない
- ジョブが時間切れで止まると、ロールバックの step が動かない恐れがある。上限を 40 分にして避ける(D16)。`report-rollback` は別のジョブなので、40 分の外で動く
- 戻した後も、反映が全拠点に届くまでは新しい版が応答しうる。戻した後の確認は再試行で吸収する
- デプロイの step が失敗し、Cloudflare 側ではデプロイが作られた(作られる途中だった)のに、`rollback.sh` が最初に読んだ一覧にまだ出ていないと、`not_needed` になる。その後に確認していない版が先頭になりうる。まれな競合として扱い、取り直しはしない。`not_needed` が出たら、人間が一覧で先頭の版を確かめる(deploy.md の表にも書く)
- `cf` が応答しないまま止まる場合に備え、`cf` を呼ぶ step と確認の step に step 単位の `timeout-minutes` を付ける(下のコードレビュー第 1 回 #2)。step の時間切れは失敗として扱われ、ロールバックの step が動く。ロールバックの step 自体が時間切れで止まると `rollback.sh` の結果が書かれないことがあるが、`report-rollback` は結果が空でも issue を作る(コードレビュー第 2 回 #1)
- step 単位の上限の合計は、web が失敗する経路では 2+5+12+2+5+4+15=45 分で、ジョブの 40 分を超えうる(コードレビュー第 2 回 #3)。各 step が上限近くまでかかることが重なる場合だけで、まれと見て詰めない。ジョブが時間切れになると、ロールバックの step と `report-rollback` は動かないことがある(知らせは失敗のメールだけ)。逆に、ロールバックの step の途中で止まった場合は、戻っていることも、結果が空のまま issue が作られることもある。どちらも、人間がダッシュボードで先頭のデプロイの版を確かめる
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

### コードレビュー第 1 回(2026-11-23、kn-code-reviewer、8 件: すべて実装判断。中 1 / 低 7)

AC-6・AC-7・AC-8 の各項目は満たしていると判定された。仕様の疑問は無し。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | Roll back の step で、対象を選ぶ同じ式が 6 回出てくる。一部だけ直し忘れると対象と戻し先が食い違う | `if: failure()` の小さな step で対象(`target`・`app`・Worker・URL・戻し先)を 1 か所で決めて出力にし、Roll back はそれを参照する | 対応済み(戻り 1 回目) |
| 2 | `cf` にタイムアウトが無く、止まるとジョブの時間切れでロールバックが動かない | `cf` を呼ぶ step と確認の step に step 単位の `timeout-minutes` を付け、ジョブの残り時間で Roll back が動くようにする | 対応済み(戻り 1 回目) |
| 3 | デプロイが一覧に出る前に読むと `not_needed` になる競合 | 取り直しはせず、既知の制約に書き、deploy.md の `not_needed` の行に「先頭の版を一覧で確かめる」を足す | 対応済み(戻り 1 回目) |
| 4 | issue の本文の 1 行目が D2 の経路と `unhealthy` に合わない | 両方の経路と状況に合う文にする | 対応済み(戻り 1 回目) |
| 5 | 失敗扱いの入力を使った後の本番の状態が書かれていない | deploy.md に「実行の後、本番はデプロイの前の版のまま。main と揃えるには入力なしで main から手動実行する」を足す | 対応済み(戻り 1 回目) |
| 6 | impl.md の `always()` と実装の `!cancelled()` の食い違い | メインが impl.md を直した | 対応済み |
| 7 | 新しい 2 つのスクリプトに実行権限が無い | 既存の `scripts/cd/` に合わせて実行権限を付ける | 対応済み(戻り 1 回目) |
| 8 | deploy.md の冒頭に #32 の design.md が無い。「design.md の D20」が曖昧 | 冒頭に足し、「#24 の design.md の D20」にする | 対応済み(戻り 1 回目) |

- lint 化の候補: なし(当たる規約スキルが無い。差分は GitHub Actions の YAML・bash・Markdown)

### コードレビュー第 2 回(2026-11-23、kn-code-reviewer、3 件: すべて実装判断。高 1 / 中 1 / 低 1)

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | Roll back の step 自体が時間切れで止まると、結果が空になり issue も注記も出ない | `rollback_target` をジョブの outputs に出し、`report-rollback` の条件を「対象があり、結果が `rolled_back`・`not_needed` 以外(空を含む)」にする。空は「戻せなかった(結果を出さずに止まった)」と書く。deploy.md の表にも足す | 対応済み(戻り 2 回目) |
| 2 | impl.md の技術的判断が `rollback_target` と step 単位の `timeout-minutes` を反映していない | メインが impl.md を直した | 対応済み |
| 3 | web の経路で step の上限の合計が 45 分になり、ジョブの 40 分を超えうる | まれと見て詰めず、既知の制約に書いた。#1 で Roll back の step の時間切れは拾える | 対応済み(既知の制約) |

- lint 化の候補: なし(当たる規約スキルが無い。差分は GitHub Actions の YAML・bash・Markdown)

### コードレビュー第 3 回(2026-11-23、kn-code-reviewer、2 件: すべて実装判断。中 1 / 低 1)

AC-6・AC-7・AC-8 の退行は無し。仕様の疑問は無し。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | 結果が空のとき、issue は作るが、error の注記と実行の概要に「戻せなかった」と対象の Worker が出ない(`trap` まで届かなかった場合) | `report-rollback` の step で、結果が空のときに `::error::` と `GITHUB_STEP_SUMMARY` に状況と Worker を出す | 対応済み(戻り 3 回目) |
| 2 | deploy.md の、ジョブの時間切れ・Cancel のときに「自動では戻さず issue も作られない」の言い切りが実際と合わないことがある | ロールバックの途中で止まった場合は、戻っていることも issue が作られることもある、ダッシュボードで先頭の版を確かめる、の書き方にする。impl.md の既知の制約もメインが合わせる | 対応済み(戻り 3 回目) |

- lint 化の候補: なし(当たる規約スキルが無い。差分は GitHub Actions の YAML・bash・Markdown)

### コードレビュー第 4 回(2026-11-23、kn-code-reviewer、2 件: すべて実装判断。低 2)

マージを止めるべき指摘(確度「中」以上)は無し。AC-6・AC-7・AC-8 の退行は無し。仕様の疑問は無し。実装の戻しは上限の 3 回を使い切ったので、#2 は直さずに見送る。

| # | 指摘 | 対応 | 状態 |
|---|---|---|---|
| 1 | impl.md の技術的判断に、結果が空のときに `report-rollback` が注記と実行の概要を出すことが書かれていない | メインが impl.md に足した | 対応済み |
| 2 | deploy.md の時間切れ・Cancel の箇条で、Cancel では失敗のメールが届かないことがあり、issue が作られうるのは時間切れのときだけ | 「〜こともある」の書き方で誤りではなく、最後の「ダッシュボードで先頭の版を確かめる」で人間の行動は正しく導ける。戻しの上限を使い切ったので見送る。ユーザーが直したい場合は、理解度チェックの後の改善提案として扱う | 見送り |

- lint 化の候補: なし(当たる規約スキルが無い。差分は GitHub Actions の YAML・bash・Markdown)

---

## 理解度チェック(2026-11-24)

質問は HTML のページで出した(ユーザーの依頼)。2 回のやり取りで、5 問とも説明できるようになった。

| # | 質問 | 観点 | 回答の要点 | 解説した点 |
|---|---|---|---|---|
| 1 | web の確認が失敗したとき、web だけを戻し api を戻さないのはなぜか。本番の api と web はどの版か | なぜこの設計か | デプロイの途中も api と web の版はずれており、確認が通った api を戻す理由が無い。api は新しい版、web は前の版。1 回で完了 | api を先にデプロイするので、途中はいつも「新しい api と古い web」になる。web だけを戻した状態はこれと同じ(D1) |
| 2 | api を戻そうとしたら、バインディングの変更で Cloudflare に止められた。ワークフローは何をし、何が届き、何をすればよいか | 異常系 | issue が作られ、メールが届く。issue から案内される手でのロールバックの手順で戻す。1 回で完了 | 結果は `failed`(強制しない。D4)。api は確認が通らなかった新しい版のまま。同じ issue が開いていればコメントになる(D8)。手で戻す前に、CD を Disable にして run を Cancel する。止められた理由によってはダッシュボードからも戻せないかもしれない(未確認。deploy.md に記述なし) |
| 3 | 「Record web's current deployment」が失敗したとき、web のデプロイ・ロールバック・issue はどうなるか。issue を作らないのはなぜか | 異常系 | 1 回目: web はデプロイされず、戻さず、issue も作らない(理由が「デプロイに失敗したわけではない」で仕組みとずれていた)。再質問(`rolled_back` でも issue を作らないこととあわせて、基準は何か): 戻せなかったとき・戻した後の確認が通らないときに作る | issue は、ロールバックの対象があり、結果が `rolled_back`・`not_needed` 以外(空を含む)のときだけ作る。つまり本番が健全に戻ったと確かめられないとき。Q3 の場合は対象が空(web は変わっておらず、api は確認を通った)ので、知らせは失敗のメールとログだけ(D5・D9・D11) |
| 4 | 「本当に戻った」ことを何で判断しているか。`create` が何もせず終了コード 0 で終わるとどうなるか。どこを見れば分かるか | どこを見れば挙動が分かるか | 1 回目: 戻し先と今の版を比べる。何もしなければ失敗になる(条件が一部足りず、場所が推測だった)。再質問: 一覧を読み直して、デプロイが増えていることと、versions が戻し先と同じことを確かめる。`scripts/cd/rollback.sh` に書かれている。Roll back の step は失敗にならないので、report-rollback を見る | 判定は `rollback.sh` の手順 4(読み直した先頭の ID が戻す前の先頭と違い、versions が戻し先と同じ。D3)。何もしなければ先頭の ID が変わらないので `failed` になり、issue が作られる(D5)。実行ログでは Roll back の step に「読み直した先頭」「判定」の行と `::error::` の注記が出て、実行の概要にも結果が出る |
| 5 | main から `simulate_check_failure=web` で実行した後、本番の web は main と比べてどうか。揃えるには。main 以外のブランチから指定したら | 変更の影響 | 1 回目: web は main より 1 つ前の版。入力なしで main から実行すれば揃う(main 以外では「失敗する」と答え、誤り)。再質問: check が成功し、deploy 以降は動かない。ワークフローは成功する | 戻る先はこの実行より前の版。マージ時の push の実行で同じ main がデプロイ済みなら、コードは同じで版だけが前のもの。main 以外では `deploy` ジョブが動かないので、入力は効かない(D6・D15) |

- 改善提案の候補として 2 点を示した: deploy.md の時間切れ・Cancel の箇条で「知らせは失敗のメールだけ」としている点(コードレビュー第 4 回の #2)と、Cloudflare に止められてダッシュボードからも戻せないときの対応が書かれていない点
- ユーザーの判断: このまま進む(2 点とも直さない)
