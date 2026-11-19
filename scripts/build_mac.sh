#!/usr/bin/env bash
# 네이티브 맥 앱(dist/macos/LC Repeater.app) 만들기. Apple 계정이나 서명 인증서는 쓰지 않는다.
#
#   bash scripts/build_mac.sh
#
# 1. whisper.cpp의 whisper-cli와 Whisper·Claude 엔진(engine_cli.py → lcr-engine)을 만든다.
# 2. Xcode로 SwiftUI 앱(LCRepeaterMac)을 빌드하고 두 helper를 Contents/Helpers에 넣는다.
# 3. 앱 전체를 ad-hoc 서명하고 zip으로 묶는다.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null || { echo 'macOS와 Xcode가 필요합니다.' >&2; exit 1; }
[ "$(uname -m)" = arm64 ] || { echo 'Apple Silicon Mac에서 빌드해 주세요.' >&2; exit 1; }
LCR_MAC_SDK=$(xcrun --sdk macosx --show-sdk-version)
python3 - "$LCR_MAC_SDK" <<'PY'
import sys
if tuple(map(int, (sys.argv[1].split('.') + ['0'])[:2])) < (26, 4):
    raise SystemExit('Apple 기기 내 전사·번역 API를 쓰려면 Xcode/macOS SDK 26.4 이상이 필요합니다 (현재 %s).' % sys.argv[1])
PY
python3 scripts/generate_ios_project.py --check

# 1. 빌드용 파이썬 환경 (3.9 이상). 기존 맥 앱(build_app.sh)과 같은 .venv를 쓴다.
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

WHISPER_BIN=$(bash scripts/build_whisper_macos.sh "$PWD/.venv/bin" | tail -1)

# 2. Whisper·Claude 엔진: 표준 라이브러리만 쓰는 pipeline.py를 실행 파일 하나로 묶는다
.venv/bin/pyinstaller --noconfirm --clean --onefile --log-level WARN \
  --name lcr-engine --hidden-import model_download --collect-data certifi \
  --distpath build/mac-engine --workpath build/mac-engine-work --specpath build \
  engine_cli.py

# 3. SwiftUI 앱
xcodebuild -project ios/LCRepeater.xcodeproj -scheme LCRepeaterMac \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/mac-xcode ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build

APP="dist/macos/LC Repeater.app"
rm -rf dist/macos
mkdir -p dist/macos
ditto "build/mac-xcode/Build/Products/Release/LC Repeater.app" "$APP"
mkdir -p "$APP/Contents/Helpers"
cp "$WHISPER_BIN" "$APP/Contents/Helpers/whisper-cli"
cp build/mac-engine/lcr-engine "$APP/Contents/Helpers/lcr-engine"
chmod 755 "$APP/Contents/Helpers/whisper-cli" "$APP/Contents/Helpers/lcr-engine"

# 4. 안쪽 실행 파일부터 ad-hoc 서명 (Apple Silicon은 서명 없는 실행 파일을 열지 않는다)
codesign --force --sign - "$APP/Contents/Helpers/whisper-cli"
codesign --force --sign - "$APP/Contents/Helpers/lcr-engine"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# 5. 엔진이 앱 안에서 whisper-cli를 찾는지 확인
"$APP/Contents/Helpers/lcr-engine" --model /nonexistent/model.bin status | python3 -c '
import json, sys
status = json.loads(sys.stdin.read().splitlines()[-1])
assert status["event"] == "done" and status["whisper"], status
print("엔진 확인:", status)'

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
ZIP="dist/macos/LC-Repeater-macOS-${VERSION}-build${BUILD}-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd dist/macos && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "완료: $APP ($(du -sh "$APP" | cut -f1))"
echo "      $ZIP"
