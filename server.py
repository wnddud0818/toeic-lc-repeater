#!/usr/bin/env python3
"""로컬 웹 플레이어 서버

    python3 server.py            # http://localhost:8765
    python3 server.py --lan      # 같은 와이파이의 휴대폰에서도 접속
"""
import argparse
import json
import os
import queue
import re
import shutil
import socket
import threading
import time
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pipeline as P
from model_download import ModelDownloader

STATIC_DIR = os.path.join(P.BUNDLE_DIR, 'static')
ID_RE = re.compile(r'^[A-Za-z0-9_-]+$')
AUDIO_EXT = {'.mp3', '.m4a', '.wav', '.aac', '.ogg', '.flac', '.mp4'}
MAX_UPLOAD = 1024 ** 3
CONTENT_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.json': 'application/json',
    '.webmanifest': 'application/manifest+json',
}

jobs = queue.Queue()
lesson_lock = threading.Lock()
downloader = ModelDownloader()


def worker():
    while True:
        kind, lid = jobs.get()
        log = lambda m, lid=lid: print('[%s] %s' % (lid, m), flush=True)
        try:
            if kind == 'process':
                P.process(lid, log=log)
            else:
                P.translate_lesson(lid, log=log)
        except Exception as e:
            log('실패: %s' % e)
        finally:
            jobs.task_done()


def lesson_ids():
    if not os.path.isdir(P.DATA_DIR):
        return []
    return sorted((x for x in os.listdir(P.DATA_DIR)
                   if ID_RE.match(x) and os.path.isdir(P.lesson_dir(x))), reverse=True)


def read_status(lid):
    return P.read_json(os.path.join(P.lesson_dir(lid), 'status.json'), {}) or {}


def resume_unfinished():
    """서버가 처리 도중 꺼졌던 레슨을 다시 줄 세운다."""
    for lid in reversed(lesson_ids()):
        stage = read_status(lid).get('stage')
        if stage in ('queued', 'prepare', 'transcribe', 'segment'):
            jobs.put(('process', lid))
        elif stage == 'translate':
            jobs.put(('translate', lid))


def lan_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(('10.255.255.255', 1))
        return s.getsockname()[0]
    except OSError:
        return '127.0.0.1'
    finally:
        s.close()


