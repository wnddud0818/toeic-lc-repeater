#!/usr/bin/env bash
# Run in MSYS2 MINGW64. Source is checked out at the pinned release by CI.
set -euo pipefail
LCR_REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
LCR_FFMPEG_SOURCE="$LCR_REPO_DIR/build/ffmpeg-src"
mkdir -p "$LCR_REPO_DIR/build/ffmpeg-build" "$LCR_REPO_DIR/build/windows-tools/licenses"
cd "$LCR_REPO_DIR/build/ffmpeg-build"
"$LCR_FFMPEG_SOURCE/configure" \
  --prefix="$LCR_REPO_DIR/build/ffmpeg-install" \
  --disable-shared --enable-static --disable-debug --disable-doc --enable-small \
  --disable-network --disable-autodetect --disable-everything --disable-programs \
  --enable-ffmpeg --disable-avdevice --disable-swscale \
  --disable-x86asm --disable-inline-asm --enable-w32threads --extra-ldflags=-static \
  --enable-protocol=file,pipe --enable-demuxer=aac,flac,mov,mp3,ogg,wav,asf \
  '--enable-decoder=aac*,alac,flac,mp3*,opus,vorbis,pcm_*,adpcm_*,wmav1,wmav2' \
  --enable-parser=aac,aac_latm,flac,mpegaudio,opus,vorbis \
  --enable-encoder=pcm_s16le,aac --enable-muxer=wav,ipod \
  --enable-filter=abuffer,abuffersink,aresample,aformat,anull,atrim
make -j 4
make install
cp "$LCR_REPO_DIR/build/ffmpeg-install/bin/ffmpeg.exe" "$LCR_REPO_DIR/build/windows-tools/ffmpeg.exe"
cp "$LCR_FFMPEG_SOURCE/COPYING.LGPLv2.1" "$LCR_REPO_DIR/build/windows-tools/licenses/FFmpeg-LGPL-2.1.txt"
cp "$LCR_REPO_DIR/scripts/build_ffmpeg_windows.sh" "$LCR_REPO_DIR/build/windows-tools/licenses/FFmpeg-build.sh"
tar -C "$LCR_FFMPEG_SOURCE" --exclude=.git -cJf \
  "$LCR_REPO_DIR/build/windows-tools/licenses/ffmpeg-9.0.2-source.tar.xz" .
"$LCR_REPO_DIR/build/windows-tools/ffmpeg.exe" -version
