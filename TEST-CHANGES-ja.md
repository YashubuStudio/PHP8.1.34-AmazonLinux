# PHP 8.1 公式修正に合わせたテストの調整

対象: `tests-php81-cve.patch`（ビルド時のローカル追加パッチ、Patch201）

## 調整が必要な理由

PHP 公式の PHP 8.1 向け最小修正は、メモリ不足時にプロセスを即終了し、セッションによる組み込みアップロード進捗記録を無効にします。一方、元の PHP 8.1.34 に含まれる一部のテストは、修正前の終了処理や進捗配列を期待したままです。そのままでは、意図した動作変更をテストが失敗として扱います。

このローカルパッチは、その関係をソースから特定できた 11 件の `.phpt` テストだけを調整します。PHP 本体・拡張の C ソースは変更しません。セキュリティ修正の本体は公式コミットの Patch200 です。

`SKIPIF`・`XFAIL` の追加、テスト一式の無効化、失敗の一括無視は行いません。AWS spec のテスト実行を継続し、未知の失敗はビルドの停止条件にします。

## 調整内容

| ファイル | 変更理由と検査内容 |
|---|---|
| `Zend/tests/fibers/get-return-after-bailout.phpt` | メモリ上限到達後に shutdown callback が実行されなくなるため、その callback 内で発生していた 2 件目の FiberError とスタックトレースを期待値から除去。最初のメモリ上限エラーを引き続き検査します。 |
| `Zend/tests/gh11189.phpt` | メモリ上限到達後の出力バッファ終了 callback で書いていた `Success` を期待値から除去。メモリ上限エラーを検査し、callback が走って `Success` が出れば失敗します。 |
| `Zend/tests/gh11189_1.phpt` | 上記と同じ調整を、連想配列のケースに適用します。 |
| `ext/session/tests/rfc1867.phpt` | 進捗配列の内容検査を、その進捗キーが存在しないことの検査に変更します。 |
| `ext/session/tests/rfc1867_inter.phpt` | 1 個目の進捗キーも存在しないことを検査します。元から行っていた 2 個目の不存在検査を維持します。 |
| `ext/session/tests/rfc1867_sid_cookie.phpt` | Cookie でセッション ID を指定するケースでも、進捗キーが存在しないことを検査します。 |
| `ext/session/tests/rfc1867_sid_get.phpt` | GET でセッション ID を指定するケースでも、進捗キーが存在しないことを検査します。 |
| `ext/session/tests/rfc1867_sid_get_2.phpt` | Cookie を使わない設定の GET ケースでも、進捗キーが存在しないことを検査します。 |
| `ext/session/tests/rfc1867_sid_only_cookie.phpt` | Cookie のみを使う設定でも、進捗キーが存在しないことを検査します。 |
| `ext/session/tests/rfc1867_sid_post.phpt` | POST でセッション ID を指定するケースでも、進捗キーが存在しないことを検査します。 |
| `ext/session/tests/rfc1867_sid_invalid.phpt` | 進捗キーの不存在を検査します。無効な ID で進捗を書こうとした際の、スクリプト開始前の警告は発生しなくなるため期待値から除去します。スクリプト自身は従来どおり `error_reporting(0)` を設定しています。 |

8 件のアップロードテストでは、元の multipart リクエスト、`$_FILES` の内容、セッション ID の検査を維持します。通常のアップロードを無効にすることを期待するテストにはしていません。

## 固定した元ソース

- AWS ソース RPM: `php-8.1.34-1.amzn2.src.rpm`
- ソース RPM の SHA-256: `268a00aa08e9e14679a834c3d5f841193968816e5d17e5d59bccbfd8a03a7394`
- 公式 PHP 修正: <https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a>
- 公式修正のパッチファイル SHA-256: `c85ad0fddcbff7f2318617eeaa54d271135463b5bf70a01228447e3ed78de96e`

この 11 ファイルは AWS の既存パッチおよび上記公式修正の対象外なので、Patch201 適用直前も次の元ファイル内容です。

