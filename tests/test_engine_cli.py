"""The JSON-lines contract that the native Mac app relies on (engine_cli.py)."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

from fixture import make_lesson

ROOT = Path(__file__).resolve().parents[1]

FAKE_WHISPER = textwrap.dedent('''\
    #!%s
    import json, sys
    args = sys.argv[1:]
    prefix = args[args.index('-of') + 1]
    lang = args[args.index('-l') + 1]
    text = [' Hello,', ' world.'] if lang == 'en' else ['こんにちは', '。']
    tokens = [{'text': t, 'offsets': {'from': 100 + 300 * k}, 't_dtw': 25 + 30 * k} for k, t in enumerate(text)]
    sys.stderr.write('whisper_print_progress_callback: progress =  50%%\\n')
    with open(prefix + '.json', 'w', encoding='utf-8') as f:
        json.dump({'transcription': [{'offsets': {'from': 100, 'to': 1500}, 'tokens': tokens}]}, f)
''') % sys.executable


def events(stdout):
    return [json.loads(line) for line in stdout.splitlines() if line.strip()]


@unittest.skipUnless(shutil.which('ffmpeg') or shutil.which('afconvert'), 'needs ffmpeg or afconvert')
class EngineCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.whisper = self.root / 'whisper-cli'
        self.whisper.write_text(FAKE_WHISPER)
        self.whisper.chmod(0o755)
        self.model = self.root / 'model.bin'
        self.model.write_bytes(b'lmgg')
        make_lesson(self.root / 'src')
        self.audio = self.root / 'src' / 'master.wav'

    def run_cli(self, *args, env=None):
        environ = dict(os.environ, WHISPER_BIN=str(self.whisper), **(env or {}))
        return subprocess.run([sys.executable, str(ROOT / 'engine_cli.py'), '--model', str(self.model)] + list(args),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                              encoding='utf-8', env=environ, cwd=str(ROOT), timeout=60)

    def test_status_reports_tools_and_model(self):
        proc = self.run_cli('status')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = events(proc.stdout)[-1]
        self.assertEqual(result['event'], 'done')
        self.assertTrue(result['whisper'])
        self.assertTrue(result['model']['ready'])
        self.assertEqual(result['model']['path'], str(self.model))

    def test_transcribe_japanese_produces_lesson_and_player_audio(self):
        work = self.root / 'work'
        proc = self.run_cli('transcribe', str(self.audio), '--lang', 'ja', '--work', str(work), '--title', '일본어')
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        out = events(proc.stdout)
        progress = [e['fraction'] for e in out if e['event'] == 'progress']
        self.assertTrue(progress and progress == sorted(progress) and progress[-1] == 1.0, progress)
        done = out[-1]
        self.assertEqual(done['event'], 'done')
        lesson = json.loads(Path(done['lesson']).read_text(encoding='utf-8'))
        self.assertEqual(lesson['lang'], 'ja')
        self.assertEqual(lesson['title'], '일본어')
        self.assertEqual([s['en'] for s in lesson['sentences']], ['こんにちは。'])
        self.assertTrue(all(s['ko'] == '' for s in lesson['sentences']))
        self.assertTrue(Path(done['audio']).is_file())

    def test_transcribe_without_model_is_a_coded_error(self):
        self.model.unlink()
        proc = self.run_cli('transcribe', str(self.audio), '--work', str(self.root / 'w'))
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(events(proc.stdout)[-1]['code'], 'no_model')

    def test_translate_when_claude_is_logged_out_is_a_coded_error_and_leaves_file(self):
        fake_claude = self.root / 'claude'
        fake_claude.write_text('#!/bin/sh\ncat >/dev/null\n'
                               'echo \'{"is_error": true, "result": "Not logged in · Please run /login"}\'\nexit 1\n')
        fake_claude.chmod(0o755)
        lesson_path = self.root / 'src' / 'lesson.json'
        before = lesson_path.read_bytes()
        proc = self.run_cli('translate', str(lesson_path), env={'CLAUDE_BIN': str(fake_claude)})
        self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
        self.assertEqual(events(proc.stdout)[-1]['code'], 'not_logged_in')
        self.assertEqual(lesson_path.read_bytes(), before)

    def test_translate_writes_claude_results_back(self):
        fake_claude = self.root / 'claude'
        fake_claude.write_text(textwrap.dedent('''\
            #!%s
            import json, sys
            rows = [line.split('\\t', 1) for line in sys.stdin.read().splitlines() if line]
            result = [{'i': int(i), 'en': text, 'ko': '번역 ' + i, 'kind': 'content'} for i, text in rows]
            print(json.dumps({'result': json.dumps(result, ensure_ascii=False), 'is_error': False}))
        ''') % sys.executable)
        fake_claude.chmod(0o755)
        lesson_path = self.root / 'src' / 'lesson.json'
        proc = self.run_cli('translate', str(lesson_path), env={'CLAUDE_BIN': str(fake_claude)})
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        lesson = json.loads(lesson_path.read_text(encoding='utf-8'))
        self.assertEqual([s['ko'] for s in lesson['sentences']], ['번역 1', '번역 2'])
        self.assertEqual(events(proc.stdout)[-1], {'event': 'done', 'lesson': str(lesson_path), 'translated': 2})

    def test_closing_stdin_stops_the_engine(self):
        slow = self.root / 'slow-whisper'
        slow.write_text('#!/bin/sh\nsleep 30\n')
        slow.chmod(0o755)
        proc = subprocess.Popen([sys.executable, str(ROOT / 'engine_cli.py'), '--watch-stdin', '--model', str(self.model),
                                 'transcribe', str(self.audio), '--work', str(self.root / 'slow')],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env=dict(os.environ, WHISPER_BIN=str(slow)), cwd=str(ROOT))
        for line in proc.stdout:   # wait until whisper is running
            if b'"transcribe"' in line:
                break
        proc.stdin.close()
        self.assertNotEqual(proc.wait(timeout=10), 0)
        proc.stdout.close()


if __name__ == '__main__':
    unittest.main()
