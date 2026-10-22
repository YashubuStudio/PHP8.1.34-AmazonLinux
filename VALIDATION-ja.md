# PHP 8.1.34 / Amazon Linux 2 検証記録

2026-10-22、ローカルのAmazon Linux 2 / x86_64 Docker環境でビルドと実行試験を完了しました
PHP表示バージョンは `8.1.34`、新RPM Releaseは `1.amzn2.cve20261021.1` です
対象は `php-cli`、`php-common`、`php-fpm`、`php-gd`、`php-mbstring`、`php-mysqlnd`、`php-pdo`、`php-xml` の8種類です

## ビルド・全件テスト

- 公式AL2ベース: `public.ecr.aws/amazonlinux/amazonlinux@sha256:ee98817857ba78c33457304c9b6d81579322e9a464847c6e54207f44ce46f70c`
- CPU上限2、メモリ上限4GiB、x86_64上でネイティブビルド
- AWSソースRPMと切り戻し用8RPMの固定SHA-256・AWS GPG署名を確認
- PHP公式パッチと2種類のテスト専用パッチの固定SHA-256、適用前後の逆適用dry-runを確認
- CGI・Apache・FPM・embedded・ZTS CLI・ZTSの全6構成のコンパイルを完了
- 初回試験で4件の古いテストデータの環境差を特定し、テスト専用パッチで調整
- コンパイル結果・入力ファイル・ビルド設定・ツールチェーンを照合して再利用し、通常の `rpmbuild -ba` でconfigure・make・install・全件テストを再実行
- `--nocheck`、`--short-circuit`、追加のSKIPIF・XFAIL、TLS検証の無効化は使用していません
- 全件PHPT最終結果: **総数17,682、合格10,302、スキップ7,372、既存の想定失敗8、失敗0、警告0**、1,162秒
- スキップは有効にしていない拡張や実行条件などに依存します。スキップ・既存の想定失敗は合格件数に含めていません
- 変更対象15件の重点PHPTも、合格15・スキップ0・警告0・失敗0
- 再ビルドしたソースRPM内のspecと同梱specの完全一致を確認。キャッシュの絶対パスを埋め込まず、通常の全工程と追加パッチを含みます
- 配布8RPMの依存に `rpmlib(ShortCircuited)` がないことを確認

初回全件結果は合格10,298・失敗4でした。タイムゾーン履歴件数、OpenSSL 1.0.2の関数番号、2026-04-02で期限切れになったSNIテスト用証明書が原因です
元のAWS版と再ビルド版の出力比較を行い、PHP本体を追加改変せず4件のPHPTを調整しました
理由・元ファイルのハッシュ・検証を維持した範囲は [TEST-CHANGES-ja.md](TEST-CHANGES-ja.md) に記録しています
初回の失敗ログもアーカイブ内 `logs/initial-attempt/` に保持しています

## 完成RPMによる実行試験

別の、同じ公式AL2ダイジェストのクリーンなコンテナで実施しました。ホスト側へのポート公開はありません
実際に旧AWS版8RPMを導入し、新8RPMへ更新、旧版へ切り戻し、新版を再適用する全4段階が成功しました
RPMのトランザクション試行と実適用を両方実行しています

- Apache→PHP-FPM→MariaDBの実HTTP要求で10機能を確認: mbstring、GD、DOM、SimpleXML、XMLReader、XMLWriter、PDO SQLite、PDO MySQL、mysqli、mysqlnd
- 日本語の文字コード往復、PNG生成・再読込、XML入出力、SQLite問い合わせ、MySQLのプリペアド問い合わせを確認
- 同じCookieによる通常セッションの保存・再読込を10要求で確認
- multipartで日本語ファイル内容・アップロードファイル属性を確認
- `session.upload_progress.enabled=1`、`cleanup=0` にしても組み込み進捗キーが作られず、通常アップロードと通常セッションは動作することを確認
- 8クライアントから100要求を送り、全件正常応答を確認
- メモリ上限8MiBで16MiBを割り当てる限定的な異常終了試験を実施
- CLIでは元版・切り戻し版が終了255＋shutdown callback実行、新版・再適用版が終了1＋callback不実行
- FPMでは新たなメモリ上限エラーをログで確認し、shutdown callback不実行と、その後10要求の正常応答を確認。この試験でのApache応答は503でした
- 更新・再適用後のPHP設定ファイルの内容とファイル集合、更新前後のモジュール一覧が一致
- 最終FPMマスタープロセスが再適用済み実行ファイルを使用することをinodeで確認
- 実際に使用した新旧16RPMと試験用4スクリプトのSHA-256を記録

## 配布物と確認範囲

新RPMは未署名のローカル再ビルドで、AWSが配布・署名した修正版RPMではありません
PHP本体への修正は [PHP公式コミット](https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a)（CVE-2026-109618 / CVE-2026-109619）です
配布アーカイブは、新8RPM・切り戻し用AWS8RPM・新旧ソースRPM・パッチ・spec・全ビルドログ・実行試験ログ・導入スクリプトを含みます
アーカイブ全体のSHA-256は添付の `.tar.gz.sha256`、内部の全ファイルは `SHA256SUMS` で確認できます

本番環境への接続・本番パッケージ変更・本番アプリや実トラフィックの試験は行っていません
systemdを起動していないコンテナのため、`install-rpms.sh` のsystemd依存の全体手順は実行していません。実際のRPM更新・切り戻し・再適用とFPMの起動停止は上記のとおり実施済みです
本番導入時は [README-ja.md](README-ja.md) の導入前checkと適用後のサイト確認を行ってください

## 証拠ファイル

| ファイル | 内容 |
|---|---|
| `validation/build-validation.json` | PHPT件数、既存XFAIL8件の一覧、ビルド証拠のSHA-256 |
| `validation/source-rpm-validation.json` | ソースRPMのspec照合と配布8RPMの依存確認 |
| `validation/runtime-validation.json` | 実行試験4段階、16RPMと試験スクリプトのSHA-256 |
| `validation/initial-attempt-oracles.json` | 元のAWS版と再ビルド版のタイムゾーン・OpenSSL出力比較 |
| アーカイブ内 `logs/rpmbuild.log` | 最終の全件試験・RPMビルドログ |
| アーカイブ内 `logs/runtime/` | HTTP結果、RPM操作・FPM・Apacheの実行ログ |
| アーカイブ内 `logs/source-validation/` | 上記JSON検証記録の写し |
| アーカイブ内 `logs/initial-attempt/` | 調査前の全件失敗ログと比較結果 |
