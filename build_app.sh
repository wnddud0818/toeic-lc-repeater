#!/usr/bin/env bash
# 맥 앱(dist/LC Repeater.app) 만들기
#
#   ./build_app.sh
#
# 처음에는 빌드 도구를 .venv에 설치하고 whisper.cpp를 받아 빌드하느라 몇 분 걸린다.
# Whisper 모델은 앱에 넣지 않는다. 앱을 처음 열 때 화면에서 내려받는다.
set -euo pipefail
cd "$(dirname "$0")"

WHISPER_VERSION=v1.9.5
WHISPER_SRC=build/whisper.cpp
WHISPER_BIN=$WHISPER_SRC/build-static/bin/whisper-cli

# 1. 빌드용 파이썬 환경 (3.9 이상)
if [ ! -x .venv/bin/python ]; then
  PY=""
  for c in python3.13 python3.12 python3.11 python3.10 python3.9 python3; do
    if command -v "$c" >/dev/null && "$c" -c 'import sys; sys.exit(sys.version_info < (3, 9))'; then
      PY=$(command -v "$c"); break
    fi
  done
  [ -n "$PY" ] || { echo "Python 3.9 이상이 필요합니다 (brew install python)"; exit 1; }
  "$PY" -m venv .venv
fi
.venv/bin/pip install -q -r requirements-build.txt

# 2. 다른 라이브러리에 기대지 않는 whisper-cli (Metal 셰이더 내장)
if [ ! -x "$WHISPER_BIN" ]; then
  [ -d "$WHISPER_SRC" ] || git clone -q --depth 1 --branch "$WHISPER_VERSION" \
    https://github.com/ggml-org/whisper.cpp "$WHISPER_SRC"
  PATH="$PWD/.venv/bin:$PATH" cmake -S "$WHISPER_SRC" -B "$WHISPER_SRC/build-static" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_BLAS=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 > build/whisper-cmake.log
  PATH="$PWD/.venv/bin:$PATH" cmake --build "$WHISPER_SRC/build-static" -j 8 --target whisper-cli \
    >> build/whisper-cmake.log
fi

# 3. 아이콘
.venv/bin/python scripts/make_icon.py build/AppIcon.icns

# 4. 앱으로 묶기
.venv/bin/pyinstaller --noconfirm --clean --windowed --log-level WARN \
  --name "LC Repeater" --icon "$PWD/build/AppIcon.icns" \
  --osx-bundle-identifier com.firstghrn.lcrepeater \
  --add-data "$PWD/static:static" \
  --add-binary "$PWD/$WHISPER_BIN:bin" \
  --distpath dist --workpath build/pyinstaller --specpath build \
  app.py

echo "완료: dist/LC Repeater.app ($(du -sh "dist/LC Repeater.app" | cut -f1))"
