"""Whisper 모델 내려받기 (앱 첫 실행 때)

중간에 끊기면 받은 데까지(.part) 남겨 두고, 다시 누르면 이어서 받는다.
"""
import os
import ssl
import threading
import urllib.error
import urllib.request

import pipeline as P

GGML_MAGIC = b'lmgg'   # whisper.cpp 모델 파일의 첫 4바이트


def _ssl_context():
    try:
        import certifi   # 앱으로 묶으면 시스템 인증서 경로를 못 찾을 수 있다
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


class ModelDownloader:
    def __init__(self):
        self.lock = threading.Lock()
        self.downloading = False
        self.received = 0
        self.total = None
        self.error = None

    def ready(self):
        return os.path.isfile(P.WHISPER_MODEL)

    def state(self):
        with self.lock:
            return {
                'ready': self.ready(),
                'name': P.MODEL_NAME,
                'downloading': self.downloading,
                'received': self.received,
                'total': self.total,
                'error': self.error,
            }

    def start(self):
        with self.lock:
            if self.downloading or self.ready():
                return
            self.downloading = True
            self.error = None
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        dst = P.WHISPER_MODEL
        part = dst + '.part'
        try:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            have = os.path.getsize(part) if os.path.exists(part) else 0
            req = urllib.request.Request(P.MODEL_URL, headers={'User-Agent': 'LCRepeater'})
            if have:
                req.add_header('Range', 'bytes=%d-' % have)
            try:
                res = urllib.request.urlopen(req, context=_ssl_context(), timeout=60)
            except urllib.error.HTTPError as e:
                if e.code != 416:
                    raise
                # .part가 이미 끝까지 받아진 상태
                with self.lock:
                    self.received = self.total = have
                res = None
            if res is not None:
                self._save(res, part, have)
            with open(part, 'rb') as f:
                if f.read(4) != GGML_MAGIC:
                    os.remove(part)
                    raise IOError('받은 파일이 Whisper 모델이 아닙니다')
            os.replace(part, dst)
        except Exception as e:
            with self.lock:
                self.error = str(e)
        finally:
            with self.lock:
                self.downloading = False

    def _save(self, res, part, have):
        with res:
            if have and res.status != 206:
                have = 0                      # 이어받기를 지원하지 않으면 처음부터
            length = int(res.headers.get('Content-Length') or 0)
            with self.lock:
                self.received = have
                self.total = have + length if length else None
            with open(part, 'ab' if have else 'wb') as f:
                while True:
                    chunk = res.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
                    with self.lock:
                        self.received += len(chunk)
        if self.total and self.received != self.total:
            raise IOError('내려받기가 중간에 끊겼습니다 (%d / %d 바이트)' % (self.received, self.total))
