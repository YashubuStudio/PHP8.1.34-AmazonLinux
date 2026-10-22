# PHP 8.1.34 セキュリティ修正 本番適用報告書

**対象環境：** Amazon Linux 2 / x86_64（EC2: `ip-172-31-40-13`）  
**実施日時：** 2026年10月23日 00:05頃（JST）  
**対象：** PHP 8.1.34、公式修正に対応する独自再ビルドRPM  
**判定：** **RPM更新・PHP-FPM再起動・基本設定検証は成功。アプリケーションの実動作検証は未完了。**

## 1. 作業目的・背景

Amazon Linux 2で動作するAWS提供のPHP 8.1.34 RPM（`8.1.34-1.amzn2`）に対し、YashubuStudioの公開リポジトリで作成・検証されたセキュリティ修正版を適用する。対象として記載されているのは **CVE-2026-109618 / CVE-2026-109619**。元のPHPメジャー・マイナーバージョンおよび従来の8パッケージ構成を維持したまま、RPMのReleaseのみを変更する方式を採用した。

**配布元：** https://github.com/YashubuStudio/PHP8.1.34-AmazonLinux  
**対象Release：** https://github.com/YashubuStudio/PHP8.1.34-AmazonLinux/releases/tag/php81-8.1.34-cve20261021.1  
**修正パッチの参照先（リポジトリ記載）：** https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a

> 本報告書は提示されたEC2の実行ログと、確認済みリポジトリ内のREADME・検証記録・スクリプトに基づく。実環境で行っていない試験を実施済みとは扱わない。

## 2. 適用前の環境

| 項目 | 確認結果 |
|---|---|
| OS | Amazon Linux 2（`ID=amzn`, `VERSION_ID=2`） |
| アーキテクチャ | `x86_64` |
| PHP（導入前） | `8.1.34-1.amzn2.x86_64` |
| PHP RPM | `php-cli`, `php-common`, `php-fpm`, `php-gd`, `php-mbstring`, `php-mysqlnd`, `php-pdo`, `php-xml` の8件 |
| PHP-FPM | `active` |
| Apache（httpd） | `active` |
| OSのサポート期限表示 | `SUPPORT_END="2026-06-30"` |

上記は配布リポジトリが想定するOS、CPU、PHPの構成に一致した。

## 3. 作業経過と障害対応

| 段階 | 操作 | 実際の結果 | 判定 |
|---|---|---|---|
| 1 | GitHub Releaseから `tar.gz` と `.sha256` を取得 | アーカイブ取得、`sha256sum --check --strict` で `OK` | 成功 |
| 2 | アーカイブを展開し `SHA256SUMS` で内部を検証 | 新旧RPM、パッチ、スクリプト、ログ類を含む全表示項目が `OK` | 成功 |
| 3 | オリジナルの `install-rpms.sh check` | RPMの更新可否試験後、`cpio: ./usr/bin/phar: Cannot open: No such file or directory` 等で停止 | 失敗 |
| 4 | 一時展開対象をPHP CLI/FPM/拡張モジュールに限定する修正版（初回） | `ERROR: Incomplete staged PHP payload.` で停止 | 失敗 |
| 5 | 抽出パターンの前方に `*` を追加した修正版で再試験 | FPM設定テストに成功し `PRECHECK OK` を確認 | 成功 |
| 6 | 修正版スクリプトで `apply` | 8件のRPMを更新、FPMを再起動、`UPDATE COMPLETE` を確認 | 成功 |
| 7 | 更新後のRPM、CLI、サービス、FPM設定、journalを確認 | すべて予定の状態、直近のFPM起動失敗なし | 成功 |

### 3.1 障害と対応内容

**初回エラー**

```text
cpio: ./usr/bin/phar: Cannot open: No such file or directory
cpio: ./usr/bin/phar: Cannot utime: No such file or directory
ERROR: stopped at script line 125.
ERROR: stopped at script line 124.
```

候補RPMを作業用ディレクトリに一時展開する箇所で発生。原因の完全な特定まではログからはできないが、検証に不要なファイルも含めて全展開している処理が失敗箇所と特定された。RPMの本番適用はこの時点では始まっていない。

**初回の改修による別エラー**

