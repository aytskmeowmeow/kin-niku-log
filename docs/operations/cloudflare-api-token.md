# Cloudflare API トークン(CD 用)の運用

GitHub Actions からのデプロイ(CD、#24)で使う Cloudflare API トークンの仕様と、発行・入れ替えの手順。
決定の経緯は [`docs/issues/23-cf-token-scope/design.md`](../issues/23-cf-token-scope/design.md) を参照。

**トークンの値とアカウント ID は、この文書・issue・ログに書かない。**

## 現在のトークン

- 有効期限: 2027-02-14

上の行は期限のリマインド(下の「リマインドの仕組み」)が読む。書き方の決まり:

- Cloudflare でトークンに設定した**終了日の値をそのまま** `YYYY-MM-DD` で書く(この日の日本時間 23:59:59 まで使える)。発行前は「未発行」と書く
- この形の行(行頭がハイフン・空白・「有効期限:」)は、この文書の中に 1 つだけにする。2 つ以上あると、リマインドは「期限日を読めない」として知らせる。例を書くときは行頭に置かない
- 更新は、ブランチ → PR → main へのマージで反映する。定期実行のワークフローは main のこの文書を読む

## トークンの仕様

| 項目 | 内容 | 出典 |
|---|---|---|
| 種類 | Account API トークン(`cfat_` で始まる) | D1 |
| 権限 | Worker `kin-niku-log` と `kin-niku-log-api` の **Editor** だけ(Workers プロダクト全体には付けない) | D2 |
| 有効期限 | 発行日から 90 日 | D3 |
| IP 制限 | なし(GitHub ホストランナーの IP は固定でないため) | D3 |
| 保管場所 | GitHub の Environment `production` の Environment secrets(`CLOUDFLARE_API_TOKEN` と `CLOUDFLARE_ACCOUNT_ID`)。Deployment branches は `main` だけ | D7 |

- **権限はまだ確定していない。** 2 つの Worker の Editor だけで `cf deploy` が通るかは未確認で、#24 の最初の CD 実行で確かめる(D6)。足りなかったら、読み取り系の権限から最小限足し、この表と #23 の design.md を更新する
- 失効のタイミングは、**終了日の日本時間 23:59:59**(確認済み)。初回の発行(終了日 2027-02-14)で、トークンの Summary の JSON の `expires_on` が `2027-02-14T14:59:59Z` だった。ダッシュボードで選んだ終了日を、ブラウザのタイムゾーン(日本時間)の終わりに直していると考えられる。リマインドも今日の日付を日本時間で数え、終了日の当日は「最終日」、翌日から「過ぎた」として知らせる

## 初回の発行

1. Cloudflare のダッシュボードで **Manage Account → Account API tokens → Create Token**
2. 権限: Workers の **Editor** を、スコープを個別の Worker にして `kin-niku-log` と `kin-niku-log-api` だけに付ける。ほかの権限は付けない
3. Token expiration: 終了日を発行日の 90 日後にする。Client IP Address Filtering は設定しない
4. 作成し、表示されたトークンの値をコピーする(値は一度しか表示されない)。トークンの Summary の JSON の `expires_on` が **`<終了日>T14:59:59Z`(終了日の日本時間 23:59:59)** かを確かめる。違っていたら(例: 日本時間以外のタイムゾーンのブラウザで発行した)、リマインドの判定(`scripts/cf-token-expiry.sh`)とこの文書を直す必要があるので、Claude に伝える
5. GitHub のリポジトリの **Settings → Environments → New environment** で `production` を作る
   - Deployment branches and tags: **Selected branches and tags** にし、`main` だけを足す
   - Required reviewers は、アプリのデプロイには付けない(#24 の D8。承認を挟むのは本番マイグレーションだけ)
6. `production` の **Environment secrets** に `CLOUDFLARE_API_TOKEN`(4 の値)と `CLOUDFLARE_ACCOUNT_ID` を登録する。アカウント ID は `cloudflare.config.ts` などリポジトリのファイルに書かない
7. カレンダーに、**終了日の 14 日前から終了日まで** の期間の予定を 1 件入れる(D11)。この期間のどこかで入れ替える
8. この文書の「有効期限」の行を終了日に更新し、main にマージする

## 入れ替え(期限前)

Roll は使わず、新しいトークンを発行してから古いトークンを削除する。Roll 後に有効期限がどうなるかは公式ドキュメントに記載がなく、Roll は古い値をすぐ失効させるので、シークレットを更新するまで CD が失敗するため。

1. 「初回の発行」の 1〜4 と同じ設定で、新しいトークンを発行する
2. Environment `production` の `CLOUDFLARE_API_TOKEN` を新しい値に更新する
3. CD を 1 回動かして、デプロイが通ることを確かめる。リポジトリの **Actions** でワークフロー「Deploy」を開き、**Run workflow** でブランチ `main` を選んで手動実行する([`deploy.md`](deploy.md))
4. 古いトークンをダッシュボードで削除する
5. この文書の「有効期限」の行を新しい終了日に更新し、main にマージする
6. カレンダーの期間の予定を、新しい終了日に合わせて入れ直す(14 日前から終了日まで)
7. リマインドの issue(`[運用] Cloudflare API トークンの入れ替え期限`)があれば閉じる。**5 のマージの後に閉じる**(先に閉じると、翌日のワークフローがまた作る)
8. リポジトリの **Actions** で、ワークフロー「Cloudflare API token expiry reminder」が有効かを確かめる。無効なら有効に戻す

## 漏洩の疑いがあるとき

1. 先に、漏れた疑いのあるトークンをダッシュボードで削除する(新しいトークンを登録するまで CD は動かないが、漏れたトークンを生かしておくより優先する)
2. 「入れ替え」の 1〜3 と 5〜8 を行う

public リポジトリにトークンがコミットされた場合は、GitHub の Secret Scanning が検知し、Cloudflare が自動で失効させてメールで知らせる。その場合も上の手順で入れ替える。

## 新しい Worker を足すとき

CD のトークンは Worker を作れない(作成には Workers プロダクトの Admin が要る)。

1. 人間がローカルから Worker を作る(下の「ローカルの認証情報」)
2. ダッシュボードでトークンを編集し、新しい Worker の Editor を足す
3. この文書の「トークンの仕様」の権限を更新する

## ローカルの認証情報

- **ふだんは `cf auth logout` でログアウトしておく**(CD が動くので、ローカルの `cf` の OAuth ログイン(ほぼ全スコープ)は常には要らない)。Worker の作成、シークレットの登録、障害時の手動デプロイなど、必要なときだけ人間が `cf auth login` でログインし、終わったらログアウトする(D4)
- ログインの頻度や手間が問題になったら、スコープを絞ったログイン(`cf auth login --scopes ...`)を検討する

## リマインドの仕組み

期限の 14 日前から、次の 3 つで知らせる(D8・D9・D11)。

| 仕組み | 動くとき | 知らせ方 |
|---|---|---|
| Claude Code の SessionStart hook(`.claude/hooks/cf-token-expiry-reminder.sh`) | このリポジトリで Claude Code のセッションを開いたとき | Claude が最初の返答で伝える |
| GitHub Actions のワークフロー(`.github/workflows/cf-token-expiry-reminder.yml`) | 毎日 UTC 0:17(日本時間 9:17) | issue `[運用] Cloudflare API トークンの入れ替え期限`(ラベル `human`・`ops`)を起こす。開いているものがあれば重ねて作らない |
| カレンダー | 終了日の 14 日前から終了日までの期間 | カレンダーの予定と通知 |

- hook とワークフローは、どちらも `scripts/cf-token-expiry.sh` で判定する。期限日の行を読めないときも知らせる
- **開発を止めている間は、hook もワークフローも働かない。** public リポジトリでは、60 日間動きが無いと定期実行のワークフローが自動で無効になり、手で有効に戻すまで止まったままになる。開発を再開したら、Actions でワークフローが有効かを確かめる
- main の更新より前に切ったブランチでは、main を取り込むまで、古い期限日で hook のリマインドが続く
