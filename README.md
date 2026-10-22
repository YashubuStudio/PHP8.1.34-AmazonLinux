# PHP 8.1.34 / Amazon Linux 2 セキュリティ再ビルド

AWS の `php-8.1.34-1.amzn2.src.rpm` に [PHP 公式修正](https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a)を適用し、Amazon Linux 2 / x86_64 用 RPM を手元の Docker で作成します

PHP の表示バージョンは **8.1.34** のまま、RPM Release が **`1.amzn2.cve20261021.1`** に変わります
AWS が配布・署名した修正版バイナリではなく、未署名のローカル再ビルドです

完成したバイナリは [Releases](https://github.com/YashubuStudio/PHP8.1.34-AmazonLinux/releases) に公開します
ビルドと実行試験の結果は [検証記録](VALIDATION-ja.md)、導入前確認・適用・切り戻しは [詳しい手順](README-ja.md) を参照してください

対象パッケージは `php-cli`、`php-common`、`php-fpm`、`php-gd`、`php-mbstring`、`php-mysqlnd`、`php-pdo`、`php-xml` の8種類です

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
Apache と PHP-FPM を起動し、日本語処理・画像処理・XML・PDO・mysqli・MariaDB接続、セッション、アップロード、100件の並列リクエスト、限定的なメモリ上限エラーからの復帰を確認します
ホスト側へポートは公開しません

`output/runtime-validation-*/runtime-validation.json` には、実際に試験した16RPMのSHA-256と結果を記録します
systemd に依存する導入スクリプト全体の実行と、利用者の本番アプリは、このコンテナ試験の対象には含まれません

## リリースの公開手順

コンパイルと実行試験は手元で行います
GitHub Actions は、検証済みファイルの再照合と Release へのアップロード・公開にだけ使います

`scripts/prepare-release.py` で完成アーカイブ・検証記録・リリースノートを配送用データにまとめ、`scripts/publish-release.py --verify-only` で全ファイルと試験対象RPMの一致を確認します
配送用の `release-upload/*` ブランチを push すると公開処理が実行されます
配送データはそのブランチに保存し、リリースタグは `main` のソースコミットを指します

公開処理は元のRPMアーカイブを復元し、SHA-256・アーカイブ内全ファイル・実行試験で使ったRPMのハッシュを照合します
全添付ファイルのGitHub側ダイジェストも確認してから、ドラフトReleaseを公開します
既存の公開済みReleaseは上書きしません

PHP公式修正に伴う動作変更と11件のテスト調整は [TEST-CHANGES-ja.md](TEST-CHANGES-ja.md) に記録しています
