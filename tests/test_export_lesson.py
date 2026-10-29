import hashlib
import http.client
import json
from pathlib import Path
import struct
import tempfile
import threading
import unittest
from unittest.mock import patch

import export_lesson as E
import server
from fixture import make_lesson


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.folder = self.root / 'test-lesson'
        self.lesson = make_lesson(self.folder)

    def test_export_preserves_metadata_and_audio_with_valid_checksum(self):
        output = E.export_file(self.folder, self.root / 'export.lcrlesson')
        data = output.read_bytes()
        self.assertEqual(data[:8], E.MAGIC)
        length, = struct.unpack('<Q', data[8:16])
        manifest = json.loads(data[16:16 + length])
        audio = data[16 + length:]
        self.assertEqual(manifest['version'], 1)
        self.assertEqual(manifest['lesson'], self.lesson)
        self.assertEqual(audio, (self.folder / 'master.wav').read_bytes())
        self.assertEqual(manifest['audio']['byte_count'], len(audio))
        self.assertEqual(manifest['audio']['sha256'], hashlib.sha256(audio).hexdigest())

    def test_incomplete_lesson_does_not_replace_existing_destination(self):
        output = self.root / 'export.lcrlesson'
        output.write_bytes(b'existing download')
        (self.folder / 'status.json').write_text('{"stage":"translate"}')
        with self.assertRaises(E.ExportError):
            E.export_file(self.folder, output)
        self.assertEqual(output.read_bytes(), b'existing download')
        self.assertEqual(list(self.root.glob('*.part')), [])

    def test_failed_write_preserves_previous_file_and_cleans_staging(self):
        output = self.root / 'export.lcrlesson'
        output.write_bytes(b'existing download')
        with patch.object(E.shutil, 'copyfileobj', side_effect=OSError('disk full')):
            with self.assertRaises(E.ExportError):
                E.export_file(self.folder, output)
        self.assertEqual(output.read_bytes(), b'existing download')
        self.assertEqual(list(self.root.glob('*.part')), [])

    def test_rejects_corrupt_ranges_duplicate_ids_and_nonfinite_values(self):
        for mutation in ('range', 'duplicate', 'nan', 'duration'):
            with self.subTest(mutation=mutation):
                lesson = json.loads(json.dumps(self.lesson))
                if mutation == 'range': lesson['sentences'][0]['end'] = 9
                if mutation == 'duplicate': lesson['sentences'][1]['i'] = 1
                if mutation == 'nan': lesson['sentences'][0]['start'] = float('nan')
                if mutation == 'duration': lesson['duration'] = 3
                with self.assertRaises(E.ExportError):
                    E.validate_lesson(lesson, 2.0)

    def test_export_cannot_overwrite_source_audio(self):
        before = (self.folder / 'master.wav').read_bytes()
        with self.assertRaises(E.ExportError):
            E.export_file(self.folder, self.folder / 'master.wav')
        self.assertEqual(before, (self.folder / 'master.wav').read_bytes())

    def test_http_download_head_and_busy_status(self):
        old_dir = server.P.DATA_DIR
        server.P.DATA_DIR = str(self.root)
        self.addCleanup(setattr, server.P, 'DATA_DIR', old_dir)
        httpd = server.make_server('127.0.0.1', 0)
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        connection = http.client.HTTPConnection('127.0.0.1', httpd.server_port)
        self.addCleanup(connection.close)
        connection.request('GET', '/api/lessons/test-lesson/export')
        response = connection.getresponse()
        data = response.read()
        self.assertEqual(response.status, 200)
        self.assertEqual(len(data), int(response.getheader('Content-Length')))
        self.assertIn('test-lesson.lcrlesson', response.getheader('Content-Disposition'))
        connection.request('HEAD', '/api/lessons/test-lesson/export')
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), b'')
        self.assertEqual(int(response.getheader('Content-Length')), len(data))
        (self.folder / 'status.json').write_text('{"stage":"transcribe"}')
        connection.request('GET', '/api/lessons/test-lesson/export')
        response = connection.getresponse()
        self.assertEqual(response.status, 409)
        response.read()


if __name__ == '__main__':
    unittest.main()
