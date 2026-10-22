# PHP 8.1.34 / Amazon Linux 2 セキュリティ再ビルド

AWS の `php-8.1.34-1.amzn2.src.rpm` に [PHP 公式修正](https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a)を適用し、Amazon Linux 2 / x86_64 用 RPM を手元の Docker で作成します

PHP の表示バージョンは **8.1.34** のまま、RPM Release が **`1.amzn2.cve20261021.1`** に変わります
AWS が配布・署名した修正版バイナリではなく、未署名のローカル再ビルドです

完成バイナリ: [php81-8.1.34-cve20261021.1](https://github.com/YashubuStudio/PHP8.1.34-AmazonLinux/releases/tag/php81-8.1.34-cve20261021.1)
ビルドと実行試験の結果は [検証記録](VALIDATION-ja.md)、導入前確認・適用・切り戻しは [詳しい手順](README-ja.md) を参照してください

2026-10-22の全件PHPTは合格10,302・スキップ7,372・既存の想定失敗8・失敗0・警告0でした
完成RPMの更新・切り戻し・再適用と、Apache/FPM/DB・セッション・アップロード・8クライアント100要求・限定的な異常終了後の復帰も確認済みです

対象パッケージは `php-cli`、`php-common`、`php-fpm`、`php-gd`、`php-mbstring`、`php-mysqlnd`、`php-pdo`、`php-xml` の8種類です

## AWS EC2の既存PHP 8.1を更新する

公開済みのRPMを使い、EC2に入っているPHPを**既存パッケージの更新として導入**します
`install-rpms.sh apply` が8種類のRPMをまとめて `rpm -Uvh` で更新します。EC2側でのコンパイルやDockerの準備は不要です
このReleaseはダウンロードしたRPMから導入するため、通常の `yum update` だけでは適用されません

### 1. 更新対象を確認する

対象は次の構成です。以下のコマンドは、適用先EC2へSSH接続し、`ec2-user`などの一般ユーザーで実行します

| 項目 | 必要な状態 |
|---|---|
| OS・CPU | Amazon Linux **2** / `x86_64` |
| 現在のPHP | AWS版 `8.1.34-1.amzn2` |
| PHPパッケージ | 上記の8種類がすべて入り、追加の `php*` パッケージがないこと |
| Web実行方式 | Apache（`httpd`）→PHP-FPM（`php-fpm`）が起動中 |
| 権限 | `sudo`を実行できること |

```bash
cat /etc/os-release
uname -m
rpm -qa 'php*' --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort
systemctl is-active php-fpm httpd
```

OSは `ID=amzn` / `VERSION_ID="2"`、CPUは `x86_64`、8パッケージすべてが `8.1.34-1.amzn2.x86_64` であることを確認します
Amazon Linux 2023、Graviton（ARM64）、別のPHP版・配布元、追加のPHPパッケージ、nginxや別の実行方式は、この導入スクリプトの対象外です。構成が異なる場合は、その構成に合わせた対応が必要です

適用時にはPHP-FPMを短時間停止するため、作業時間を確保します。既存アプリ・DBのバックアップも用意してください
スクリプトが保存するバックアップはPHP設定・パッケージ情報・切り戻し用RPMで、アプリやDB本体は含みません

### 2. 完成RPMを取得・検証して展開する

以下は**EC2上**で実行します。公開ReleaseのためGitHubトークンは不要です
アーカイブと展開先は、ログインユーザーのホームディレクトリに作成します。同名ファイルや展開先がある場合は、その内容を確認できるように処理を止めます

```bash
(
  set -e
  cd "$HOME"
  php81_archive='php81-rpms-8.1.34-cve20261021.1.tar.gz'
  php81_bundle='php81-rpms-8.1.34-cve20261021.1'
  php81_release_url='https://github.com/YashubuStudio/PHP8.1.34-AmazonLinux/releases/download/php81-8.1.34-cve20261021.1'
  for php81_path in "$php81_archive" "$php81_archive.sha256" "$php81_bundle"; do
    if [ -e "$php81_path" ] || [ -L "$php81_path" ]; then
      printf '既存のファイル・展開先を確認してください: %s\n' "$php81_path" >&2
      exit 1
    fi
  done
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 1800 \
    --output "$php81_archive" "$php81_release_url/$php81_archive"
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 1800 \
    --output "$php81_archive.sha256" "$php81_release_url/$php81_archive.sha256"
  sha256sum --check --strict "$php81_archive.sha256"
  tar -xzf "$php81_archive"
  cd "$php81_bundle"
  sha256sum --check --strict SHA256SUMS
)
```

アーカイブと内部ファイルのチェックがすべて `OK` になったら次へ進みます

### 3. 既存環境との適合を確認する

```bash
sudo bash "$HOME/php81-rpms-8.1.34-cve20261021.1/install-rpms.sh" \
  check "$HOME/php81-rpms-8.1.34-cve20261021.1"
```

最後に **`PRECHECK OK`** が出ることを確認します。この段階ではPHPパッケージの交換やPHP-FPMの停止は行いません
現在の8パッケージ・版、AWS旧RPMの署名、依存関係、候補PHPの拡張一覧・メモリ上限エラー時の動作、PHP-FPM設定を確認します
不足ツールや構成差があれば停止するため、表示された原因を解消してから再度 `check` を行います。`cpio`不足などへの対応は[詳しい手順のエラー対応](README-ja.md#エラーで止まったとき)を参照してください

### 4. 既存PHPを更新する

`PRECHECK OK`を確認し、PHP-FPMを停止できる時間帯に実行します

```bash
sudo bash "$HOME/php81-rpms-8.1.34-cve20261021.1/install-rpms.sh" \
  apply "$HOME/php81-rpms-8.1.34-cve20261021.1"
```

スクリプトは再チェック後に `/var/backups/php81-cve-日時.XXXXXXXX/` へバックアップを保存し、PHP-FPM停止→8RPM更新→設定・拡張・起動確認を実行します
既存PHP設定を引き継ぎ、Apacheの再起動は行いません。完了時の **`UPDATE COMPLETE`** と、表示されたバックアップ先・切り戻しコマンドを確認してください

### 5. 更新結果とアプリの動作を確認する

```bash
rpm -q --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' \
  php-cli php-common php-fpm php-gd php-mbstring php-mysqlnd php-pdo php-xml
/usr/bin/php -v
sudo systemctl is-active php-fpm httpd
sudo journalctl -u php-fpm -n 50 --no-pager
```

8パッケージすべてが **`8.1.34-1.amzn2.cve20261021.1.x86_64`**、サービスがともに `active` であることを確認します
`php -v`の **8.1.34表示は更新後も変わりません**。修正の適用はRPMのReleaseで判断します
ブラウザで既存サイトの表示・ログイン維持・フォーム送信・少量のアップロードを確認し、複数サイトやFPMプールがある場合はそれぞれ確認します

公式修正により、組み込み `session.upload_progress` は無効になり、対象のメモリ上限エラーなどではshutdown callbackが実行されません。通常セッションと通常アップロードは動作確認済みです
`check`は本番アプリの互換性試験ではありません。[検証記録](VALIDATION-ja.md)と[互換性の説明](README-ja.md#修正の内容と互換性)も参照してください

### 6. 必要な場合は旧RPMへ戻す

```bash
sudo bash "$HOME/php81-rpms-8.1.34-cve20261021.1/install-rpms.sh" \
  rollback "$HOME/php81-rpms-8.1.34-cve20261021.1"
```

元のAWS版 `8.1.34-1.amzn2` に戻し、PHP-FPMを起動します。切り戻しでもPHP-FPMを一時停止し、今回のCVE修正も外れます
適用時に表示された `/var/backups/` 配下のコマンドも利用できます。切り戻し後は手順5のサービス・サイト確認を行い、RPMが元のReleaseに戻ったことを確認します
設定ファイルをバックアップから一律復元する処理は含まれません。動作確認が終わるまで、展開済みバンドルとバックアップを保管してください

## ビルド

必要な環境は x86_64 Linux とローカル Docker、目安として CPU 2コア分・メモリ4GiB・空き20GiBです

```bash
git clone https://github.com/YashubuStudio/PHP8.1.34-AmazonLinux.git
cd PHP8.1.34-AmazonLinux
sha256sum --check --strict KIT-SHA256SUMS
BUILD_JOBS=2 bash build-local.sh
```

一般ユーザーで実行します
完成物は `output/php81-rpms-8.1.34-cve20261021.1.tar.gz` と、その `.sha256` です
新旧RPM、ソースRPM、パッチ、ビルドログ、導入スクリプトを含みます

## ローカルでの実行試験

ビルドで生成された展開済みバンドルを指定します

```bash
bash validate-local.sh output/php81-build.XXXXXXXX/php81-rpms-8.1.34-cve20261021.1
```

別の Amazon Linux 2 コンテナで元の8RPMをインストールし、実際に更新・切り戻し・再適用します
Apache と PHP-FPM を起動し、日本語処理・画像処理・XML・PDO・mysqli・MariaDB接続、セッション、アップロード、同時8接続で100件のリクエスト、限定的なメモリ上限エラーからの復帰を確認します
ホスト側へポートは公開しません

`output/runtime-validation-*/runtime-validation.json` には、実際に試験した16RPMのSHA-256と結果を記録します
systemd に依存する導入スクリプト全体の実行と、利用者の本番アプリは、このコンテナ試験の対象には含まれません

検証記録を更新したら、ビルド時の元アーカイブを保存したまま、試験記録入りの配布物を作成できます
下記の `XXXXXXXX` と日時付きディレクトリは、実際のビルド・検証出力先に置き換えます

```bash
python3 scripts/finalize-bundle.py \
  --bundle output/php81-build.XXXXXXXX/php81-rpms-8.1.34-cve20261021.1 \
  --runtime-results output/runtime-validation-日時-XXXXXXXX \
  --build-run-logs output/local-build-日時-XXXXXXXX \
  --validation VALIDATION-ja.md \
  --output output/release
```

完成物は `output/release/php81-rpms-8.1.34-cve20261021.1.tar.gz` と、その `.sha256` です
試験したRPMと配布物の一致、元バンドル全ファイル、PHPテストの失敗0件、実行試験用スクリプトの一致も確認します

## リリースの公開手順

コンパイルと実行試験は手元で行います
GitHub Actions は、検証済みファイルの再照合と Release へのアップロード・公開にだけ使います

`scripts/prepare-release.py` で完成アーカイブ・検証記録・リリースノートを配送用データにまとめ、`scripts/publish-release.py --verify-only` で全ファイルと試験対象RPMの一致を確認します
配送用の `release-upload/*` ブランチを push すると公開処理が実行されます
配送データはそのブランチに保存し、リリースタグは `main` のソースコミットを指します

公開処理は元のRPMアーカイブを復元し、SHA-256・アーカイブ内全ファイル・実行試験で使ったRPMのハッシュを照合します
全添付ファイルのGitHub側ダイジェストも確認してから、ドラフトReleaseを公開します
既存の公開済みReleaseは上書きしません

PHP公式修正に伴う11件のテスト調整と、AL2環境に合わせた4件のテスト調整は [TEST-CHANGES-ja.md](TEST-CHANGES-ja.md) に記録しています
後者はタイムゾーン履歴件数・OpenSSLの版ごとのエラーコード・期限切れのテスト用証明書への対応です
PHP本体への修正は公式パッチで、テストのスキップやTLS検証の無効化は追加していません

同一環境でのコンパイル結果を検証して再利用する内部ツールとして `scripts/build-cache.py` と `PHP81_RESUME_WORK` も用意しています
通常の新規ビルドでは使用せず、既存の作業ディレクトリ・ツールチェーン・ビルド設定が一致する復旧時だけ使用します
復旧時も通常のRPMビルド工程と全件テストを実行します
