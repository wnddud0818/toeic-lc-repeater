"""Exercise the installed x64 executable, bundled tools and native WebView2 UI."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT), str(ROOT / 'tests')]
from fixture import make_lesson
import pipeline as P


def run(executable):
    tools = executable.parent / '_internal' / 'bin'
    for name in ('ffmpeg.exe', 'whisper-cli.exe'):
        assert (tools / name).is_file(), name
    with tempfile.TemporaryDirectory(prefix='lcr-windows-', ignore_cleanup_errors=True) as folder:
        root = Path(folder) / '한글 경로'
        data = root / 'data' / 'test-lesson'
        lesson = make_lesson(data)
        lesson['sentences'][1]['end'] = 1.2
        lesson['sentences'].append({'i': 3, 'start': 1.2, 'end': 2.0,
                                    'en': 'Please try again.', 'ko': '다시 해 보세요.', 'kind': 'content'})
        (data / 'lesson.json').write_text(json.dumps(lesson), encoding='utf-8')
        P.AFCONVERT = None
        P.FFMPEG = str(tools / 'ffmpeg.exe')
        converted = root / '변환.wav'
        P.decode(str(data / 'master.wav'), str(converted), 16000)
        with wave.open(str(converted)) as audio:
            assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2)
        aac = root / '입력.m4a'
        subprocess.run([P.FFMPEG, '-nostdin', '-y', '-loglevel', 'error', '-i', str(converted),
                        '-c:a', 'aac', str(aac)], check=True)
        P.decode(str(aac), str(root / '다시.wav'), 32000)
        with wave.open(str(root / '다시.wav')) as audio:
            assert audio.getframerate() == 32000 and audio.getnframes() > 0
        # A real tiny-model inference checks the native CPU binary and its runtime.
        # The user's large-v3-turbo model is downloaded by the UI on first use.
        model = root / 'ggml-tiny.en.bin'
        speech = root / 'speech.wav'
        urllib.request.urlretrieve('https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin', model)
        urllib.request.urlretrieve('https://raw.githubusercontent.com/ggml-org/whisper.cpp/v1.9.5/samples/jfk.wav', speech)
        prefix = root / 'transcript'
        subprocess.run([str(tools / 'whisper-cli.exe'), '-m', str(model), '-f', str(speech),
                        '-l', 'en', '-ng', '-nfa', '-dtw', 'tiny.en', '-ojf', '-of', str(prefix)],
                       check=True, timeout=180)
        transcript = json.loads(prefix.with_suffix('.json').read_text(encoding='utf-8'))
        assert any(s.get('text', '').strip() for s in transcript['transcription']), transcript
        report = root / 'ui-result.json'
        env = dict(os.environ, LCR_SUPPORT_DIR=str(root))
        process = subprocess.Popen([str(executable), '--smoke-test', str(report)], env=env)
        try:
            assert process.wait(timeout=90) == 0
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            if (root / 'app.log').exists():
                print((root / 'app.log').read_text(encoding='utf-8', errors='replace'))
        result = json.loads(report.read_text(encoding='utf-8'))
        assert result.get('ok'), result
        destination = ROOT / 'dist' / 'windows-smoke-result.json'
        destination.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        print('Installed app, Unicode paths, WAV/AAC conversion, Whisper inference, WebView2 card/clip/export checks passed')


if __name__ == '__main__':
    run(Path(sys.argv[1]).resolve())