| 元ファイル | 適用前 SHA-256 |
|---|---|
| `Zend/tests/fibers/get-return-after-bailout.phpt` | `096ccebd9a07291ec0d797fb228328c972e1b8d9d3e95430e0bc653cfbf71522` |
| `Zend/tests/gh11189.phpt` | `2751855525839ab96b46880c65b3f0b1ab3a63f0f41d83ff7169c4e3e5011a12` |
| `Zend/tests/gh11189_1.phpt` | `2831545c069b21bdbb74b3050ec037bfebd2ec5c6d1106018aa079bca64cf4c6` |
| `ext/session/tests/rfc1867.phpt` | `1a9eda42286a423244e8d6cf958e767e6231948df499a7e5226badf74de02ffc` |
| `ext/session/tests/rfc1867_inter.phpt` | `c22048259bf09e49fbedf138659cd0d131a76c132085d14286fa5e097c69fa2c` |
| `ext/session/tests/rfc1867_sid_cookie.phpt` | `19ea0f2ea9822ae95b3726567a29e998b023b61f874b04f169012a0cd9d13b1d` |
| `ext/session/tests/rfc1867_sid_get.phpt` | `1263c5544d430406281a42425998df422bb0401f266948237c7b1f3caaa3028f` |
| `ext/session/tests/rfc1867_sid_get_2.phpt` | `4cb24b80ae5caff26ce56314fd2d4028b61d3e0fe4b13322544c8d15289678ac` |
| `ext/session/tests/rfc1867_sid_invalid.phpt` | `a735359284336b30016dc881f6475efbe74e159861cb11559e79de3b53374727` |
| `ext/session/tests/rfc1867_sid_only_cookie.phpt` | `0bff6f7816695eb93048ab493b446356aa1fd8ad1c0d365453aea75fa68558fc` |
| `ext/session/tests/rfc1867_sid_post.phpt` | `a6ab7c93b6055608476655240387b8eff66a792652eeb2751e28101a8de5ed64` |

## 検証したことと限界

- 固定した元ソースに対して、パッチの適用 dry-run、実際の適用、逆適用 dry-run が成功したことを確認しました。`--fuzz=0` で、行のずれによる offset もありません。
- 変更対象が上記 11 件のテストに限定されること、PHPT のセクション構成、アップロードのリクエストと既存のファイル検査が維持されることを確認しました。
- 新しい SKIPIF / XFAIL は追加していません。
- 2026-10-22、実際の AL2 コンテナでコンパイルし、変更した 11 件の PHPT が合格しました。下記の環境互換調整を含む重点 15 件も、合格 15・スキップ 0・警告 0・失敗 0 でした。全体の検証結果は `VALIDATION-ja.md` に記録します。

このテスト専用パッチの SHA-256: `0f68687ff063de5961dd22b37cf8886df146d8a716be1a3d0fdf6f0a65580071`


## AL2 の実行環境に合わせた追加のテスト調整

追加パッチ: `tests-al2-environment.patch`（Patch202、SHA-256: `4fddc3acefc86035aa4dcb5d3ca54dbef1acfab57dc999732268cffa28ef1e51`）

最初の全件実行は総数 17,682、合格 10,298、スキップ 7,372、既存の想定失敗 8、失敗 4、警告 0 でした。失敗を終了条件としてビルドを止め、次の原因を確認しました。

