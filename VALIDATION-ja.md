# PHP 8.1.34 / Amazon Linux 2 検証記録

2026-10-22、ローカルのAmazon Linux 2 / x86_64 Docker環境でビルドと実行試験を完了しました
2026-10-23、利用者提供の[本番適用報告書](reports/PRODUCTION-20261023-ja.md)を追加しました。以下のローカル試験とは実施主体・確認範囲を分けて記録します
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

## 本番EC2への適用報告（2026-10-23追記）

根拠は、利用者から提供された実行ログに基づく[本番適用報告書](reports/PRODUCTION-20261023-ja.md)です。今回の文書更新作業でEC2へ再接続・再適用したものではありません

| 項目 | 報告書で確認できる内容 |
|---|---|
| 環境 | Amazon Linux 2 / x86_64、AWS版 `8.1.34-1.amzn2`、対象8RPM、Apache・PHP-FPMともにactive |
| 配布物の検証 | Releaseのアーカイブと内部`SHA256SUMS`の確認が成功 |
| 元の事前チェック | 全展開時の `cpio: ./usr/bin/phar: Cannot open` で停止。RPM本適用前 |
| 初回修正版 | 抽出パターンが合わず `Incomplete staged PHP payload` で停止 |
| 最終修正版 | `*usr/bin/php`・`*usr/sbin/php-fpm`・`*usr/lib64/php/modules/*` を抽出する1行変更の別ファイルで `PRECHECK OK` |
| 適用 | 同じ修正版の `apply` が `UPDATE COMPLETE`。8RPMすべてが `8.1.34-1.amzn2.cve20261021.1.x86_64` |
| サービス・設定 | PHP-FPM・httpdともにactive、FPM設定テスト成功、今回の起動時エラーなし |
| バックアップ | `/var/backups/php81-cve-20261022T150505Z.QOMw0CWd/` 作成をログで確認 |

適用は2026-10-23 00:05頃JSTです。journalのFPM停止00:05:05→起動00:05:08は約3秒ですが、外部からのHTTP停止時間を測定した値ではありません
元のアーカイブと同梱スクリプトは改変せず、バンドル外の `~/php81-install-stage-fix.sh` を使用しています。展開エラーの完全な原因特定は報告書では行われていません

本番で未確認なのは、実サイトのHTTP/HTTPS・ログイン・フォーム・アップロード、FPMプール固有の動作、長時間稼働や実トラフィックのエラー率、本番切り戻しです。アプリ・DBバックアップとEBSスナップショットの有無もログでは確認されていません
ローカルコンテナで成功した100要求・セッション・DB試験や切り戻しを、本番で実施済みとは扱いません

旧Releaseには元の展開処理が残ります。[READMEの手順3](README.md#3-既存環境との適合を確認する)に、同じ1行変更を持つコピーを元バンドルの外へ作る方法を追記しました。同梱スクリプトの恒久修正・再検証・修正版Releaseの配布は別途必要です
外部の修正版は自動バックアップには入りません。`rollback`は一時展開前に分岐するためバックアップ内の元スクリプトも利用できますが、本番で実行済みという報告はありません

### 追記した回避手順のローカル確認

2026-10-23 JST、保存済みのAL2ビルド環境イメージを使い、ネットワーク・サービス操作なしの隔離コンテナでREADMEのコピー作成コマンドを実行しました

- AL2のBash 4.2で生成でき、元スクリプトとの違いが報告書と同じ展開行1行だけであることを確認
- 元バンドルのスクリプトを変更せず、既存の修正版コピーを上書きしないことを確認
- 生成したコピーの実際の展開処理を新8RPMに適用し、CLI・FPMと拡張27ファイルの計29ファイルが不足・余分なく展開されることを確認
- `phar`を展開せず、候補CLI・FPMの`-n -v`が起動し、共有拡張12個を起動警告なく読み込めることを確認

記録は [validation/staging-workaround-validation.json](validation/staging-workaround-validation.json) です。報告書・元/生成後スクリプト・READMEのコマンドのSHA-256も記録しています
この試験は回避手順と一時展開の確認で、新しい本番適用・RPMトランザクション・systemd動作試験を行ったものではありません

## 配布物と確認範囲

新RPMは未署名のローカル再ビルドで、AWSが配布・署名した修正版RPMではありません
PHP本体への修正は [PHP公式コミット](https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a)（CVE-2026-109618 / CVE-2026-109619）です
配布アーカイブは、新8RPM・切り戻し用AWS8RPM・新旧ソースRPM・パッチ・spec・全ビルドログ・実行試験ログ・導入スクリプトを含みます
アーカイブ全体のSHA-256は添付の `.tar.gz.sha256`、内部の全ファイルは `SHA256SUMS` で確認できます

2026-10-22のローカル作業では、本番への接続・変更やコンテナでのsystemd依存の全体手順は実施していません
2026-10-23の本番報告で確認されたのは、別ファイル修正版による`check`・`apply`とパッケージ・サービス・基本設定です。本番アプリや実トラフィックの試験、本番切り戻しは未確認です
本番導入時は [README-ja.md](README-ja.md) の導入前checkと適用後のサイト確認を行ってください

## 証拠ファイル

| ファイル | 内容 |
|---|---|
| `validation/build-validation.json` | PHPT件数、既存XFAIL8件の一覧、ビルド証拠のSHA-256 |
| `validation/source-rpm-validation.json` | ソースRPMのspec照合と配布8RPMの依存確認 |
| `validation/runtime-validation.json` | 実行試験4段階、16RPMと試験スクリプトのSHA-256 |
| `validation/initial-attempt-oracles.json` | 元のAWS版と再ビルド版のタイムゾーン・OpenSSL出力比較 |
| `reports/PRODUCTION-20261023-ja.md` | 利用者提供の本番適用報告書の原文 |
| `validation/staging-workaround-validation.json` | READMEの外部コピー作成・AL2での実RPM展開・候補バイナリ起動の確認 |
| アーカイブ内 `logs/rpmbuild.log` | 最終の全件試験・RPMビルドログ |
| アーカイブ内 `logs/runtime/` | HTTP結果、RPM操作・FPM・Apacheの実行ログ |
| アーカイブ内 `logs/source-validation/` | 上記JSON検証記録の写し |
| アーカイブ内 `logs/initial-attempt/` | 調査前の全件失敗ログと比較結果 |
