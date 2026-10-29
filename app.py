#!/usr/bin/env python3
"""LC Repeater 맥 앱 실행 파일 (build_app.sh가 PyInstaller로 .app으로 묶는다)

데이터와 모델은 ~/Library/Application Support/LC Repeater/ 에 둔다(앱 안에는 쓸 수 없다).
개발 중에는 `.venv/bin/python app.py`로 바로 띄워 볼 수 있다.
"""
import os
import socket
import sys
import threading

SUPPORT_DIR = os.environ.get('LCR_SUPPORT_DIR') or \
    os.path.expanduser('~/Library/Application Support/LC Repeater')
APP_PORT = 18765   # 창 주소(=localStorage 저장 위치)가 실행마다 바뀌지 않게 고정 포트를 먼저 쓴다


def setup_logging():
    os.makedirs(SUPPORT_DIR, exist_ok=True)
    log = open(os.path.join(SUPPORT_DIR, 'app.log'), 'a', buffering=1, encoding='utf-8')
    sys.stdout = sys.stderr = log


def pick_port(preferred):
    for port in (preferred, 0):
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(('127.0.0.1', port))
            return s.getsockname()[1]
        except OSError:
            continue
        finally:
            s.close()
    raise RuntimeError('빈 포트를 찾지 못했습니다')


def main():
    if getattr(sys, 'frozen', False):
        setup_logging()

    import pipeline as P
    P.configure(data_dir=os.path.join(SUPPORT_DIR, 'data'),
                model_path=os.path.join(SUPPORT_DIR, 'models', P.MODEL_NAME))
    import server
    import webview

    # Lesson export links download a .lcrlesson document from the local server.
    webview.settings['ALLOW_DOWNLOADS'] = True

    server.start_worker()
    port = pick_port(APP_PORT)
    httpd = server.make_server('127.0.0.1', port)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    print('LC Repeater 앱: http://127.0.0.1:%d (데이터: %s)' % (port, SUPPORT_DIR), flush=True)

    webview.create_window('LC Repeater', 'http://127.0.0.1:%d/' % port,
                          width=1180, height=820, min_size=(380, 560))
    # private_mode=False여야 설정·이어 듣기 위치(localStorage)가 앱을 껐다 켜도 남는다
    webview.start(private_mode=False, storage_path=os.path.join(SUPPORT_DIR, 'webview'))
    httpd.shutdown()


if __name__ == '__main__':
    main()
