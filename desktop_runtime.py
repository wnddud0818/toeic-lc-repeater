"""Desktop paths and child-process settings shared by the macOS/Windows app."""
import os
import subprocess
import sys


def support_dir(platform=None, environ=None, home=None):
    platform = sys.platform if platform is None else platform
    environ = os.environ if environ is None else environ
    home = os.path.expanduser('~') if home is None else home
    if environ.get('LCR_SUPPORT_DIR'):
        return environ['LCR_SUPPORT_DIR']
    if platform == 'win32':
        base = environ.get('LOCALAPPDATA') or os.path.join(home, 'AppData', 'Local')
    elif platform == 'darwin':
        base = os.path.join(home, 'Library', 'Application Support')
    else:
        base = environ.get('XDG_DATA_HOME') or os.path.join(home, '.local', 'share')
    return os.path.join(base, 'LC Repeater')


def child_process_options():
    """Do not flash a console for FFmpeg, Whisper or Claude in the Windows GUI."""
    return {'creationflags': subprocess.CREATE_NO_WINDOW} if sys.platform == 'win32' else {}
