<?php
declare(strict_types=1);

function check(bool $condition, string $message): void {
    if (!$condition) {
        throw new RuntimeException($message);
    }
}

$mode = $_GET['mode'] ?? 'health';
if ($mode === 'oom') {
    ini_set('memory_limit', '8M');
    register_shutdown_function(function (): void {
        file_put_contents('/tmp/php81-runtime-shutdown', 'unexpected shutdown callback');
    });
    str_repeat('x', 16 * 1024 * 1024);
    exit;
}

header('Content-Type: application/json; charset=utf-8');
try {
    check(PHP_VERSION === '8.1.34', 'PHP version');
    check(PHP_SAPI === 'fpm-fcgi', 'FPM SAPI');
    if ($mode === 'session' || $mode === 'upload') {
        check(session_start(), 'session_start');
        $_SESSION['counter'] = ($_SESSION['counter'] ?? 0) + 1;
        $counter = $_SESSION['counter'];
        $progress = isset($_SESSION['upload_progress_build-validation']);
        check(session_write_close(), 'session_write_close');
        if ($mode === 'session') {
            echo json_encode(['counter' => $counter], JSON_THROW_ON_ERROR);
            exit;
        }
        check(isset($_FILES['file']) && $_FILES['file']['error'] === UPLOAD_ERR_OK, 'file upload');
        check(is_uploaded_file($_FILES['file']['tmp_name']), 'uploaded file identity');
        check(file_get_contents($_FILES['file']['tmp_name']) === "PHP81 upload テスト\n", 'uploaded contents');
        check(!$progress, 'disabled built-in session upload progress');
        echo json_encode(['upload' => true, 'progress_present' => $progress], JSON_THROW_ON_ERROR);
        exit;
    }

    check(mb_strlen('日本語', 'UTF-8') === 3, 'mbstring length');
    check(mb_convert_encoding(mb_convert_encoding('日本語', 'SJIS-win', 'UTF-8'), 'UTF-8', 'SJIS-win') === '日本語', 'mbstring round trip');
    $image = imagecreatetruecolor(3, 2);
    check($image !== false, 'GD image');
    ob_start();
    check(imagepng($image), 'GD PNG encode');
    $png = ob_get_clean();
    $decoded = imagecreatefromstring($png);
    check($decoded !== false && imagesx($decoded) === 3 && imagesy($decoded) === 2, 'GD PNG decode');
    imagedestroy($image);
    imagedestroy($decoded);

    $xml = '<root><value>日本語</value></root>';
    $dom = new DOMDocument();
    check($dom->loadXML($xml), 'DOM parse');
    check($dom->getElementsByTagName('value')->item(0)->textContent === '日本語', 'DOM text');
    check((string)simplexml_load_string($xml)->value === '日本語', 'SimpleXML');
    $reader = new XMLReader();
    check($reader->XML($xml), 'XMLReader initialization');
    $elements = 0;
    while ($reader->read()) {
        $elements += (int)($reader->nodeType === XMLReader::ELEMENT);
    }
    $reader->close();
    check($elements === 2, 'XMLReader traversal');
    $writer = new XMLWriter();
    check($writer->openMemory() && $writer->writeElement('test', 'ok'), 'XMLWriter');
    check($writer->outputMemory() === '<test>ok</test>', 'XMLWriter output');

    $sqlite = new PDO('sqlite::memory:', null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    check((int)$sqlite->query('SELECT 6 * 7')->fetchColumn() === 42, 'PDO SQLite query');
    $pdo = new PDO('mysql:unix_socket=/run/mariadb/php81-test.sock;dbname=php81_validation;charset=utf8mb4',
        'php81_test', 'local-container-only', [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $statement = $pdo->prepare('SELECT ? AS value');
    check($statement->execute(['日本語']) && $statement->fetchColumn() === '日本語', 'PDO MySQL prepared query');
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $mysql = new mysqli('localhost', 'php81_test', 'local-container-only', 'php81_validation', 0, '/run/mariadb/php81-test.sock');
    check((int)$mysql->query('SELECT 6 * 7')->fetch_row()[0] === 42, 'mysqli query');
    check(str_contains(mysqli_get_client_info(), 'mysqlnd'), 'mysqlnd client');
    $mysql->close();

    echo json_encode(['ok' => true, 'version' => PHP_VERSION, 'sapi' => PHP_SAPI,
        'pid' => getmypid(), 'checks' => ['mbstring', 'gd', 'dom', 'simplexml', 'xmlreader',
        'xmlwriter', 'pdo_sqlite', 'pdo_mysql', 'mysqli', 'mysqlnd']], JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE);
} catch (Throwable $error) {
    http_response_code(500);
    echo json_encode(['error' => $error->getMessage()], JSON_THROW_ON_ERROR);
}
