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
- この文書作成環境では PHP 8.1 のコンパイルおよび変更した PHPT の実行は未実施です。テスト一式の合格を保証するものではありません。利用者のローカルビルド時にテストを実行し、追加の失敗があれば停止してログを確認します。

このテスト専用パッチの SHA-256: `0f68687ff063de5961dd22b37cf8886df146d8a716be1a3d0fdf6f0a65580071`