- `ext/date/tests/bug80963.phpt`: AL2 の `tzdata-2026e` ではロンドン・ニューヨーク・ベルリンの履歴件数が 245 / 238 / 147 です。元の AWS 署名済み CLI と今回の CLI の出力は完全に一致し、2037 年の末尾の遷移情報も元の期待値と一致します。固定件数を、元の件数以上であることの検査に変更し、末尾の日時・タイムスタンプ・オフセット・DST・略称の厳密な検査を維持しました。[元の不具合](https://bugs.php.net/bug.php?id=80963)は末尾が1996年や2007年で切れる問題です。
- `ext/openssl/tests/openssl_error_string_basic.phpt`: OpenSSL 1.0.2 の OAEP MGF1 関数番号は 161、1.1.x は 153 なので、同じ理由のエラーコードが `040A1079` / `04099079` になります。元の AWS CLI と今回の CLI で同じ差を確認しました。バージョンに応じた厳密なコードを検査します。参考: [OpenSSL 1.0.2 定義](https://raw.githubusercontent.com/openssl/openssl/OpenSSL_1_0_2-stable/crypto/rsa/rsa.h)、[OpenSSL 1.1.1 定義](https://raw.githubusercontent.com/openssl/openssl/OpenSSL_1_1_1-stable/include/openssl/rsaerr.h)
- `ext/openssl/tests/sni_server.phpt` と `sni_server_key_cert.phpt`: 同梱の3枚のサーバー証明書は 2026-04-02 に期限切れになっていました。既存の `CertificateGenerator.inc` を使い、各テストで有効なCA・証明書・鍵を作成し、終了時に削除します。CA検証、接続先名の検証、3種類のSNI名の検査、鍵と証明書を分けるケースを維持します。[PHP upstreamの現行テスト](https://raw.githubusercontent.com/php/php-src/master/ext/openssl/tests/sni_server.phpt)も同じ生成用ヘルパーを使っています。

PHP本体・拡張のCコード、テストのスキップ条件、XFAIL、TLSの検証設定は変更していません。新しい秘密鍵はテスト実行時だけ作成し、配布物やGitには含めません。

元のファイルと追加調整後のSHA-256:

| ファイル | 調整前 | 調整後 |
|---|---|---|
| `ext/date/tests/bug80963.phpt` | `b19a356bc40d801110fd1ac1de96c14a4ba74b4933b7cfd9273738d1033338e8` | `e0789b48e6a11bafb3df099b1eec04a0d60cf761defb8b54d2116941269b894f` |
| `ext/openssl/tests/openssl_error_string_basic.phpt` | `fb834d847b344435ba2f36f90e09bc40850fd64f0d6bae57eb103372bb43afc5` | `9b37730d0aa32f9f2b96f7d8251a0cc005d60637e3266eea3314ad27eaeddb4b` |
| `ext/openssl/tests/sni_server.phpt` | `6b7957619f0f0fda087c16dbcf26b113e6b5587cbed8d9534718e6508ad678ab` | `6ab54a2f4fbcba1fe64f044d398e7370ead92cf9aea49eab33ac2f9a6129d16e` |
| `ext/openssl/tests/sni_server_key_cert.phpt` | `95afb6959a088d031b7af5e6decfb9a5030d7e9e2939bc2b2989db31ef1bb3a4` | `a290c862f699e7c8caf007f739b512255f7ebf78eb1f882d8db6549a6a549d51` |

## 同じコンパイル結果を使った再試験

初回の全6種類のコンパイルを保存し、`scripts/build-cache.py` で全キャッシュファイル・ツールチェーンRPM一覧・ビルド設定・絶対パスを照合します。通常の `rpmbuild -ba` でソースを展開し直してパッチを適用し、その後に検証済みのビルドディレクトリを復元します。

ソース内容が一致する入力だけ元の時刻を戻し、異なる入力には新しい時刻を付けます。configure・make・install・全件テストを通常どおり実行し、必要な入力が変わった場合はMakeが再コンパイルします。`--nocheck` や `--short-circuit` は使用しません。配布するソースRPMのspecは、追加パッチを含む通常の全工程を再現できる形にします。

configureが内容の同じヘッダーも作り直すため、復旧時だけ `scripts/cache-bin/make` が生成されたCファイル・ヘッダーの内容を保存済みSHA-256と照合します。一致する入力だけ時刻を戻してから、引数を変えず `/usr/bin/make` を実行します。異なる内容のファイルとコンパイル結果の時刻は変更しません。適用記録は `generated-input-cache.jsonl` に残します。

初回の失敗ログ、元のAWS版と再ビルド版の比較、重点15件のログも完成バンドルに含めます。