class Handler(BaseHTTPRequestHandler):
    server_version = 'LCRepeater/0.1'

    def log_message(self, fmt, *args):
        pass

    # ---- 응답 도우미 ----

    def send_bytes(self, body, ctype, status=200, cache='no-store'):
        self.send_response(status)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', cache)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def send_json(self, obj, status=200):
        self.send_bytes(json.dumps(obj, ensure_ascii=False).encode('utf-8'),
                        'application/json; charset=utf-8', status)

    def fail(self, status, msg):
        self.send_json({'error': msg}, status)

    def read_body_json(self):
        n = int(self.headers.get('Content-Length') or 0)
        return json.loads(self.rfile.read(n).decode('utf-8') or '{}') if n else {}

    # ---- 라우팅 ----

    def do_GET(self):
        try:
            self.route_get(urllib.parse.urlparse(self.path).path)
        except Exception:
            traceback.print_exc()
            self.fail(500, '서버 오류')

    do_HEAD = do_GET

    def do_POST(self):
        try:
            self.route_post(urllib.parse.urlparse(self.path).path)
        except Exception:
            traceback.print_exc()
            self.fail(500, '서버 오류')

    def route_get(self, path):
        if path in ('/', '/index.html'):
            return self.serve_static('index.html')
        if path.startswith('/static/'):
            return self.serve_static(path[len('/static/'):])
        if path == '/api/lessons':
            return self.send_json([self.lesson_summary(lid) for lid in lesson_ids()])
        if path == '/api/setup':
            return self.send_json({
                'model': downloader.state(),
                'whisper': bool(P.WHISPER),
                'claude': P.claude_bin(),
            })
        m = re.match(r'^/api/lessons/([A-Za-z0-9_-]+)$', path)
        if m:
            return self.get_lesson(m.group(1))
        m = re.match(r'^/api/lessons/([A-Za-z0-9_-]+)/clip/(\d+)-(\d+)\.wav$', path)
        if m:
            return self.get_clip(m.group(1), int(m.group(2)), int(m.group(3)))
        self.fail(404, '없는 경로')

    def route_post(self, path):
        if path == '/api/lessons':
            return self.upload()
        if path == '/api/setup/download':
            downloader.start()
            return self.send_json(downloader.state(), 202)
        m = re.match(r'^/api/lessons/([A-Za-z0-9_-]+)/translate$', path)
        if m:
            return self.retranslate(m.group(1))
        m = re.match(r'^/api/lessons/([A-Za-z0-9_-]+)/sentences/(\d+)$', path)
        if m:
            return self.update_sentence(m.group(1), int(m.group(2)))
        self.fail(404, '없는 경로')

    # ---- 처리기 ----

    def serve_static(self, name):
        name = os.path.normpath(name)
        if name.startswith('..') or os.path.isabs(name):
            return self.fail(404, '없는 파일')
        path = os.path.join(STATIC_DIR, name)
        if not os.path.isfile(path):
            return self.fail(404, '없는 파일')
        with open(path, 'rb') as f:
            body = f.read()
        ext = os.path.splitext(name)[1]
        self.send_bytes(body, CONTENT_TYPES.get(ext, 'application/octet-stream'))

    def lesson_summary(self, lid):
        d = P.lesson_dir(lid)
        meta = P.read_json(os.path.join(d, 'meta.json'), {}) or {}
        lesson = P.read_json(os.path.join(d, 'lesson.json'))
        return {
            'id': lid,
            'title': meta.get('title', lid),
            'created': meta.get('created'),
            'status': read_status(lid),
            'count': len(lesson['sentences']) if lesson else 0,
            'duration': lesson.get('duration') if lesson else None,
        }

    def get_lesson(self, lid):
        d = P.lesson_dir(lid)
        if not os.path.isdir(d):
            return self.fail(404, '없는 레슨')
        lesson = P.read_json(os.path.join(d, 'lesson.json'))
        self.send_json({'status': read_status(lid), 'lesson': lesson})

    def get_clip(self, lid, a_ms, b_ms):
        if not os.path.isfile(os.path.join(P.lesson_dir(lid), 'master.wav')):
            return self.fail(404, '오디오가 아직 없습니다')
        if b_ms <= a_ms or b_ms - a_ms > 120000:
            return self.fail(400, '구간이 잘못되었습니다')
        body = P.read_clip(lid, a_ms / 1000.0, b_ms / 1000.0)
        # URL에 구간이 들어 있어 내용이 바뀌지 않으므로 오래 캐시해도 된다
        self.send_bytes(body, 'audio/wav', cache='public, max-age=31536000, immutable')

    def upload(self):
        if not downloader.ready():
            return self.fail(409, '음성 인식 모델을 먼저 내려받아 주세요')
        name = urllib.parse.unquote(self.headers.get('X-Filename') or 'audio.mp3')
        ext = os.path.splitext(name)[1].lower()
        if ext not in AUDIO_EXT:
            return self.fail(400, '오디오 파일(mp3 등)만 올릴 수 있습니다')
        n = int(self.headers.get('Content-Length') or 0)
        if n <= 0 or n > MAX_UPLOAD:
            return self.fail(400, '파일 크기가 잘못되었습니다')

        lid = P.new_lesson_id(name)
        while os.path.exists(P.lesson_dir(lid)):
            time.sleep(1)
            lid = P.new_lesson_id(name)
        d = P.lesson_dir(lid)
        os.makedirs(d)
        try:
            with open(os.path.join(d, 'source' + ext), 'wb') as f:
                left = n
                while left > 0:
                    chunk = self.rfile.read(min(left, 1 << 20))
                    if not chunk:
                        raise IOError('업로드가 중간에 끊겼습니다')
                    f.write(chunk)
                    left -= len(chunk)
        except Exception:
            shutil.rmtree(d, ignore_errors=True)
            raise
        P.write_json(os.path.join(d, 'meta.json'), {
            'title': os.path.splitext(os.path.basename(name))[0], 'created': time.time()})
        P.set_status(d, 'queued')
        jobs.put(('process', lid))
        self.send_json({'id': lid}, 201)

    def retranslate(self, lid):
        if not os.path.isfile(os.path.join(P.lesson_dir(lid), 'lesson.json')):
            return self.fail(404, '없는 레슨')
        if read_status(lid).get('stage') not in ('done', 'error'):
            return self.fail(409, '아직 처리 중입니다')
        P.set_status(P.lesson_dir(lid), 'translate')
        jobs.put(('translate', lid))
        self.send_json({'ok': True}, 202)

    def update_sentence(self, lid, i):
        body = self.read_body_json()
        path = os.path.join(P.lesson_dir(lid), 'lesson.json')
        with lesson_lock:
            lesson = P.read_json(path)
            if not lesson:
                return self.fail(404, '없는 레슨')
            s = next((x for x in lesson['sentences'] if x['i'] == i), None)
            if not s:
                return self.fail(404, '없는 문장')
            start = float(body.get('start', s['start']))
            end = float(body.get('end', s['end']))
            start = max(0.0, start)
            end = min(lesson['duration'], end)
            if end - start < 0.2:
                return self.fail(400, '구간이 너무 짧습니다')
            s['start'], s['end'] = round(start, 3), round(end, 3)
            P.write_json(path, lesson)
        self.send_json(s)


def start_worker():
    """처리 작업자를 띄우고, 꺼지기 전에 처리하던 레슨을 다시 줄 세운다."""
    os.makedirs(P.DATA_DIR, exist_ok=True)
    threading.Thread(target=worker, daemon=True).start()
    resume_unfinished()


def make_server(host, port):
    httpd = ThreadingHTTPServer((host, port), Handler)
    httpd.daemon_threads = True
    return httpd


def main():
    ap = argparse.ArgumentParser(description='LC Repeater 로컬 서버')
    ap.add_argument('--port', type=int, default=int(os.environ.get('PORT', 8765)))
    ap.add_argument('--lan', action='store_true', help='같은 네트워크의 다른 기기에서도 접속 허용')
    args = ap.parse_args()

    if not downloader.ready():
        print('Whisper 모델이 없습니다. 화면에서 내려받거나 ./setup.sh 를 실행하세요.')
    start_worker()
    httpd = make_server('0.0.0.0' if args.lan else '127.0.0.1', args.port)
    print('LC Repeater: http://localhost:%d' % args.port)
    if args.lan:
        print('휴대폰(같은 와이파이): http://%s:%d' % (lan_ip(), args.port))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
