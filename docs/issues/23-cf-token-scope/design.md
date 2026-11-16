# #23 Cloudflare API トークンの権限を最小化する — design.md

- issue: https://github.com/ayatsuki-meowmeow/kin-niku-log/issues/23
- 状態: 2026-11-16 にメインが調査結果と論点(U1〜U7)を起案。同日、ユーザーが U1〜U4・U6・U7 を決定し D1〜D6 に転記済み。U5 はユーザーの質問(A と B の違い)を受けて比較を補足した後、U8 とあわせて同日に決定し D7・D8 に転記済み。U8 の回答から出た U9(Claude からのリマインドの仕組み)も同日に決定し D9 に転記済み。impl.md のレビューで出た 2 点(issue の形式、カレンダーの予定日)を同日に決定し D10・D11 に転記済み。D11 は第 2 回レビューを受けて同日に変更し、初回の発行で失効のタイミングが分かった後、同日にもう一度変更(変更履歴)。未決事項なし
- 調査結果は 2026-11-16 時点の記録。仕様の決定はユーザーが行う
- ルート: 運用ルート(アプリのコード・振る舞いに触れない。トークンの発行・登録は人間が行う)

---

## 目的・背景

- Cloudflare への操作に使う認証情報の権限を、必要最小限に絞る
- #24(GitHub Actions からの CD)で `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` を使う予定のため、その前にトークンの権限設計を決める
- 現状、ローカルからの `cf deploy` は `cf auth login`(ブラウザでの OAuth ログイン)で得た認証情報を使っており、権限の範囲を確認していなかった(→ 調査結果 1 で確認した)
- #20(初回デプロイ)の作業中に挙がった申し送り。経緯は `docs/issues/20-initial-deploy/design.md`

### 完了条件(issue より)

- CD で使う API トークンが、決めた最小権限で発行され、決めた場所に登録されている
- ローカルの認証情報の扱い(現状維持 / 切り替え)が決まり、記録されている

### 前提

| 項目 | 内容 | 出典 |
|---|---|---|
| デプロイ対象 | Worker `kin-niku-log`(web、静的アセットのみ)と `kin-niku-log-api`(api)。どちらも #20 で作成済み | #20 D7 |
| URL | 独自ドメインは持たず `*.workers.dev` を使う。ルート・カスタムドメインは無い(= ゾーンの権限は不要) | #20 D4・ユーザーの方針(独自ドメインの取得予定なし) |
| バインディング | どちらの Worker も KV / R2 / D1 などのバインディングを持たない。シークレットも未登録 | `apps/*/cloudflare.config.ts`、#20 D6 |
| プラン | Workers Free | #20 D3 |
| リポジトリ | public | `gh repo view` |
| デプロイの承認 | main へのマージで自動デプロイ。人間の承認(GitHub Environments の Required reviewers)を挟むのは本番マイグレーションだけ | `docs/project-overview.md`「CI/CD」 |

### 範囲外

