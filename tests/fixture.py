"""Synthetic, redistributable audio for the Python/Swift transfer contract tests."""
import array
import json
import math
from pathlib import Path
import sys
import wave


def make_lesson(folder):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    samples = array.array('h', (int(4000 * math.sin(2 * math.pi * 440 * i / 32000)) for i in range(64000)))
    if sys.byteorder == 'big':
        samples.byteswap()
    with wave.open(str(folder / 'master.wav'), 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(32000)
        wav.writeframes(samples.tobytes())
    lesson = {'id': 'test-lesson', 'title': '전달 확인 레슨', 'duration': 2.0, 'created': 1700000000,
              'sentences': [
                  {'i': 1, 'start': 0.0, 'end': 0.4, 'en': 'Directions.', 'ko': '안내입니다.', 'kind': 'direction'},
                  {'i': 2, 'start': 0.5, 'end': 1.5, 'en': 'Hello, world.', 'ko': '안녕하세요.', 'kind': 'content'},
              ]}
    (folder / 'lesson.json').write_text(json.dumps(lesson, ensure_ascii=False), encoding='utf-8')
    (folder / 'status.json').write_text(json.dumps({'stage': 'done'}), encoding='utf-8')
    return lesson
