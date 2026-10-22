#!/usr/bin/env bash
# Internal: isolated, disposable AL2 container only, never the host or production.
set -Eeuo pipefail
export LC_ALL=C
[[ -f /.dockerenv && $(id -u) == 0 && -d /bundle/new && -d /bundle/old && -d /results ]] || exit 1
. /etc/os-release
[[ $ID == amzn && $VERSION_ID == 2 && $(uname -m) == x86_64 ]] || exit 1
http_pid= fpm_pid= database_pid=
cleanup() {
    local result=$?
    trap - EXIT
    for process in "$http_pid" "$fpm_pid" "$database_pid"; do
        if [[ -n $process ]]; then
            kill "$process" 2>/dev/null || true
            wait "$process" 2>/dev/null || true
        fi
    done
    cp -a /var/log/php-fpm /var/log/httpd /results/ 2>/dev/null || true
    chown -R "$RESULT_UID:$RESULT_GID" /results
    exit "$result"
}
trap cleanup EXIT
(cd /bundle && sha256sum --check --strict SHA256SUMS)
yum --disablerepo='*' --enablerepo=amzn2-core install -y \
    httpd mariadb-server python3 curl cpio procps-ng which findutils diffutils tar gzip util-linux hostname
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-amazon-linux-2*
for package in /bundle/old/*.rpm; do
    rpm --checksig --verbose "$package"
done
yum --disablerepo='*' --enablerepo=amzn2-core localinstall -y /bundle/old/*.rpm

mkdir -p /run/php-fpm /run/httpd /run/mariadb
chown mysql:mysql /run/mariadb
mysql_install_db --user=mysql --datadir=/var/lib/mysql > /results/database-init.log 2>&1
setsid /usr/libexec/mysqld --user=mysql --datadir=/var/lib/mysql --skip-networking \
    --socket=/run/mariadb/php81-test.sock --pid-file=/run/mariadb/php81-test.pid \
    > /results/database.log 2>&1 &
database_pid=$!
for attempt in {1..100}; do
    if mysqladmin --socket=/run/mariadb/php81-test.sock -uroot ping >/dev/null 2>&1; then break; fi
    kill -0 "$database_pid"
    sleep 0.2
done
mysql --socket=/run/mariadb/php81-test.sock -uroot <<'SQL'
CREATE DATABASE php81_validation CHARACTER SET utf8mb4;
CREATE USER 'php81_test'@'localhost' IDENTIFIED BY 'local-container-only';
GRANT ALL ON php81_validation.* TO 'php81_test'@'localhost';
SQL
cp /kit/tests/runtime.php /var/www/html/runtime.php
chmod 0644 /var/www/html/runtime.php
sed -i 's/^Listen 80$/Listen 127.0.0.1:8080/' /etc/httpd/conf/httpd.conf
printf '\nServerName localhost\n' >> /etc/httpd/conf/httpd.conf
cat > /etc/php.d/zz-build-validation.ini <<'INI'
session.upload_progress.enabled=1
session.upload_progress.cleanup=0
INI
printf '\ncatch_workers_output = yes\n' >> /etc/php-fpm.d/www.conf
config_hashes() {
    find /etc/php.ini /etc/php.d /etc/php-fpm.conf /etc/php-fpm.d -type f -print0 \
        | sort -z | xargs -0 sha256sum
}
config_hashes > /results/configuration-before.sha256
php -m > /results/modules-before.txt 2> /results/cli-before.stderr
[[ ! -s /results/cli-before.stderr ]]
start_fpm() {
    /usr/sbin/php-fpm -t
    setsid /usr/sbin/php-fpm --nodaemonize > /results/fpm-"$1".log 2>&1 &
    fpm_pid=$!
}
stop_fpm() {
    kill -QUIT "$fpm_pid"
    wait "$fpm_pid"
    fpm_pid=
}
oom_check() {
    local expected=$1 callback=$2 status=0
    timeout 15 php -n -d memory_limit=8M -r \
        'register_shutdown_function(function () { echo "PHP81_SHUTDOWN_CALLBACK\n"; }); str_repeat("x", 16 * 1024 * 1024);' \
        > /results/oom-"$3".log 2>&1 || status=$?
    [[ $status == "$expected" ]]
    grep -q 'Allowed memory size' /results/oom-"$3".log
    if [[ $callback == yes ]]; then
        grep -q PHP81_SHUTDOWN_CALLBACK /results/oom-"$3".log
    else
        ! grep -q PHP81_SHUTDOWN_CALLBACK /results/oom-"$3".log
    fi
    printf '%s OOM exit status: %s; shutdown callback expected: %s\n' "$3" "$status" "$callback"
}
assert_release() {
    local release=$1 package
    [[ $(rpm -qa 'php*' --qf '%{NAME}\n' | wc -l) == 8 ]]
    for package in php-cli php-common php-fpm php-gd php-mbstring php-mysqlnd php-pdo php-xml; do
        [[ $(rpm -q --qf '%{VERSION}|%{RELEASE}|%{ARCH}' "$package") == "8.1.34|$release|x86_64" ]]
    done
    rpm -qa 'php*' --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' | sort
}
assert_release 1.amzn2
oom_check 255 yes original
start_fpm original
/usr/sbin/httpd -t
setsid /usr/sbin/httpd -DFOREGROUND > /results/apache-console.log 2>&1 &
http_pid=$!
python3 /kit/tests/http-runtime.py original
stop_fpm
if [[ ${BASELINE_ONLY:-0} == 1 ]]; then
    printf 'BASELINE PREFLIGHT PASSED (original AWS RPMs only; candidate not tested)\n'
    exit 0
fi

rpm -Uvh --test /bundle/new/*.rpm
rpm -Uvh /bundle/new/*.rpm
assert_release 1.amzn2.cve20261021.1
for binary in /usr/bin/php /usr/sbin/php-fpm; do
    grep -aFq zend_mm_safe_error_ex "$binary"
done
php -v
php -r '$db = new PDO("sqlite::memory:"); if (PHP_VERSION !== "8.1.34" || (int)$db->query("SELECT 6 * 7")->fetchColumn() !== 42 || mb_strlen("日本語", "UTF-8") !== 3) { exit(1); } echo "CLI execution, PDO and mbstring: OK\n";'
php -m > /results/modules-candidate.txt 2> /results/cli-candidate.stderr
[[ ! -s /results/cli-candidate.stderr ]]
diff -u /results/modules-before.txt /results/modules-candidate.txt
config_hashes > /results/configuration-candidate.sha256
diff -u /results/configuration-before.sha256 /results/configuration-candidate.sha256
oom_check 1 no candidate
start_fpm candidate
python3 /kit/tests/http-runtime.py candidate
stop_fpm

rpm -Uvh --oldpackage --replacepkgs --test /bundle/old/*.rpm
rpm -Uvh --oldpackage --replacepkgs /bundle/old/*.rpm
assert_release 1.amzn2
oom_check 255 yes rollback
start_fpm rollback
python3 /kit/tests/http-runtime.py rollback
stop_fpm

rpm -Uvh --test /bundle/new/*.rpm
rpm -Uvh /bundle/new/*.rpm
assert_release 1.amzn2.cve20261021.1
oom_check 1 no reapplied
start_fpm reapplied
python3 /kit/tests/http-runtime.py reapplied
[[ $(stat -Lc '%d:%i' "/proc/$fpm_pid/exe") == $(stat -Lc '%d:%i' /usr/sbin/php-fpm) ]]
config_hashes > /results/configuration-after.sha256
diff -u /results/configuration-before.sha256 /results/configuration-after.sha256
printf 'RUNTIME VALIDATION PASSED: original -> candidate -> rollback -> reapplied\n'
