#!/usr/bin/env python3
"""Whisper·Claude 처리 엔진 명령줄 (맥 네이티브 앱이 helper로 실행한다)

    engine_cli.py status [--model 모델경로]
    engine_cli.py download-model --model 모델경로
    engine_cli.py transcribe 음원 --lang en|ja --work 작업폴더 [--model 모델경로]
    engine_cli.py translate lesson.json

표준 출력에는 한 줄에 JSON 하나씩 쓴다.
  {"event": "progress", "label": "음성 인식 중", "fraction": 0.42}
  {"event": "done", ...}
  {"event": "error", "code": "not_logged_in" | "failed", "message": "..."}
성공하면 종료 코드 0, 실패하면 1이다. --watch-stdin을 주면 표준 입력이 닫힐 때(앱이 꺼질 때)
whisper·claude 자식 프로세스까지 함께 끝낸다.
"""
import argparse
import json
import os
import signal
import sys
import threading
import time

if getattr(sys, 'frozen', False) and not os.environ.get('WHISPER_BIN'):
    # 앱 안에서는 whisper-cli가 이 실행 파일 옆(Contents/Helpers)에 있다
    _side = os.path.join(os.path.dirname(os.path.abspath(sys.executable)), 'whisper-cli')
    if os.path.exists(_side):
        os.environ['WHISPER_BIN'] = _side

import pipeline as P  # noqa: E402  (WHISPER_BIN을 정한 뒤 읽어야 한다)

_out_lock = threading.Lock()


def emit(event, **fields):
    fields['event'] = event
    line = json.dumps(fields, ensure_ascii=False)
    with _out_lock:
        sys.stdout.write(line + '\n')
        sys.stdout.flush()


def fail(message, code='failed'):
    emit('error', code=code, message=str(message)[-800:])
    return 1


def _stop_group(*_):
    """자신과 자식(whisper-cli, claude, afconvert)을 함께 끝낸다."""
    try:
        os.killpg(os.getpgrp(), signal.SIGKILL)
    finally:
        os._exit(143)


def watch_stdin():
    def run():
        try:
            while sys.stdin.buffer.read(4096):
                pass
        except (OSError, ValueError):
            pass
        _stop_group()
    threading.Thread(target=run, daemon=True).start()


# ---------- 명령 ----------

def cmd_status(args):
    emit('done', whisper=bool(P.WHISPER), model={'ready': os.path.isfile(P.WHISPER_MODEL), 'path': P.WHISPER_MODEL,
                                                 'name': P.MODEL_NAME},
         claude=P.claude_bin())
    return 0


def cmd_download_model(args):
    from model_download import ModelDownloader
    downloader = ModelDownloader()
    if downloader.ready():
        emit('done', path=P.WHISPER_MODEL)
        return 0
    downloader.start()
    while True:
        state = downloader.state()
        if not state['downloading']:
            break
        total = state['total']
        emit('progress', label='음성 인식 모델 내려받는 중', received=state['received'], total=total,
             fraction=round(state['received'] / float(total), 4) if total else None)
        time.sleep(0.5)
    state = downloader.state()
    if state['ready']:
        emit('done', path=P.WHISPER_MODEL)
        return 0
    return fail(state['error'] or '모델을 내려받지 못했습니다')


def cmd_transcribe(args):
    if not os.path.isfile(args.audio):
        return fail('음원 파일이 없습니다: %s' % args.audio)
    if not P.WHISPER:
        return fail('whisper-cli를 찾을 수 없습니다')
    if not os.path.isfile(P.WHISPER_MODEL):
        return fail('Whisper 모델이 없습니다. 먼저 모델을 내려받아 주세요.', 'no_model')
    os.makedirs(args.work, exist_ok=True)
    lesson_id = P.import_file(args.audio, args.title, args.lang)
    original = P.set_status
    span = P.STAGES['segment'][2]   # 번역 전까지가 이 명령의 전체 진행률이다

    def set_status(d, stage, frac=0.0, error=None):
        original(d, stage, frac, error)
        label, lo, hi = P.STAGES[stage]
        if stage in ('prepare', 'transcribe', 'segment'):
            done = lo + (hi - lo) * max(0.0, min(1.0, frac))
            emit('progress', stage=stage, label=label, fraction=round(min(1.0, done / span), 4))

    P.set_status = set_status
    try:
        lesson = P.process(lesson_id, do_translate=False, log=lambda m: emit('log', message=m))
    except Exception as e:  # process()가 status.json에도 남긴다
        return fail(e)
    finally:
        P.set_status = original
    d = P.lesson_dir(lesson_id)
    if not lesson or not lesson.get('sentences'):
        return fail('음성을 찾지 못했습니다. 음원 언어가 맞는지 확인해 주세요.')
    emit('progress', stage='segment', label=P.STAGES['segment'][0], fraction=1.0)
    emit('done', lesson=os.path.join(d, 'lesson.json'), audio=os.path.join(d, 'master.wav'),
         count=len(lesson['sentences']))
    return 0


def cmd_translate(args):
    lesson = P.read_json(args.lesson)
    if not lesson or not isinstance(lesson.get('sentences'), list):
        return fail('레슨 파일을 읽을 수 없습니다: %s' % args.lesson)
    emit('progress', label='Claude로 번역 중', fraction=0.0)
    try:
        P.translate(lesson['sentences'],
                    lambda f: emit('progress', label='Claude로 번역 중', fraction=round(f, 4)),
                    P.lang_of(lesson))
    except P.NotLoggedIn as e:
        return fail(e, 'not_logged_in')
    except Exception as e:
        return fail(e)
    P.write_json(args.lesson, lesson)
    emit('done', lesson=args.lesson, translated=sum(1 for s in lesson['sentences'] if s.get('ko')))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--watch-stdin', action='store_true', help='표준 입력이 닫히면 자식 프로세스까지 끝낸다')
    ap.add_argument('--model', help='Whisper 모델 경로')
    sub = ap.add_subparsers(dest='command', required=True)
    sub.add_parser('status')
    sub.add_parser('download-model')
    t = sub.add_parser('transcribe')
    t.add_argument('audio')
    t.add_argument('--lang', choices=sorted(P.LANGS), default=P.DEFAULT_LANG)
    t.add_argument('--work', required=True, help='처리 중 파일을 둘 폴더')
    t.add_argument('--title')
    tr = sub.add_parser('translate')
    tr.add_argument('lesson', help='번역을 채워 넣을 lesson.json (같은 파일에 덮어쓴다)')
    args = ap.parse_args(argv)

    if hasattr(sys.stdout, 'reconfigure'):
        sys.stdout.reconfigure(encoding='utf-8')
    P.configure(data_dir=getattr(args, 'work', None), model_path=args.model)
    if args.watch_stdin:
        try:
            os.setpgrp()   # 자식들과 한 그룹으로 묶어 함께 끝낼 수 있게
        except OSError:
            pass
        signal.signal(signal.SIGTERM, _stop_group)
        watch_stdin()
    commands = {'status': cmd_status, 'download-model': cmd_download_model,
                'transcribe': cmd_transcribe, 'translate': cmd_translate}
    try:
        return commands[args.command](args)
    except Exception as e:
        return fail(e)


if __name__ == '__main__':
    sys.exit(main())