```text
ERROR: Incomplete staged PHP payload.
```

`cpio` の抽出パターンがRPM内の相対パス表記と合致していなかった可能性があり、`./usr/...` 形式にも対応するパターンへ変更した。

**最終的に通過した展開行（修正版の抜粋）**

```bash
(cd "$PHP81_STAGE" && rpm2cpio "$PHP81_FILE" | cpio -idm --quiet --no-absolute-filenames "*usr/bin/php" "*usr/sbin/php-fpm" "*usr/lib64/php/modules/*")
```

変更は元スクリプトの該当する**1行**に限定。修正版の保存先は `~/php81-install-stage-fix.sh`。GitHub Releaseの元アーカイブとハッシュ検証対象のオリジナルスクリプトは変更していない。

## 4. 最終事前チェック結果

2026年10月23日 00:03:35 JSTの出力：

```text
[23-Oct-2026 00:03:35] NOTICE: configuration file /etc/php-fpm.conf test is successful
PRECHECK OK: eight RPMs, dependencies, CLI extensions, patched OOM behavior and FPM configuration.
This does not test application requests or per-pool runtime overrides.
```

事前チェックで確認された対象は、RPMセットと依存関係、候補PHP CLIと拡張一覧、修正後の制限メモリ異常終了挙動、PHP-FPM設定である。一方、アプリケーション要求やプール固有の実行時上書き設定に関しては、このチェックでは確認していない。

## 5. 本番RPM適用・バックアップ

使用コマンド：

```bash
sudo bash "$HOME/php81-install-stage-fix.sh" \
  apply "$HOME/php81-rpms-8.1.34-cve20261021.1"
```

適用は2026年10月23日 00:05頃（JST）。適用前の再チェック後、バックアップが作成され、PHP-FPMの停止、8個の更新RPM導入、旧RPM削除、設定検査とPHP-FPM再起動が実行された。

```text
Backup: /var/backups/php81-cve-20261022T150505Z.QOMw0CWd
UPDATE COMPLETE: PHP remains 8.1.34; RPM release is 1.amzn2.cve20261021.1.
PHP-FPM master PID: 31124. Configuration and the existing CVE ini file were retained.
```

バックアップディレクトリ名のUTC表記 `20261022T150505Z` はJSTの10月23日00:05:05に相当する。

`journalctl` によればPHP-FPMは**00:05:05に停止、00:05:08に起動**。この2つの記録の時刻差は約3秒。ただし、外部利用者から見た実際のHTTP停止時間を測定した値ではない。Apacheの停止・再起動を示す記録は提示されていない。

## 6. 更新後の検証結果

### 6.1 インストール済みRPM

以下の8件がすべて `8.1.34-1.amzn2.cve20261021.1.x86_64` に更新されている。

```text
php-cli
php-common
php-fpm
php-gd
php-mbstring
php-mysqlnd
php-pdo
php-xml
```

### 6.2 バイナリ・サービス・設定

| チェック | ログに示された結果 | 判定 |
|---|---|---|
| `php -v` | `PHP 8.1.34 (cli)` / `built: Oct 22 2026 09:41:16` | 期待どおり |
| `systemctl is-active php-fpm httpd` | `active` / `active` | 成功 |
| `sudo php-fpm -t` | `configuration file /etc/php-fpm.conf test is successful` | 成功 |
| `journalctl -u php-fpm -n 30` | 10月23日00:05:05停止→00:05:08起動。該当時刻の起動エラーなし | 成功 |
| 適用スクリプトの追加確認 | 拡張一覧の一致、FPMプロセスの実行バイナリ一致、`UPDATE COMPLETE` | 成功 |

更新後の8RPMのRelease名とサービス状態が一致しており、**OSのパッケージレベルでの更新は正常終了**と判断できる。

### 6.3 ビルド側で実施済みと記録された試験（本番EC2の試験とは区別）

リポジトリ内の `VALIDATION-ja.md` には、Amazon Linux 2コンテナ上でのPHPT全件試験が、**合格10,302、スキップ7,372、既存の想定失敗8、失敗0、警告0（総数17,682）**と記載されている。別のクリーンなコンテナで、新旧RPMの更新・切り戻し・再適用、Apache/PHP-FPM/MariaDB、セッション、アップロード、100要求の負荷試験等を実施した記録もある。

