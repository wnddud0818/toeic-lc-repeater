#!/usr/bin/env python3
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from export_lesson import export_file
from fixture import make_lesson

with tempfile.TemporaryDirectory() as folder:
    make_lesson(folder)
    export_file(folder, sys.argv[1])
