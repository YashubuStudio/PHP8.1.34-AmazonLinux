# PHP 8.1 セキュリティ修正：手元でビルドして EC2 に適用する

作成日：2026-10-22（日本時間）

**コンパイルは、すべて手元の PC で行います。** 手元の Docker 内に Amazon Linux 2 の作業環境を作り、修正済みの RPM を生成します。GitHub は完成ファイルの受け渡しに使い、本番 EC2 では検証とインストールを行います。GitHub Actions は、検証済み完成物の再照合と Release 公開に使用します。

ソース ZIP は手順書と実行スクリプトのセットで、コンパイル済み RPM は含みません。**公開済み Release を使う場合は再ビルド不要です。** [EC2 の既存 PHP 8.1 を更新する手順](README.md#aws-ec2の既存php-81を更新する)から、完成 RPM の取得・検証・適用を進めてください。この文書の「1〜4」は、自分で再ビルドして配布する場合の手順です。

## 先に確認すること

| 項目 | 今回の対象・必要なもの |
|---|---|
| 本番 OS | Amazon Linux 2 / x86_64 |
| 本番の現在の PHP | AWS 版 `8.1.34-1.amzn2`、下記の８パッケージ |
| 更新後 | PHP 8.1 を維持。RPM の Release は `1.amzn2.cve20261021.1` |
| 本番の PHP 実行方式 | Apache から PHP-FPM へ接続。FPM は `/usr/sbin/php-fpm` |
| 手元の PC | x86_64 の Ubuntu 機、または Windows＋WSL 2 の Ubuntu |
| 手元の Docker | ローカルの Linux コンテナを一般ユーザーで操作できること |
| 計算資源の目安 | ビルドに CPU ２コア分・メモリ４ GiB、さらにホスト OS 用の余裕 |
| 空き容量の目安 | 作業フォルダと Docker の保存先に、合計 20 GiB 程度以上の余裕 |
| 通信 | Docker イメージ、AWS の RPM、PHP の公式パッチ、GitHub に HTTPS 接続できること |
| GitHub | 自分が管理できるリポジトリ。非公開でも利用可能 |
| 本番操作 | いつもの SSH 接続先・秘密鍵と、`ec2-user` の sudo 権限 |
| 作業時間 | 本番への反映時に PHP-FPM を一時停止できる時間帯 |

資源・時間は実測した最低要件ではなく、環境準備のための目安です。ビルドには数十分〜数時間かかる可能性があります。Docker の仮想環境に割り当てるメモリと、PC 全体のメモリは別に考えてください。

更新対象の８パッケージは次のとおりです。追加の PHP パッケージがある場合、このキットは確認段階で停止します。

```text
php-cli    php-common    php-fpm    php-gd
php-mbstring    php-mysqlnd    php-pdo    php-xml
```

## 作業場所と順番

| 順番 | 作業場所 | 作業 |
|---|---|---|
| 1 | 手元の PC | Docker の準備、ZIP の展開 |
| 2 | 手元の PC | `build-local.sh` でビルド・テスト |
| 3 | 手元の PC のブラウザ | 完成した２ファイルを GitHub Releases に添付 |
| 4 | 本番 EC2 | 完成ファイルを取得し、導入前チェック |
| 5 | 本番 EC2 | RPM の更新、PHP-FPM の起動、サイト確認 |

**各コマンドの「実行場所」を確認してください。** 手元の Ubuntu 機や WSL に本番用 RPM をインストールする操作はありません。本番で `build-local.sh` を動かす操作もありません。

## 1. 手元の Docker を準備する

### 1-A. Ubuntu の PC を使う場合

まず、手元の Ubuntu にログインし、環境を確認します。BMAX-N100 などの Ubuntu 機を使う場合も、この手順です。

実行場所：**手元の Ubuntu PC**

```bash
uname -m
free -h
df -h "$HOME"
command -v docker || true
```

`uname -m` は `x86_64` であることを確認します。このキットは ARM 機からのエミュレーションビルドには対応していません。

すでに Docker があり、次が成功する場合はインストールを飛ばし、「2. ZIP を展開する」へ進んでください。

実行場所：**手元の Ubuntu PC**

```bash
docker info --format '{{.OSType}} {{.Architecture}}'
```

Linux の Docker Engine が表示されることを確認します。権限エラーの場合は、後述の「一般ユーザーの Docker 操作権限」を確認します。

#### Docker が未導入の場合だけ実施

以下は、Docker 公式の Ubuntu 用 apt リポジトリを使う導入手順です。WSL で Docker Desktop を使う場合はこの節を実行せず、1-B へ進んでください。[Docker 公式手順](https://docs.docker.com/engine/install/ubuntu/)

既存の `docker.io`、`podman-docker`、`containerd` などがある場合は、既存環境との競合を確認してから進めます。この手順には、それらを自動削除するコマンドを含めていません。

実行場所：**手元の Ubuntu PC**

```bash
dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' \
  docker-ce docker.io podman-docker containerd containerd.io runc \
  2>/dev/null || true
```

未導入の状態を確認したら、次を順番に実行します。途中で失敗した場合は、後続のコマンドへ進まないでください。

実行場所：**手元の Ubuntu PC**

```bash
sudo apt update
sudo apt install ca-certificates curl unzip
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo systemctl start docker
sudo docker info --format '{{.OSType}} {{.Architecture}}'
```

#### 一般ユーザーの Docker 操作権限

このキットの `build-local.sh` は、一般ユーザーで実行します。`sudo docker info` は成功するのに `docker info` が権限エラーになる場合は、Docker を使用する自分のアカウントを `docker` グループへ追加します。このグループは Docker を通じてホストを管理できる権限を持ちます。

実行場所：**手元の Ubuntu PC**

```bash
sudo usermod -aG docker "$(id -un)"
```

その後、**いったんログアウトし、ログインし直します。** SSH の場合は接続を終了して再接続してください。再ログイン後、次が sudo なしで成功すれば準備完了です。

実行場所：**手元の Ubuntu PC／再ログイン後**

```bash
docker info --format '{{.OSType}} {{.Architecture}}'
```

### 1-B. Windows の PC を使う場合

Windows では **Docker Desktop＋WSL 2 の Ubuntu** を使います。以降の Bash コマンドは Ubuntu のターミナルで実行し、PowerShell には貼り付けません。

1. [Docker Desktop の公式要件](https://docs.docker.com/desktop/setup/install/windows-install/)を確認します。ハードウェア仮想化、対応する Windows、PC 全体のメモリ容量が必要です。
2. WSL が未導入の場合、管理者として開いた PowerShell で下記を実行し、求められたら再起動します。既存の WSL がある場合は、再インストールせず状態を確認します。

実行場所：**手元の Windows／管理者 PowerShell、WSL 未導入時のみ**

```powershell
wsl --install
```

3. Ubuntu を初回起動し、Linux 用の一般ユーザーとパスワードを作成します。
4. Docker Desktop を公式サイトからインストールして起動します。
5. Docker Desktop の設定で WSL 2 のエンジンを使用し、`Settings → Resources → WSL Integration` で利用する Ubuntu を有効にします。Linux コンテナを使います。
6. PowerShell で Ubuntu の `VERSION` が `2` であることを確認します。

実行場所：**手元の Windows／PowerShell**

```powershell
wsl --list --verbose
```

7. Ubuntu のターミナルを開き、次を確認します。

実行場所：**手元の Windows 内の WSL Ubuntu**

```bash
uname -m
docker info --format '{{.OSType}} {{.Architecture}}'
```

`x86_64` と Linux の Docker が確認できたら、次へ進みます。Docker Desktop と WSL 内への別の Docker Engine の二重導入は避け、すでに別構成がある場合は既存設定を確認してください。[WSL 連携の公式手順](https://docs.docker.com/desktop/features/wsl/)

## 2. ZIP を手元に展開する

`php81-local-build-kit.zip` を手元の PC にダウンロードします。作業先は、Ubuntu または WSL Ubuntu のホームディレクトリ内を使います。例では `~/work/php81-local-build-kit/` です。

Ubuntu のダウンロード先が `~/Downloads/` の場合の例です。実際の保存先が違う場合は ZIP のパスを変更してください。すでに同名フォルダがある場合は上書きせず、新しい作業場所を用意します。

実行場所：**手元の Ubuntu PC または WSL Ubuntu**

```bash
mkdir -p "$HOME/work"
unzip "$HOME/Downloads/php81-local-build-kit.zip" -d "$HOME/work"
cd "$HOME/work/php81-local-build-kit"
sha256sum --check --strict KIT-SHA256SUMS
```

WSL から Windows のダウンロードフォルダを参照する場合は、ZIP のパスを `/mnt/c/Users/Windowsのユーザー名/Downloads/php81-local-build-kit.zip` に変更します。パス全体を引用符で囲んで指定してください。**展開先は `~/work` のままにします。** `unzip` がない場合のみ、Ubuntu 側で `sudo apt install unzip` を実行します。

`KIT-SHA256SUMS` の各項目が `OK` になったことを確認します。これは ZIP 内のファイルが揃っているかを確認するものです。

## 3. 手元でビルドする

実行場所：**手元の Ubuntu PC または WSL Ubuntu／キットのフォルダ**

```bash
cd "$HOME/work/php81-local-build-kit"
BUILD_JOBS=2 bash build-local.sh
```

**`sudo bash build-local.sh` では実行しません。** コンテナ内のユーザー作成や sudo の準備は、スクリプトが自動で行います。`build-rpms.sh` を Ubuntu ホスト上で直接実行する必要もありません。

処理は次の順番です。

1. Docker の接続先がローカルの Unix ソケットであること、Linux / x86_64 であることを確認。
2. AWS 公式の `public.ecr.aws/amazonlinux/amazonlinux:2` を取得し、実際に取得したイメージの digest を記録。
3. 手元の Docker 内で Amazon Linux 2 のコンテナを起動。
4. コンテナ内だけに開発ツールを追加し、一般ユーザーで AWS の PHP ソース RPM を展開。
5. 公式の PHP 8.1 修正パッチと、後述のテスト専用調整を追加し、RPM をビルドしてテスト。
6. 本番に必要な８個の新 RPM、切り戻し用の８個の旧 RPM、ソース・ログ・適用スクリプトをまとめる。

既存の Ubuntu の PHP や本番 EC2 の PHP は、この段階では更新されません。Amazon Linux 2 は手元の PC 内で動きます。リモート Docker の `ssh://` や `tcp://` 接続先は、このキットでは拒否します。

### 負荷の設定

標準設定は、コンパイル２並列、コンテナの CPU 上限２コア分、メモリ上限４ GiB です。コンテナには上限を超える追加の swap 枠を割り当てません。PC 上で別の作業を続ける場合、CPU を１コア分に抑える例は次のとおりです。

実行場所：**手元の Ubuntu PC または WSL Ubuntu／ビルド開始前**

```bash
BUILD_JOBS=1 BUILD_CPUS=1 BUILD_MEMORY=4g bash build-local.sh
```

メモリ不足でコンテナが停止した場合は、ホストと Docker 側に余裕があることを確認してから、たとえば `BUILD_MEMORY=6g` に増やします。メモリ不足を解消せずテストやチェックを無効にして進める手順にはしません。

### ビルド成功時にできるファイル

最後に `LOCAL BUILD COMPLETED` と表示され、キットの `output/` に転送用の２ファイルができます。

```text
php81-rpms-8.1.34-cve20261021.1.tar.gz
php81-rpms-8.1.34-cve20261021.1.tar.gz.sha256
```

実行場所：**手元の Ubuntu PC または WSL Ubuntu／ビルド成功後**

```bash
cd "$HOME/work/php81-local-build-kit/output"
sha256sum --check --strict php81-rpms-8.1.34-cve20261021.1.tar.gz.sha256
```

`OK` が出ることを確認します。`output/local-build-日時-.../` に起動・コンテナのログ、`output/php81-build.XXXXXXXX/` にソースや RPM ビルドの作業ファイルが残ります。**失敗時もログを保持します。** 同名の完成アーカイブがある状態で再実行すると、上書きせず停止します。

## 4. GitHub Releases に完成ファイルを置く

実行場所：**手元の PC のブラウザ／GitHub**

1. 自分で管理するリポジトリを選びます。新しく作る場合の名前の例は `php81-al2-security-build` です。非公開でよく、新規作成時は README を追加して、ブランチに最初のコミットがある状態にします。
2. リポジトリの `Releases` から `Draft a new release` を開きます。
3. タグ名を `php81-8.1.34-cve20261021.1` として作成します。同じタグがすでにある場合は、その内容を確認し、別ビルドで上書きしません。
4. タイトルの例を `PHP 8.1.34 / Amazon Linux 2 / security rebuild` とします。
5. 本番に入れる完成物として、`output/` の `.tar.gz` と `.tar.gz.sha256` の２ファイルを添付します。
6. アップロードが完了したことを確認し、Release を公開します。非公開リポジトリ内の Release は、そのリポジトリにアクセスできる人が取得するものです。

説明文は同梱の `RELEASE-NOTES-ja.txt` を使えます。「Amazon Linux 2 x86_64 用のローカル再ビルド、PHP 公式修正コミット、AWS 公式署名付きの修正版バイナリではないこと」を記載しています。ソース、パッチ、ログは完成アーカイブの中にも含まれます。GitHub が自動生成する `Source code (zip)` は、今回作った RPM のアーカイブとは別です。[GitHub の Release 作成手順](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)

WSL で作成した `output/` を Windows のファイル選択画面で開く場合は、エクスプローラーから `\\wsl$\Ubuntu\home\Linuxのユーザー名\work\php81-local-build-kit\output` を参照します。`Ubuntu` の部分は、実際の WSL ディストリビューション名に置き換えます。

## 5. 本番 EC2 で完成ファイルを取得する

対象の Amazon Linux 2 / x86_64 EC2 に、普段使っている SSH ホスト名・鍵で接続します。プライベート IP を使う場合は、その EC2 に到達できるネットワークから接続してください。必要な PHP の版・8 パッケージ・Apache / FPM 構成は、上の「先に確認すること」で確認します。

### 5-A. 公開リポジトリの場合

下記は、このリポジトリの公開済み Release を使うコマンドです。`latest` ではなく、検証済みのタグを指定して取得します。取得先に同名ファイルがある場合は、その内容を確認してから進めてください。ログインユーザーのホームが `/home/ec2-user` 以外の場合は、そのパスに読み替えます。

実行場所：**本番 EC2／SSH 接続後、公開リポジトリの場合**

```bash
(
  set -e
  cd /home/ec2-user
  php81_archive='php81-rpms-8.1.34-cve20261021.1.tar.gz'
  php81_release_url='https://github.com/YashubuStudio/PHP8.1.34-AmazonLinux/releases/download/php81-8.1.34-cve20261021.1'
  if [ -e "$php81_archive" ] || [ -e "$php81_archive.sha256" ]; then
    printf '%s\n' '同名ファイルがあります。既存の内容を確認してから続行してください。' >&2
    exit 1
  fi
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 1800 \
    --output "$php81_archive" "$php81_release_url/$php81_archive"
  curl --fail --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 1800 \
    --output "$php81_archive.sha256" "$php81_release_url/$php81_archive.sha256"
  sha256sum --check --strict "$php81_archive.sha256"
)
```

`OK` が出たら「6. 本番で導入前チェックする」へ進みます。失敗した場合は、途中まで取得したファイルを完成物として使用しません。

### 5-B. 非公開リポジトリの場合

キットには、公開・非公開リポジトリの両方に対応する `download-release.py` を同梱しています。GitHub CLI は不要で、Python 3 の標準機能で取得します。補助スクリプトを本番の `/home/ec2-user/` に一度だけ送ります。

下の鍵のパスと `PRODUCTION_SSH_HOST` を実際の値に置き換えてください。秘密鍵自体は転送しません。

実行場所：**手元の Ubuntu PC または WSL Ubuntu**

```bash
cd "$HOME/work/php81-local-build-kit"
scp -i /path/to/production-key.pem \
  download-release.py \
  ec2-user@PRODUCTION_SSH_HOST:/home/ec2-user/
```

本番で Python 3 が利用できることを確認します。

実行場所：**本番 EC2／SSH 接続後**

```bash
python3 --version
```

Python 3 がない場合に限り、追加するパッケージを確認して導入できます。追加したくない場合は、後述の「直接渡す場合」を使います。

実行場所：**本番 EC2／Python 3 がない場合だけ**

```bash
sudo yum --disablerepo='*' --enablerepo=amzn2-core install python3
```

GitHub の fine-grained personal access token を用意します。手元のブラウザで `Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token` を開き、利用する所有者を選びます。`Repository access` は今回のリポジトリだけに限定し、`Contents: Read-only` 権限と有効期限を設定して作成します。組織側で承認が必要な場合は、承認後に使用します。[トークン作成の公式手順](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)／[取得 API の必要権限](https://docs.github.com/en/rest/releases/assets)

`OWNER/REPO` は、たとえば `YashubuStudio/php81-al2-security-build` のような形式です。ここに例示するリポジトリが作成済みという意味ではありません。

実行場所：**本番 EC2／非公開リポジトリから取得**

```bash
cd /home/ec2-user
python3 download-release.py \
  --repo YashubuStudio/PHP8.1.34-AmazonLinux \
  --tag php81-8.1.34-cve20261021.1 \
  --output /home/ec2-user \
  --private
```

トークンは、表示される非表示入力欄へ貼り付けます。コマンドの引数やファイルにトークンを書き込む必要はありません。公開リポジトリにこの補助スクリプトを使う場合は、`--private` を外します。

取得先は `/home/ec2-user/` です。ここに `.tar.gz` と `.tar.gz.sha256` が揃ってから、次の手順へ進みます。取得エラーの場合は `apply` を実行しません。

### GitHub を経由せず、直接渡す場合

同じ完成ファイルを、SCP や普段の SFTP ツールで転送しても構いません。直接転送する場合は、上の GitHub 取得手順を省略できます。

実行場所：**手元の Ubuntu PC または WSL Ubuntu**

```bash
cd "$HOME/work/php81-local-build-kit/output"
scp -i /path/to/production-key.pem \
  php81-rpms-8.1.34-cve20261021.1.tar.gz \
  php81-rpms-8.1.34-cve20261021.1.tar.gz.sha256 \
  ec2-user@PRODUCTION_SSH_HOST:/home/ec2-user/
```

## 6. 本番で導入前チェックする

この段階では、本番の PHP パッケージは交換しません。アーカイブを確認して展開し、既存設定と新 RPM の整合性を調べます。

実行場所：**本番 EC2／SSH 接続後**

```bash
(
  set -e
  cd /home/ec2-user
  sha256sum --check --strict php81-rpms-8.1.34-cve20261021.1.tar.gz.sha256
  if [ -e php81-rpms-8.1.34-cve20261021.1 ]; then
    printf '%s\n' '展開先がすでにあります。既存の内容を確認してから続行してください。' >&2
    exit 1
  fi
  tar -xzf php81-rpms-8.1.34-cve20261021.1.tar.gz
  cd php81-rpms-8.1.34-cve20261021.1
  sudo bash install-rpms.sh check "$PWD"
)
```

最後に **`PRECHECK OK`** が出たことを確認します。エラーで停止した場合は、本番適用へ進みません。

チェックには、現在の８パッケージと版の一致、RPM の依存関係、旧 AWS RPM の署名、チェックサム、候補 CLI による現行の拡張・設定の読み込み、候補 PHP-FPM の構文検査が含まれます。候補 CLI の独立プロセスで、小さな PHP メモリ上限による修正後の動作確認も行います。

同じ展開済みバンドルのチェックだけをやり直す場合は、次を使います。

実行場所：**本番 EC2／同じ完成バンドルを展開済みの場合**

```bash
sudo bash /home/ec2-user/php81-rpms-8.1.34-cve20261021.1/install-rpms.sh \
  check /home/ec2-user/php81-rpms-8.1.34-cve20261021.1
```

## 7. 本番に適用する

**ここから PHP-FPM を一時停止します。** PHP を使うページが一時的にエラーになる可能性があるため、停止できる作業時間に実行してください。コンパイルを待つ時間の停止はありません。

実行場所：**本番 EC2／導入前チェック成功後**

```bash
sudo bash /home/ec2-user/php81-rpms-8.1.34-cve20261021.1/install-rpms.sh \
  apply /home/ec2-user/php81-rpms-8.1.34-cve20261021.1
```

スクリプトは事前チェックをもう一度行い、設定・導入前のパッケージ一覧・切り戻し用 RPM を `/var/backups/php81-cve-日時.XXXXXXXX/` に保存してから、８個の RPM をまとめて更新します。その後、PHP-FPM の設定・起動・実行中バイナリを確認します。バックアップは root 専用です。

現在の Apache は FPM に接続する構成なので、Apache の再起動処理は入っていません。PHP 設定も編集せず、既存の `/etc/php.d/zz-cve-2026-109618-109619.ini` を保持します。本番で依存パッケージを自動更新する処理はありません。

## 8. 適用結果とサイトを確認する

実行場所：**本番 EC2／適用後**

```bash
rpm -q php-cli php-common php-fpm php-gd php-mbstring php-mysqlnd php-pdo php-xml
php -v
sudo systemctl status php-fpm --no-pager
sudo journalctl -u php-fpm -n 50 --no-pager
```

確認点は次のとおりです。

- ８パッケージすべてが `8.1.34-1.amzn2.cve20261021.1.x86_64` になっている。
- PHP-FPM が `active` で動作している。
- `php -v` は **8.1.34 のままで正常**。パッチを当てても PHP 本体の表示版番号は変わらない。
- ブラウザで既存サイトのページ表示、ログイン維持、フォーム送信、少量のファイルアップロードを確認できる。
- 複数サイトや FPM プールがある場合、それぞれの代表的な PHP 処理が動く。

`check` の成功だけでは、アプリケーションの互換性までは確認できません。確認が終わるまで、手元の `output/` と本番のバックアップを残してください。

## 9. 不具合時に元へ戻す

この操作は元の AWS 版 `8.1.34-1.amzn2` に戻します。**今回の２件の修正も外れる**ため、不具合からの復旧に必要な場合に使用します。切り戻し時も PHP-FPM を一時停止します。

実行場所：**本番 EC2／切り戻しが必要な場合だけ**

```bash
sudo bash /home/ec2-user/php81-rpms-8.1.34-cve20261021.1/install-rpms.sh \
  rollback /home/ec2-user/php81-rpms-8.1.34-cve20261021.1
```

適用時に表示される `/var/backups/` 内のバックアップから戻すコマンドも使えます。画面に表示された正確なパスを使用してください。設定ファイルを一律に復元する操作は行いません。

途中で新旧の RPM が混在した場合も、各パッケージが１件ずつ登録されていれば切り戻し対象です。同名パッケージの重複登録、RPM データベースの破損などは、追加調査が必要です。自動的にあらゆる失敗を修復するスクリプトではありません。

## エラーで止まったとき

| 状況 | 確認すること |
|---|---|
| `docker: command not found` | 手元に Docker があるか。WSL では Docker Desktop の WSL Integration が有効か |
| Docker の permission denied | Ubuntu で Docker の操作権限を設定し、ログインし直したか。キットは一般ユーザーで実行する |
| リモート Docker を拒否された | `DOCKER_HOST`、`DOCKER_CONTEXT`、Docker context が手元の Docker を指しているか |
| コンテナがメモリ不足で停止 | PC と Docker に余裕があるか。必要なら `BUILD_MEMORY` を増やして新しい作業環境で再実行する |
| RPM のビルド・テスト失敗 | `output/local-build-.../console.log`、`output/php81-build.XXXXXXXX/build-run.log`、`output/php81-build.XXXXXXXX/php81-rpms-8.1.34-cve20261021.1/logs/rpmbuild.log` を確認する |
| 完成アーカイブが既存のため停止 | 以前の完成物を保管し、新しいフォルダへキットを展開してやり直す |
| GitHub の 404 / 認証失敗 | OWNER/REPO、タグ、添付したファイル名、Release の公開状態、非公開リポジトリの読み取り権限 |
| 本番で必要なツールがない | エラーに表示されたツールだけを確認。`cpio` が不足する場合の例は下記 |
| 本番のパッケージ構成が違う | 現在の `rpm -qa 'php*'` を確認。このキットの前提と違う場合は、対象を見直す |
| 本番の依存関係・拡張・FPM 設定で停止 | エラー内容を解決して再チェック。`--force` や `--nodeps` で通さない |
| 本番の適用開始後に停止 | FPM の状態とエラーを確認し、表示された切り戻しコマンドで復旧するか判断する |

`cpio` だけが不足している場合の例です。表示される追加・更新内容を確認して実行します。

実行場所：**本番 EC2／`cpio` 不足と表示された場合だけ**

```bash
sudo yum --disablerepo='*' --enablerepo=amzn2-core install cpio
```

ビルド失敗の調査では、ログの最後のエラー部分を共有すると原因を追いやすくなります。ビルド用のテストは失敗を無視せず停止する設定です。既存テストが環境条件で失敗する場合も、原因を確認してから対応します。公式修正による動作変更に対応するテスト期待値の調整は、別のテスト専用パッチとして同梱し、`TEST-CHANGES-ja.md` で説明しています。テストを一括でスキップするものではありません。

## 修正の内容と互換性

適用するのは、PHP 公式の PHP 8.1 向け修正コミット `1d7dec178a094e6e75b229ce22754045f8c6070a` です。対象は `CVE-2026-109618` と `CVE-2026-109619` です。PHP 8.2 へ切り替える手順ではありません。

PHP 8.1 のままでも、修正に伴い次の動作変更があります。

- PHP 組み込みの `session.upload_progress` による進捗記録は、設定値に関係なく無効になります。通常のアップロードや通常のセッション全体が無効になるという意味ではありません。
- PHP のメモリ上限到達など、修正対象の異常終了経路では、そのプロセスが直ちに終了します。その場合は、通常の shutdown callback や終了時のセッション保存が実行されることを前提にできません。
- multipart フォームのヘッダー処理も変更されます。

AWS の元ソースと PHP の修正パッチを使いますが、完成した RPM は **自分の PC で作った未署名のローカルビルド**です。AWS が配布・署名した修正版バイナリではありません。RPM 署名を必須とする独自運用がある場合、その設定を無効にするのではなく、自分の管理する鍵で署名するなど運用に合わせた対応が必要です。[PHP 公式コミット](https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a)

## ビルドと検証の確認範囲

2026-10-22、Amazon Linux 2 / x86_64の実コンテナで全6構成のコンパイルと通常のRPMビルドを完了しました。PHPTは総数17,682、合格10,302、スキップ7,372、既存の想定失敗8、失敗0、警告0です。公式修正による動作変更11件とAL2環境差4件を、独立したテスト専用パッチで調整しています。テストのスキップ・失敗の一括無視・TLS検証の無効化は追加していません。

**別のクリーンなAL2環境で、完成RPMの更新・切り戻し・再適用、Apache→PHP-FPM→MariaDB、通常セッション・アップロード、8クライアント100要求、限定的なメモリ上限エラー後の復帰、設定・モジュール保持を確認しました。** 本番への接続・変更、本番アプリ、systemd依存の導入手順全体は未実施です。導入前checkと適用後のサイト確認を行ってください。詳細と証拠は検証記録を参照してください。

[検証記録と確認範囲](VALIDATION-ja.md)

## 同梱ファイル

| ファイル | 役割 |
|---|---|
| `START-HERE-ja.txt` | 最初に読む短い案内 |
| `README.html` | ブラウザで読めるこの手順書 |
| `README-ja.md` | 手順書の Markdown 版 |
| `build-local.sh` | 手元の Docker を確認し、ローカルビルドを開始 |
| `container-build.sh` | コンテナ内のユーザーとツールを準備 |
| `build-rpms.sh` | 公式ソースとパッチから RPM を作成 |
| `install-rpms.sh` | 本番での check / apply / rollback |
| `download-release.py` | GitHub Releases の完成ファイルを取得（Python 3） |
| `tests-php81-cve.patch` | 公式修正による動作変更に合わせたテスト期待値の調整 |
| `tests-al2-environment.patch` | タイムゾーン履歴・OpenSSL版差・期限切れ証明書へのテスト専用調整 |
| `VALIDATION-ja.md` | 全件試験・完成RPM実行試験の詳細と証拠 |
| `TEST-CHANGES-ja.md` | テスト期待値を調整した理由と範囲 |
| `RELEASE-NOTES-ja.txt` | GitHub Release の説明欄に使う文章 |
| `VALIDATION-ja.txt` | ビルド・実行試験の結果と未実施の範囲 |
| `KIT-SHA256SUMS` | キット内ファイルのチェックサム |

## 一次資料と固定した入力

- [Amazon Linux コンテナのローカル利用](https://docs.aws.amazon.com/AmazonECR/latest/userguide/amazon_linux_container_image.html)
- [Docker Engine / Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker Desktop / Windows](https://docs.docker.com/desktop/setup/install/windows-install/)
- [Docker Desktop と WSL 2 の連携](https://docs.docker.com/desktop/features/wsl/)
- [Microsoft：WSL のインストール](https://learn.microsoft.com/en-us/windows/wsl/install)
- [GitHub Releases の作成](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
- [GitHub Release assets API](https://docs.github.com/en/rest/releases/assets)
- [GitHub の personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [PHP 公式告知](https://www.php.net/archive/2026.php)
- [PHP 8.1 公式修正コミット](https://github.com/php/php-src/commit/1d7dec178a094e6e75b229ce22754045f8c6070a)
- [AWS ソースパッケージ](https://docs.aws.amazon.com/linux/al2/ug/amazon-linux-source-packages.html)
- [元の AWS PHP 8.1.34 のアドバイザリ](https://alas.aws.amazon.com/AL2/ALAS2PHP8.1-2026-008.html)

元の AWS ソース RPM の SHA-256：

```text
268a00aa08e9e14679a834c3d5f841193968816e5d17e5d59bccbfd8a03a7394
```

公式 PHP パッチの SHA-256：

```text
c85ad0fddcbff7f2318617eeaa54d271135463b5bf70a01228447e3ed78de96e
```

旧８ RPM の URL・ハッシュは `build-rpms.sh` 内に固定されています。完成したバンドルにも `sources/upstream-downloads.tsv` として保存されます。新しい RPM と同梱ファイルの転送確認用ハッシュは、完成バンドルの `SHA256SUMS` に記録します。
