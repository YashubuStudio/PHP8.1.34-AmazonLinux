# PHP 8.1.34 / Amazon Linux 2 検証記録

2026-10-22、ローカルの Amazon Linux 2 / x86_64 Docker 環境でビルドと検証を実施中です
全6種類のコンパイルが完了し、初回全件試験で見つかった環境差分4件を調整して、全件試験を再実行しています
修正版のビルド・実行試験が完了するまで、バイナリReleaseは公開しません

確認済み:

- 提供されたキット14ファイルのSHA-256がすべて一致
- 元のAWSソースRPMと切り戻し用8RPMの固定SHA-256・AWS署名を確認
- PHP公式パッチとテスト専用パッチの固定SHA-256、適用・逆適用dry-runを確認
- 元のAWS版8RPMを別のクリーンなAL2コンテナにインストール
- Apache→PHP-FPMの実HTTP要求で、mbstring、GD、DOM、SimpleXML、XMLReader、XMLWriter、PDO SQLite、PDO MySQL、mysqli、mysqlndを確認
- テスト用MariaDBに実際に接続して問い合わせを実行
- 元のCLIのメモリ上限エラーが終了コード255とshutdown callback実行になることを確認
- 最初に完成した修正版CLIで、8.1.34の起動とメモリ上限エラー時の終了コード1・shutdown callbackの不実行を確認
- 修正版CLI/CGIで調整対象11件のPHPTを実行し、11件合格・スキップ0件・警告0件・失敗0件を確認
- コンパイル済みの新しい共有拡張12個をCLIで読み込み、起動時の警告がないこと、GDのPNG入出力、日本語処理、DOM/SimpleXML、XMLReader/Writer、PDO SQLiteの問い合わせ、PDO MySQLドライバーとmysqlndを確認
- 追加調整4件を含む重点15件のPHPTがすべて合格、スキップ・警告・失敗は0件
- 元のAWS CLIと再ビルドCLIで、タイムゾーンとOpenSSLの問題箇所の出力が完全に一致することを確認
- 古いSNI用証明書が2026-04-02に期限切れになっていたことを確認し、各テストで有効な証明書を作成する方式に変更。CA・接続先名の検証とSNI名の検査を維持

進行中:

- 通常のRPMビルド工程とAWS specのPHPT全件試験の再実行
- 修正版の実行試験、RPM更新・切り戻し・再適用

本番環境への接続・パッケージ変更・本番アプリの試験は行っていません

初回の全件結果は、総数17,682、合格10,298、スキップ7,372、既存の想定失敗8、失敗4、警告0です
失敗4件の原因と修正内容、元のファイルのハッシュは [TEST-CHANGES-ja.md](TEST-CHANGES-ja.md) に記録しています
