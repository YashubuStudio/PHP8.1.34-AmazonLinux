# PHP 8.1.34 / Amazon Linux 2 検証記録

2026-10-22、ローカルの Amazon Linux 2 / x86_64 Docker 環境でビルドと検証を実施中です
修正版のビルド・実行試験が完了するまで、バイナリReleaseは公開しません

確認済み:

- 提供されたキット14ファイルのSHA-256がすべて一致
- 元のAWSソースRPMと切り戻し用8RPMの固定SHA-256・AWS署名を確認
- PHP公式パッチとテスト専用パッチの固定SHA-256、適用・逆適用dry-runを確認
- 元のAWS版8RPMを別のクリーンなAL2コンテナにインストール
- Apache→PHP-FPMの実HTTP要求で、mbstring、GD、DOM、SimpleXML、XMLReader、XMLWriter、PDO SQLite、PDO MySQL、mysqli、mysqlndを確認
- テスト用MariaDBに実際に接続して問い合わせを実行
- 元のCLIのメモリ上限エラーが終了コード255とshutdown callback実行になることを確認

進行中:

- 修正版RPMのコンパイルとAWS specのPHPTテスト
- 修正版の実行試験、RPM更新・切り戻し・再適用

本番環境への接続・パッケージ変更・本番アプリの試験は行っていません