- CD のワークフロー(`.github/workflows/`)の作成は #24
- 本番シークレット `DATABASE_URL` の登録方法は、DB をつなぐ issue(#20 の申し送り)
- トークンの値は issue・docs・ログに書かない。アカウント ID も docs に書かない

---

## 調査結果(2026-11-16 確認)

確認できなかったことは「未確認」、推測で補ったことは「推定」と書いている。

### 1. ローカルの `cf auth login` の権限範囲(実機で確認)

- `cf auth scopes` の結果: **ほぼ全プロダクトのスコープ(472 中 471)が付与されている**。Workers だけでなく、DNS・ゾーン設定、Zero Trust、アカウント設定の書き込み(`account-settings write`)、メンバーシップの書き込み(`memberships write`)、R2・D1・KV などを含む
- 例外: `cf` は請求系(`billing:read` / `billing:write` など)をログイン時の要求スコープから除いている(`cf` 1.0.0-beta.26 のソースで確認)
- `cf auth login` / `cf auth create <name>` には `--scopes` オプションがあり、要求するスコープを指定できる。プロファイル(`cf auth create` / `cf auth activate`)をディレクトリごとに切り替えることもできる
- **OAuth のスコープはプロダクト単位**(例: `workers-scripts.write` は全 Worker が対象)で、特定の Worker だけに絞ることはできない。公式: 「`wrangler login` の OAuth フローは granular authorization にまだ対応していない。granular permissions を使うには account-owned API トークンで認証する」(`cf` の OAuth も同じ扱いと推定)
- `CLOUDFLARE_API_TOKEN` が環境変数にあると、保存済みのログインより優先される
- `cf` は、カレントディレクトリの dotenv 系ファイル(拡張子なしの 1 つだけ。ローカル用・モード別のものは読まない)からも `CLOUDFLARE_API_TOKEN` などを読む

**含意:** このマシンで動く AI エージェントが `cf` を実行すると、デプロイ以外(DNS、Zero Trust、アカウント設定、Worker の削除など)もユーザー本人と同じ範囲でできる。`docs/project-overview.md` には「本番デプロイコマンド(`cf deploy` など)は hook でブロックする」方針があるが、それ以外の `cf` コマンドは対象外。

出典:
- `cf auth scopes` / `cf auth --help` の出力(ローカル、`cf` 1.0.0-beta.26)
- https://developers.cloudflare.com/workers/authorization/ (Use granular permissions with Wrangler)
- https://developers.cloudflare.com/cf/ci/ (Provide credentials)

### 2. API トークンの種類

| 種類 | 形式 | 特徴 |
|---|---|---|
| User API トークン | `cfut_...` | ユーザーに紐づき、そのユーザーの権限の部分集合で動く。「スクリプトなど、ユーザーとして動くのが望ましい一時的な作業向け」 |
| Account API トークン(account-owned) | `cfat_...` | アカウントが持つサービスプリンシパル。作ったユーザーがいなくなっても動き続ける。**「CI/CD のような用途に最適」**。Workers は対応済み(互換表で ✅) |

- 公式: 「granular permissions(特定の Worker に絞った権限)を Wrangler で使うには account-owned API トークンで認証する」
- Account API トークンを作れるのは Super Administrator か API Token Provisioning 権限を持つメンバー。付けられる権限は、作るメンバー自身の権限の部分集合
- どちらの形式も、GitHub の Secret Scanning の対象。**public リポジトリで漏洩が検知されると、Cloudflare が自動で失効させてメールで通知する**

出典:
- https://developers.cloudflare.com/fundamentals/api/get-started/account-owned-tokens/
- https://developers.cloudflare.com/fundamentals/api/get-started/create-token/
- https://developers.cloudflare.com/fundamentals/api/get-started/token-formats/

### 3. Workers の権限(ロールとスコープ)

Workers の権限は「ロール × スコープ」の形になっている(旧来の `Workers Scripts Edit` などは引き続き使えるが、置き換え対象。廃止日は未定)。

| ロール | できること |
|---|---|
| Metadata Read-Only | Worker の一覧・設定・メトリクス・ログを見る。コードとシークレットは見られない |
| Content Read-Only | 上に加えてコードを見る |
| Editor | 既存 Worker の更新・デプロイ・名前変更・バージョン・ロールバック・シークレット管理。**Worker の作成・削除はできない** |
| Admin | 作成・削除を含む全操作(プロダクト単位で付けた場合) |

| スコープ | 対象 |
|---|---|
| Workers プロダクト | アカウントの全 Worker(今後作るものも含む) |
| 個別の Worker | 選んだ Worker だけ。**まだ存在しない Worker には付けられない** |

公式の「よくある組み合わせ」:
- 「CI/CD からの自動デプロイ」→ API トークン + Workers プロダクト + Editor
- 「特定の 1 つの Worker への自動デプロイ」→ API トークン + 個別の Worker + Editor

その他:
- 既存 Worker のデプロイ(`wrangler deploy` / `versions upload` / `versions deploy` / `rollback` / `secret put`)は、その Worker の **Editor** で足りる(公式の表は wrangler のコマンドで書かれている。`cf deploy` も同じ API を使うと推定)
- ルート・カスタムドメインを変えるデプロイには、加えてゾーンの `Workers Routes Write` が要る(本プロジェクトは workers.dev のみなので不要)
- バインディング(KV・R2・D1)を持つ Worker のデプロイも Editor で足りる。バインド先のリソースへの権限は不要
- 新しい Worker の作成には **Workers プロダクトの Admin** が要る
- 旧テンプレート「Edit Cloudflare Workers」は、Workers Scripts / KV / R2 の書き込み、Tail 読み取り、Account Settings 読み取り、ゾーンの Workers Routes 書き込み、ユーザー詳細・メンバーシップの読み取りをまとめて付ける。本プロジェクトには広すぎる

**未確認(発行後に試すまで分からない):** `cf deploy` は、workers.dev の URL を得るためにアカウント単位の API(`/accounts/<id>/workers/subdomain`)を呼んでいる(`cf` 1.0.0-beta.26 のソースで確認)。**個別の Worker の Editor だけで、この呼び出しが通るかは未確認**。通らない場合は、Workers プロダクトの Metadata Read-Only(読み取りのみ)を足すなどの調整が要る見込み(推定)。トークンの権限は発行後もダッシュボードで編集できる

出典:
- https://developers.cloudflare.com/workers/authorization/
- https://developers.cloudflare.com/workers/authorization/workers/
- https://developers.cloudflare.com/fundamentals/api/reference/template/
- `apps/api/node_modules/cf/dist/containers-*.mjs`(`getWorkersDevSubdomain`)

### 4. トークンの追加制約

| 制約 | 内容 | 本プロジェクトでの使いやすさ |
|---|---|---|
| 有効期限(TTL) | 開始日・終了日を設定できる(既定は無期限)。日付は UTC 0 時単位(調査時の理解。初回の発行で、終了日の日本時間 23:59:59 に失効すると確認した。impl.md「期限日の書き方と意味」) | 使える。期限切れで CD が止まるので、更新の段取りが要る。期限切れ前に Cloudflare から通知が来るかは**未確認** |
| クライアント IP 制限 | 使える IP 範囲を CIDR で指定できる | **CD には実用的でない**。GitHub ホストランナーの IP は広い範囲で変わる。ローカルも家庭回線だと IP が変わりうる |
| ロール(Roll) | 同じ権限のまま新しい値を発行し、古い値を即時失効させる | ローテーションに使える。ダッシュボードで「⋯ → Roll」。Roll 後の有効期限の扱い(延びるか、元の期限のままか)は公式ドキュメントに記載がなく**未確認** |

出典:
- https://developers.cloudflare.com/fundamentals/api/how-to/restrict-tokens/
- https://developers.cloudflare.com/fundamentals/api/how-to/roll-token/

### 5. GitHub 側の保管場所

| 置き場所 | 参照できるジョブ | 本リポジトリ(public・Free)で使えるか |
|---|---|---|
| Repository secrets | リポジトリの全ワークフロー(フォークからの PR には渡らない) | 使える |
| Environment secrets | その Environment を参照するジョブだけ。Environment の保護ルールを満たすまで渡らない | 使える(public なら Free でも可) |

Environment の保護ルール(public リポジトリなら Free でも使える):
- **Deployment branches and tags**: Environment を使えるブランチを制限できる(例: `main` だけ)。PR のワークフローからはシークレットに届かなくなる
- **Required reviewers**: 指定した人が承認するまでジョブを止める(最大 6 人)
- Wait timer: 指定時間待ってから実行

`cf` の CI ドキュメントの例は Repository secrets に `CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` を置き、デプロイの step だけに渡している。`CLOUDFLARE_ACCOUNT_ID` は `cloudflare.config.ts` の `accountId` に書く方法もある(public リポジトリなのでアカウント ID が公開される)。

出典:
- https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments
- https://developers.cloudflare.com/cf/ci/

---

## 未決事項

U1〜U9 はすべて 2026-11-16 に決定済み(「決定事項」に転記)。未決事項なし。

---

## 決定事項

すべて 2026-11-16 の決定。出典は「design.md への記入」(ユーザーが未決事項の「回答:」に書いた内容)。D9 は design.md への記入と、補足を示した後のチャットでの回答(AskUserQuestion)による。D10・D11 は impl.md のドキュメントレビューで出た論点への、チャットでの回答(AskUserQuestion)による。D11 の最新の変更は、初回の発行の後のコードレビュー(第 4 回)で出た疑問への、チャットでの回答(AskUserQuestion)による。

| ID | 決定日 | 内容 | 理由 |
|---|---|---|---|
| D1 | 2026-11-16 | CD 用トークンは **Account API トークン**(`cfat_`)にする(U1=A) | 推奨どおり。CI/CD 向けとして公式に推奨され、個別の Worker に絞る権限(D2)の前提になる |
| D2 | 2026-11-16 | 権限は **個別の Worker(`kin-niku-log` と `kin-niku-log-api`)の Editor だけ** を付ける。トークンは 1 本(U2=B) | 推奨どおり。漏れたときの影響が 2 つの Worker に限られ、Worker が増える予定も当面ない。影響: CD では Worker の作成・削除ができないので、作成は人間がローカルから行い、トークンの対象に足す。`cf deploy` がこの権限だけで通るかは未確認で、足りなければ読み取り系から最小限足す(D6) |
| D3 | 2026-11-16 | 有効期限は **90 日**、IP 制限なし(U3=B) | **推奨(1 年)とは異なる選択。** ユーザー補足: 「ちょっとインフルの業務体験みたいな感じで」(インフラ運用の業務を体験する意図と解釈)。IP 制限は、GitHub ホストランナーの IP が固定でないため付けない。影響: 約 3 か月ごとに入れ替えが必要になる(D5)。期限切れでは本番は止まらず、CD のデプロイが失敗するだけ |
| D4 | 2026-11-16 | ローカルは、#24 で CD が動いたら **ふだんはログアウトしておき、必要なときだけ人間がログインする**。#24 の完了までは今の OAuth ログイン(ほぼ全スコープ)のまま(U4=D) | 推奨どおり。ユーザー補足: 「要求頻度と手間を考慮して後から権限広げる方が良さそう」(最初は絞った状態から始め、必要になったら広げる)。影響: ログアウトは #24 の完了時に行う(後続への申し送り)。ログインが必要な場面の頻度・手間が問題になったら、スコープを絞ったログイン(U4 の B)などを改めて検討する |
| D5 | 2026-11-16 | トークンの入れ替えは **有効期限の前と、漏洩の疑いがあるとき** に行う。定期ローテーションは別に設けない。手順は **`docs/` に独立した運用文書** を置き、`docs/project-overview.md` からリンクする(U6=A+イ) | 推奨どおり。有効期限 90 日(D3)で入れ替えが定期的に起きるため、別の定期ローテーションは不要。issue の文書に埋もれさせず、次の入れ替えで探せるようにする。リマインドの置き方は U8 |
| D6 | 2026-11-16 | 最小権限のトークンで `cf deploy` が通るかは、**#24 の最初の CD 実行で確かめる**。足りなければ #24 の中で権限を足し、足した内容を #23 の design.md にも追記する(U7=B) | 推奨どおり。トークンの値を GitHub の外(ローカルのシェル)で扱わずに済む。権限は発行後も編集できるので、足すのは軽い |
| D7 | 2026-11-16 | GitHub の **Environment `production`** を作り、Environment secrets に `CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID` を置く。Deployment branches は `main` だけに制限する。Required reviewers は付けるかを #24 で決める。アカウント ID は `cloudflare.config.ts` に書かない(U5=A) | 推奨どおり。ユーザーの質問を受けて比較を補足した後に決定。決め手は、Repository secrets だと作業ブランチ(AI エージェントも push する)で書き換えたワークフローがマージ前にトークンを使えるのに対し、Environment を `main` に限れば、人間が必ず通る関門(PR のマージ)を通ったワークフローだけがトークンを使えること。ジョブに `environment: production` を書き忘れても、トークンが渡らずデプロイが失敗する(安全側)。public リポジトリなので追加費用なし |
| D8 | 2026-11-16 | 期限切れ前のリマインドは、**カレンダーへの予定登録と、運用文書(D5)への有効期限の記載の両方** で行う(U8=C) | 推奨どおり。ユーザー補足: 「できれば期限切れの 2 週間前に Claude からユーザーへのリマインドが発火する仕組みが欲しい」→ 実現方法と範囲は U9(D9) |
| D9 | 2026-11-16 | 期限の 14 日前からのリマインドを、**2 つの仕組みで #23 の中で入れる**(U9=A+C)。共通の前提として、運用文書(D5)に期限日を機械で読める 1 行(例: `- 有効期限: 2027-02-14`)で書き、入れ替えのたびに更新する。(A)このリポジトリの Claude Code の **SessionStart hook**: セッション開始時に期限日を読み、残り 14 日以内(期限切れ後も含む)なら Claude の文脈にリマインドを差し込み、Claude がユーザーに伝える。(C)**GitHub Actions の定期実行ワークフロー**: 1 日 1 回期限日を見て、残り 14 日以内なら issue を起こす | ユーザーは A 寄りで、GitHub Actions の無料枠に懸念が少なければ C も良いとした。補足(public リポジトリでは標準ランナーが無料。60 日間リポジトリに動きが無いと定期実行が自動で無効になる。混雑時は遅延・取りこぼしがある)を踏まえ、推奨(A だけ)ではなく A + C を選んだ。影響: A ではプロジェクトの `.claude/settings.json` を新しく作る。C ではワークフローに issue を起こす権限が要る。開発を止めている期間はどちらも働かないので、カレンダー(D8)が最後の歯止めになる |
| D10 | 2026-11-16 | D9 の (C) が起こす issue は、タイトルを **`[運用] Cloudflare API トークンの入れ替え期限`**、ラベルを **`human` と新設の `ops`** にする。`docs/project-overview.md` の「タスク管理の運用」に、定期の運用 issue はタイトルを `[運用] 〜` にし、`ops` ラベルを付ける例外を書き足す | レビューで、規約(タイトル `[PN] 〜`、ラベル `phase-N`)と合わないと指摘された。この issue は Phase に関係なく約 90 日ごとに起きるので、Phase 番号を固定で入れると Phase が進むたびにワークフローを直すことになる。推奨(`[運用]` + `human`)に加え、運用作業を見分けられるよう `ops` ラベルを新設する方をユーザーが選んだ |
| D11 | 2026-11-16 | カレンダーの予定(D8)は、**期限の 14 日前から終了日までの期間の予定 1 件** を入れる(初回は 2027-01-31〜2027-02-14) | ユーザー補足: 「どこかで対応すればOKなので」(期間の中のどこかで入れ替えればよい)。カレンダーは開発を止めている期間の最後の歯止め(D9)。当初は 14 日前と予備の 2 件(予備は期限当日 → 前日)としていた。初回の発行で、トークンは終了日の日本時間 23:59:59 まで使えると確認され(調査結果 4)、予備を前日にずらした理由(当日の朝に失効するという推定)が無くなった。そのうえで、ユーザーは期間の予定 1 件で登録した(変更履歴を参照) |

### 変更履歴

| 日付 | 決定 | 旧内容 | 変更の理由 |
|---|---|---|---|
| 2026-11-16 | D11 | 予備の予定は「期限当日」 | 失効が終了日の UTC 0 時(日本時間 9:00)と推定され、当日の予定では失効後の通知になりうる。ユーザーがチャット(AskUserQuestion)で前日にずらすことを選んだ |
| 2026-11-16 | D11 | 期限の 14 日前と、終了日の前日の 2 件 | 初回の発行で、失効は終了日の日本時間 23:59:59 と確認され、前日にずらした理由(推定)が無くなった。ユーザーは期間(14 日前〜終了日)の予定 1 件で登録しており、チャット(AskUserQuestion)で「どこかで対応すればOKなので」と答えた |

---

## 後続 issue への申し送り

| 送り先 | 内容 | 出典 |
|---|---|---|
| #24(CD) | デプロイのジョブに `environment: production` を書き、Environment secrets を参照する。Required reviewers を付けるかは #24 で決める | D7 |
| #24(CD) | 最初の CD 実行で、最小権限のトークン(個別の Worker の Editor だけ)で `cf deploy` が通るか確かめる。足りなければ権限を足し、#23 の design.md に追記する | D2, D6 |
| #24(CD) | CD が動いたら、ローカルの `cf` をログアウトする(運用文書にもその旨を書く) | D4 |
| 新しい Worker を作る issue | CD のトークンでは Worker を作れない。作成は人間がローカルから行い、トークンの対象に新しい Worker を足す | D2 |
