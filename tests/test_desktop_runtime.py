import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import desktop_runtime as R
import pipeline as P


class DesktopRuntimeTests(unittest.TestCase):
    def test_user_data_is_outside_installation_on_each_platform(self):
        self.assertEqual(R.support_dir('win32', {'LOCALAPPDATA': 'local-data'}, 'user'),
                         os.path.join('local-data', 'LC Repeater'))
        self.assertEqual(R.support_dir('win32', {}, 'user'),
                         os.path.join('user', 'AppData', 'Local', 'LC Repeater'))
        self.assertEqual(R.support_dir('darwin', {}, 'user'),
                         os.path.join('user', 'Library', 'Application Support', 'LC Repeater'))
        self.assertEqual(R.support_dir('win32', {'LCR_SUPPORT_DIR': 'isolated'}, 'user'), 'isolated')

    def test_windows_bundle_tools_do_not_require_path_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            tool = Path(folder, 'bin', 'whisper-cli.exe')
            tool.parent.mkdir()
            tool.touch()
            with patch.object(P, 'BUNDLE_DIR', folder), patch.object(P.sys, 'platform', 'win32'):
                self.assertEqual(P.bundled_bin('whisper-cli'), str(tool))
                self.assertIsNone(P.bundled_bin('missing'))

    def test_native_claude_installation_is_found_without_shell(self):
        with patch.object(P.sys, 'platform', 'win32'), \
             patch.object(P.os.path, 'expanduser', return_value='native-bin'), \
             patch.object(P.os.path, 'isfile', side_effect=lambda p: p == os.path.join('native-bin', 'claude.exe')), \
             patch.object(P.shutil, 'which') as which:
            self.assertEqual(P.find_bin('claude', 'LCR_UNUSED_TEST_BIN', True), os.path.join('native-bin', 'claude.exe'))
            which.assert_not_called()

    def test_npm_claude_shim_is_run_as_node_without_cmd_interpretation(self):
        with tempfile.TemporaryDirectory() as folder:
            entry = Path(folder, 'node_modules', '@anthropic-ai', 'claude-code', 'cli.js')
            entry.parent.mkdir(parents=True)
            entry.touch()
            with patch.object(P.sys, 'platform', 'win32'), patch.object(P.shutil, 'which', return_value='node.exe'):
                self.assertEqual(P.claude_command(os.path.join(folder, 'claude.cmd')), ['node.exe', str(entry)])
            with patch.object(P.sys, 'platform', 'win32'), patch.object(P.shutil, 'which', return_value=None):
                with self.assertRaises(P.NotLoggedIn):
                    P.claude_command(os.path.join(folder, 'claude.cmd'))

    def test_windows_children_have_no_console(self):
        with patch.object(R.sys, 'platform', 'win32'), \
             patch.object(subprocess, 'CREATE_NO_WINDOW', 0x08000000, create=True):
            self.assertEqual(R.child_process_options(), {'creationflags': 0x08000000})
        with patch.object(R.sys, 'platform', 'darwin'):
            self.assertEqual(R.child_process_options(), {})

    def test_decode_surfaces_ffmpeg_diagnostics(self):
        failure = subprocess.CompletedProcess([], 1, stdout='cannot decode input')
        with patch.object(P, 'AFCONVERT', None), patch.object(P, 'FFMPEG', 'ffmpeg'), \
             patch.object(P.subprocess, 'run', return_value=failure):
            with self.assertRaisesRegex(RuntimeError, 'cannot decode input'):
                P.decode('input.mp3', 'output.wav', 32000)


if __name__ == '__main__':
    unittest.main()
