#!/usr/bin/env bash
# Build on macOS with Xcode. No Apple account or signing credentials are used.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null || { echo 'macOS와 Xcode가 필요합니다.' >&2; exit 1; }
LCR_IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-version)
python3 - "$LCR_IOS_SDK" <<'PY'
import sys
if tuple(map(int, sys.argv[1].split('.')[:2])) < (26, 4):
    raise SystemExit('기기 내 일반 번역 모델을 선택하려면 Xcode/iOS SDK 26.4 이상이 필요합니다.')
PY
python3 scripts/generate_ios_project.py --check
LCR_BUNDLE_ID="${LCR_BUNDLE_ID:-com.firstghrn.lcrepeater.ios}"
mkdir -p dist
xcodebuild -project ios/LCRepeater.xcodeproj -scheme LCRepeater \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios-device \
  CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER="$LCR_BUNDLE_ID" build

LCR_PAYLOAD=$(mktemp -d "${TMPDIR:-/tmp}/lcrepeater-ipa.XXXXXX")
trap 'rm -rf "$LCR_PAYLOAD"' EXIT
mkdir -p "$LCR_PAYLOAD/Payload"
ditto build/ios-device/Build/Products/Release-iphoneos/LCRepeater.app "$LCR_PAYLOAD/Payload/LCRepeater.app"
ditto -c -k --keepParent "$LCR_PAYLOAD/Payload" dist/LC-Repeater-unsigned.ipa
shasum -a 256 dist/LC-Repeater-unsigned.ipa > dist/LC-Repeater-unsigned.ipa.sha256
echo '완료: dist/LC-Repeater-unsigned.ipa (Feather에서 서명 후 설치)'
