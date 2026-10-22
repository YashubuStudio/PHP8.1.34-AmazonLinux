#!/usr/bin/env python3
"""Exercise the installed RPMs through real Apache -> PHP-FPM HTTP requests."""
from concurrent.futures import ThreadPoolExecutor
from http.cookiejar import CookieJar
from pathlib import Path
import json
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import HTTPCookieProcessor, Request, build_opener

URL = 'http://127.0.0.1:8080/runtime.php'


def request(mode='health', opener=None, data=None, headers=None):
    opener = opener or build_opener()
    with opener.open(Request(URL + '?mode=' + mode, data=data, headers=headers or {}), timeout=20) as response:
        assert response.status == 200
        return json.load(response)


def main():
    phase = sys.argv[1]
    for attempt in range(50):
        try:
            health = request()
            assert health['ok'] and health['sapi'] == 'fpm-fcgi'
            break
        except (URLError, OSError):
            if attempt == 49:
                raise
            time.sleep(0.2)
    result = {'phase': phase, 'health': health}
    if phase == 'candidate':
        cookies = build_opener(HTTPCookieProcessor(CookieJar()))
        for expected in range(1, 11):
            assert request('session', cookies)['counter'] == expected
        result['session_requests'] = 10
        boundary = 'php81-build-validation-boundary'
        body = (
            '--{b}\r\nContent-Disposition: form-data; name="PHP_SESSION_UPLOAD_PROGRESS"\r\n\r\n'
            'build-validation\r\n--{b}\r\nContent-Disposition: form-data; name="file"; filename="test.txt"\r\n'
            'Content-Type: text/plain\r\n\r\nPHP81 upload テスト\n\r\n--{b}--\r\n'
        ).format(b=boundary).encode('utf-8')
        upload = request('upload', cookies, body, {'Content-Type': 'multipart/form-data; boundary=' + boundary})
        assert upload == {'upload': True, 'progress_present': False}, upload
        result['multipart_upload_and_disabled_progress'] = True
        with ThreadPoolExecutor(max_workers=8) as executor:
            responses = list(executor.map(lambda _: request(), range(100)))
        assert all(item['ok'] for item in responses)
        result['parallel_requests'] = len(responses)
        result['worker_pids'] = sorted(set(item['pid'] for item in responses))
        callback = Path('/tmp/php81-runtime-shutdown')
        assert not callback.exists()
        fpm_log = Path('/var/log/php-fpm/error.log')
        log_before = fpm_log.stat().st_size
        try:
            with build_opener().open(URL + '?mode=oom', timeout=20) as response:
                status, body = response.status, response.read()
        except HTTPError as error:
            status, body = error.code, error.read()
        # The mitigation exits before FPM can emit response headers. Apache may
        # return an empty response or a gateway error; verify the worker's real
        # memory-limit failure and subsequent healthy requests independently.
        assert status in (200, 500, 502, 503) and (status != 200 or not body), (status, body)
        for attempt in range(50):
            fresh_log = fpm_log.read_bytes()[log_before:]
            if b'Allowed memory size' in fresh_log and b'runtime.php' in fresh_log:
                break
            time.sleep(0.1)
        else:
            raise AssertionError('No PHP-FPM memory-limit diagnostic was captured')
        assert not callback.exists(), 'Unpatched FPM shutdown callback ran'
        for _ in range(10):
            assert request()['ok'], 'FPM did not recover after bounded OOM'
        result['bounded_oom_and_fpm_recovery'] = True
        result['bounded_oom_http_status'] = status
    destination = Path('/results') / ('http-' + phase + '.json')
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
