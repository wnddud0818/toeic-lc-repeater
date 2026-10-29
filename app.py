#!/usr/bin/env python3
"""LC Repeater desktop entry point, packaged by PyInstaller on macOS and Windows.

데이터와 모델은 ~/Library/Application Support/LC Repeater/ 에 둔다(앱 안에는 쓸 수 없다).
개발 중에는 `.venv/bin/python app.py`로 바로 띄워 볼 수 있다.
"""
import os
import socket
import sys
import threading
from desktop_runtime import support_dir

SUPPORT_DIR = support_dir()
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

    base_url = 'http://127.0.0.1:%d' % port
    smoke_report = sys.argv[2] if len(sys.argv) == 3 and sys.argv[1] == '--smoke-test' else None
    if smoke_report and not os.environ.get('LCR_SUPPORT_DIR'):
        raise RuntimeError('--smoke-test requires an isolated LCR_SUPPORT_DIR')
    url = base_url + ('/#/l/test-lesson' if smoke_report else '/')
    window = webview.create_window('LC Repeater', url,
                                   width=1180, height=820, min_size=(380, 560))
    if smoke_report:
        from desktop_smoke import check_window
        window.events.loaded += lambda: check_window(window, base_url, smoke_report)
    # private_mode=False여야 설정·이어 듣기 위치(localStorage)가 앱을 껐다 켜도 남는다
    webview.start(gui='edgechromium' if sys.platform == 'win32' else None,
                  private_mode=False, storage_path=os.path.join(SUPPORT_DIR, 'webview'))
    httpd.shutdown()


if __name__ == '__main__':
    main()
