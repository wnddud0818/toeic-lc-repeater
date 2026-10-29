#!/usr/bin/env python3
"""Export a processed lesson as one streaming, versioned .lcrlesson document.

    python3 export_lesson.py data/<lesson-id> -o lesson.lcrlesson

No model, translation service, or third-party package is needed for export.
The format is documented in docs/ios-transfer.md and read by LessonArchive.swift.
"""
import argparse
import contextlib
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import tempfile
import wave

MAGIC = b'LCRLESS1'
MAX_MANIFEST = 8 * 1024 * 1024
MAX_AUDIO = 2 * 1024 ** 3
CHUNK = 1024 * 1024


class ExportError(ValueError):
    pass


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate_lesson(lesson, audio_duration):
    if not isinstance(lesson, dict):
        raise ExportError('레슨 형식이 잘못되었습니다')
    if not all(isinstance(lesson.get(k), str) and lesson[k].strip() for k in ('id', 'title')):
        raise ExportError('레슨 이름과 ID가 필요합니다')
    duration = lesson.get('duration')
    if not _number(duration) or duration <= 0 or abs(duration - audio_duration) > 0.05:
        raise ExportError('레슨과 음원의 길이가 일치하지 않습니다')
    if not _number(lesson.get('created')):
        raise ExportError('레슨 생성 시각이 잘못되었습니다')
    sentences = lesson.get('sentences')
    if not isinstance(sentences, list) or not 1 <= len(sentences) <= 50000:
        raise ExportError('내보낼 문장이 없거나 너무 많습니다')
    seen = set()
    for sentence in sentences:
        if not isinstance(sentence, dict):
            raise ExportError('문장 형식이 잘못되었습니다')
        i = sentence.get('i')
        if type(i) is not int or i < 1 or i in seen:
            raise ExportError('문장 번호가 잘못되었거나 중복되었습니다')
        seen.add(i)
        a, b = sentence.get('start'), sentence.get('end')
        if not (_number(a) and _number(b) and 0 <= a < b <= duration + 0.001 and b - a <= 120):
            raise ExportError('문장 %d의 구간이 잘못되었습니다 (최대 120초)' % i)
        if not all(isinstance(sentence.get(k), str) for k in ('en', 'ko')):
            raise ExportError('문장 %d의 텍스트가 잘못되었습니다' % i)
        if sentence.get('kind') not in ('content', 'direction'):
            raise ExportError('문장 %d의 종류가 잘못되었습니다' % i)


@contextlib.contextmanager
def prepare_export(lesson_dir):
    """Yield (header + manifest, open WAV) without loading the audio into memory."""
    folder = Path(lesson_dir)
    try:
        status_path = folder / 'status.json'
        if status_path.exists():
            status = json.loads(status_path.read_text(encoding='utf-8'))
            if not isinstance(status, dict) or status.get('stage') != 'done':
                raise ExportError('레슨 처리가 끝난 뒤 내보내 주세요')
        lesson_path = folder / 'lesson.json'
        if lesson_path.stat().st_size > MAX_MANIFEST:
            raise ExportError('레슨 정보가 너무 큽니다')
        lesson = json.loads(lesson_path.read_text(encoding='utf-8'))
        with (folder / 'master.wav').open('rb') as audio:
            byte_count = os.fstat(audio.fileno()).st_size
            if not 44 <= byte_count <= MAX_AUDIO:
                raise ExportError('음원 크기는 2GB 이하여야 합니다')
            with wave.open(audio, 'rb') as wav:
                if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (1, 2, 32000, 'NONE'):
                    raise ExportError('32kHz 모노 16비트 PCM WAV 음원이 필요합니다')
                validate_lesson(lesson, wav.getnframes() / float(wav.getframerate()))
            audio.seek(0)
            digest = hashlib.sha256()
            for chunk in iter(lambda: audio.read(CHUNK), b''):
                digest.update(chunk)
            manifest = {
                'format': 'toeic-lc-repeater.lesson', 'version': 1,
                'lesson': lesson,
                'audio': {'format': 'wav', 'byte_count': byte_count, 'sha256': digest.hexdigest(),
                          'sample_rate': 32000, 'channels': 1, 'sample_width': 2},
            }
            encoded = json.dumps(manifest, ensure_ascii=False, allow_nan=False,
                                 separators=(',', ':')).encode('utf-8')
            if len(encoded) > MAX_MANIFEST:
                raise ExportError('레슨 정보가 너무 큽니다')
            audio.seek(0)
            yield MAGIC + struct.pack('<Q', len(encoded)) + encoded, audio
    except (OSError, wave.Error, EOFError, json.JSONDecodeError) as exc:
        raise ExportError('레슨을 읽을 수 없습니다: %s' % exc) from exc


def export_file(lesson_dir, destination):
    """Atomically replace a destination only after a complete export."""
    destination = Path(destination)
    if destination.resolve() in {(Path(lesson_dir) / n).resolve() for n in
                                 ('master.wav', 'lesson.json', 'status.json', 'meta.json', 'whisper.json')}:
        raise ExportError('레슨 원본 파일을 내보내기 대상으로 지정할 수 없습니다')
    destination.parent.mkdir(parents=True, exist_ok=True)
    temp = None
    try:
        with prepare_export(lesson_dir) as (prefix, audio):
            with tempfile.NamedTemporaryFile(dir=destination.parent, suffix='.part', delete=False) as out:
                temp = Path(out.name)
                out.write(prefix)
                shutil.copyfileobj(audio, out, CHUNK)
            os.replace(str(temp), str(destination))
    finally:
        if temp is not None:
            _remove_temp(temp)
    return destination


def _remove_temp(path):
    try:
        path.unlink()
    except FileNotFoundError:
        pass


def main():
    parser = argparse.ArgumentParser(description='아이폰에서 가져올 레슨 파일 만들기')
    parser.add_argument('lesson_dir', type=Path, help='lesson.json과 master.wav가 있는 폴더')
    parser.add_argument('-o', '--output', type=Path, required=True, help='저장할 .lcrlesson 파일')
    args = parser.parse_args()
    try:
        result = export_file(args.lesson_dir, args.output)
    except ExportError as exc:
        parser.exit(1, '내보내기 실패: %s\n' % exc)
    print('완료: %s' % result)


if __name__ == '__main__':
    main()
