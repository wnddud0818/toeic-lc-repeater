#!/usr/bin/env bash
# whisper.cpp의 whisper-cli를 다른 라이브러리에 기대지 않는 실행 파일로 빌드한다 (Metal 셰이더 내장).
# build_app.sh(기존 맥 앱)와 scripts/build_mac.sh(네이티브 맥 앱)가 함께 쓴다.
#
#   scripts/build_whisper_macos.sh [cmake가 있는 PATH 앞부분]
#
# 결과: build/whisper.cpp/build-static/bin/whisper-cli
set -euo pipefail
cd "$(dirname "$0")/.."

WHISPER_VERSION=v1.9.5
WHISPER_SRC=build/whisper.cpp
WHISPER_BIN=$WHISPER_SRC/build-static/bin/whisper-cli
[ -n "${1:-}" ] && export PATH="$1:$PATH"

if [ ! -x "$WHISPER_BIN" ]; then
  mkdir -p build
  [ -d "$WHISPER_SRC" ] || git clone -q --depth 1 --branch "$WHISPER_VERSION" \
    https://github.com/ggml-org/whisper.cpp "$WHISPER_SRC"
  cmake -S "$WHISPER_SRC" -B "$WHISPER_SRC/build-static" \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_BLAS=ON \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 > build/whisper-cmake.log
  cmake --build "$WHISPER_SRC/build-static" -j 8 --target whisper-cli >> build/whisper-cmake.log
fi
echo "$WHISPER_BIN"