これらは**ローカル検証環境の実績**であり、今回の本番EC2で同じ試験を全件実施したものではない。

## 7. 修正の性質と運用上の注意

- PHP表示版は引き続き `8.1.34` であり、**修正版かどうかはRPMのRelease**で判定する。
- 新RPMは独自再ビルドの**未署名パッケージ**で、AWSが署名して提供した修正版バイナリではない。SHA-256一致は配布物の改変検出に使われたが、それだけで開発元の真正性全体を保証するものではない。
- リポジトリの説明では、公式修正によって組み込み `session.upload_progress` が無効となり、対象のメモリ制限エラーではshutdown callbackの動作が変わる。これらに依存するアプリケーションでは互換性確認が必要。
- オリジナルの `install-rpms.sh` の展開エラーは現行Releaseに残っているため、将来の再適用・新規導入に向けて**リポジトリ側の修正と再検証・再配布**が必要。
- 本番更新の際に利用した修正版 `~/php81-install-stage-fix.sh` は配布済みバンドルの外にある。バックアップ内のオリジナルスクリプトとは異なることに注意。
- リポジトリ記録上、コンテナではsystemd依存の導入スクリプト一式の試験は未実施だったが、今回の本番EC2では `apply` が正常終了した。ただしWebアプリ全体の検証とは別。
- `/etc/os-release` に `SUPPORT_END="2026-06-30"` とあり、**Amazon Linux 2のOSサポートは期限経過**。今回のPHP個別修正だけでOS全体の脆弱性対策が完了するわけではない。

## 8. 未完了・未確認事項

1. 各Webサイトの実際のHTTP/HTTPS応答、WordPress等の表示、ログイン・管理画面・記事保存・フォーム送信・ファイルアップロードの動作確認。
2. サイト固有のPHP-FPMプール設定・プール別動作、エラーログ、アプリケーション依存の互換性検証。
3. 本番トラフィックにおける性能・エラー率の比較と長時間稼働確認。
4. EBSスナップショットおよびアプリケーション・DBバックアップの有無（ログでは確認できない）。
5. ロールバックは今回**実行していない**。切り戻しコマンドは準備されているが、本番環境での切り戻し成功を示すログはない。
6. 今回の修正版スクリプトを製品リポジトリに反映する作業と、修正版Releaseの作成。

## 9. 推奨する最終確認コマンド

```bash
rpm -qa 'php*' --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort
php -v
systemctl is-active php-fpm httpd
sudo php-fpm -t
sudo journalctl -u php-fpm --since '2026-10-23 00:05:00' --no-pager
```

CLI上の確認に加え、**実際のサイトに対して**ブラウザで通常動線をテストすること。確認できた事実をサイト名・URL・結果・確認日時とともに追記すると報告書を完結できる。

## 10. 切り戻し手段

適用時に表示されたバックアップ内の配布物を使って戻せる。

```bash
sudo bash /var/backups/php81-cve-20261022T150505Z.QOMw0CWd/bundle/install-rpms.sh \
  rollback /var/backups/php81-cve-20261022T150505Z.QOMw0CWd/bundle
```

切り戻すと元の `8.1.34-1.amzn2` に戻り、今回のセキュリティ修正も外れる。切り戻し前後はPHP-FPMが一時停止する。バックアップ、展開済みバンドル、修正版の検証スクリプトは、実動作確認が済むまで保管する。

## 11. 総合判定

**結果：パッケージ適用成功／サービス起動正常／基本設定正常／本番アプリケーション動作確認待ち。**

初回と初回修正版の `check` は一時展開処理で停止したが、展開処理だけを修正することで `PRECHECK OK` を確認。その後の本番RPM更新では、予定の8パッケージがすべて目標Releaseに更新され、PHP-FPMの起動と設定テストにも成功した。提示されたサービスログには今回の更新に伴う起動エラーはない。

本作業について「**サーバー側の更新は完了**」と判断できる。一方、「**Webサービスとして完全に正常**」と断定するには、実サイトの操作確認と一定期間のログ監視が必要である。
