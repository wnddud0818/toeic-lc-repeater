# 네이티브 맥 앱

`ios/LCRepeaterMac/`의 SwiftUI 앱. 아이폰 앱과 같은 Xcode 프로젝트(`ios/LCRepeater.xcodeproj`)의 `LCRepeaterMac` 타깃이다.

## 처리 방식

새 레슨은 **전사**와 **번역**을 따로 고른다. 네 가지 조합이 모두 된다.

| 단계 | Apple | 기존 방식 |
|---|---|---|
| 전사 | `SpeechAnalyzer` + `SpeechTranscriber` (en-US / ja-JP), 문장 나누기는 `TranscriptSegmenter` — 아이폰과 같은 코드 | `pipeline.py`의 whisper.cpp 받아쓰기와 무음 기반 문장 나누기 — PC와 같은 코드 |
| 번역 | `TranslationSession` (en/ja → ko) — 아이폰과 같은 `AppleLessonTranslator` | `pipeline.py`의 `claude -p` 번역 (인식 오류 교정, 시험 안내 문장 구분 포함) |

- Apple 전사는 앱이 음원을 32kHz 모노 WAV로 바꾼 뒤 전사한다. Whisper 전사는 엔진이 같은 형식의 `master.wav`를 만든다. 어느 쪽이든 보관함에는 같은 형식(`entry.json` + `master.wav`)으로 저장된다.
- 번역이 실패해도 받아쓰기 결과(draft)는 남는다. 같은 창에서 번역 방식을 바꿔 다시 하거나 번역 없이 저장할 수 있다.
- 플레이어의 **다시 번역**은 전체를, 번역이 빠진 문장 안내의 버튼은 빈 문장만 번역한다. 구간(시작·끝)은 번역해도 바뀌지 않는다.

## Whisper·Claude 엔진 (`lcr-engine`)

`engine_cli.py`를 PyInstaller로 묶은 실행 파일이다. 앱 안 `Contents/Helpers/`에 `whisper-cli`와 함께 들어간다. 앱은 명령을 실행하고 표준 출력의 JSON 줄을 읽는다.

```text
lcr-engine [--watch-stdin] --model <모델> status
lcr-engine [--watch-stdin] --model <모델> download-model
lcr-engine [--watch-stdin] --model <모델> transcribe <음원> --lang en|ja --work <폴더> [--title 제목]
lcr-engine [--watch-stdin] translate <lesson.json>

{"event": "progress", "label": "음성 인식 중", "fraction": 0.42}
{"event": "done", ...}
{"event": "error", "code": "not_logged_in" | "no_model" | "failed", "message": "..."}
```

- `--watch-stdin`: 앱이 연 파이프가 닫히면(취소하거나 앱이 꺼지면) 엔진이 whisper-cli·claude 자식 프로세스까지 함께 끝낸다.
- Whisper 모델은 `~/Library/Application Support/LC Repeater/models/ggml-large-v3-turbo-q5_0.bin`에 둔다. 기존 맥 앱과 같은 위치라 이미 받은 모델을 그대로 쓴다.
- `claude`는 기존과 같이 PATH, Homebrew 경로, 로그인 셸 순서로 찾는다.
- 계약은 `tests/test_engine_cli.py`가 가짜 whisper-cli·claude로 검증하고, CI는 작은 Whisper 모델(`LCR_WHISPER_DTW=tiny`)과 `say`로 만든 음성으로 앱 안의 엔진을 실제로 돌려 본다.

## 저장 위치

- 레슨: `~/Library/Application Support/LCRepeater/Lessons/<UUID>/` (아이폰 앱과 같은 형식)
- 이어 듣기 위치·설정: 앱 UserDefaults (`com.firstghrn.lcrepeater.mac`)
- 기존 맥 앱 레슨(`~/Library/Application Support/LC Repeater/data/`)은 **파일 → 이전 맥 앱 레슨 가져오기**로 한 번씩 복사한다. 원본은 지우지 않는다.

## 빌드와 개발

```bash
bash scripts/build_mac.sh
```

1. `scripts/build_whisper_macos.sh`로 whisper-cli를 빌드한다(기존 맥 앱 빌드와 공유).
2. PyInstaller로 `lcr-engine`을 만든다.
3. `xcodebuild -scheme LCRepeaterMac`로 앱을 빌드하고 helper 두 개를 넣은 뒤 전체를 ad-hoc 서명한다.
4. `dist/macos/LC-Repeater-macOS-<버전>-build<빌드>-arm64.zip`과 SHA-256 파일을 만든다.

Xcode에서 `LCRepeaterMac` 스킴으로 바로 실행하면 helper가 없어서 Apple 처리만 된다. Whisper·Claude까지 시험하려면 스킴의 환경 변수에 `LCR_ENGINE=<저장소>/engine_cli.py`를 넣는다(`/usr/bin/env python3`로 실행된다).

소스 파일을 추가·삭제하면 `python3 scripts/generate_ios_project.py`로 프로젝트를 다시 만든다. 맥 앱이 아이폰 폴더에서 함께 쓰는 파일 목록은 그 스크립트의 `MAC_SHARED`에 있다.

## 자동 빌드

`.github/workflows/macos-native.yml`이 Python·Swift 테스트, 맥 앱 빌드, 엔진 실제 전사, 앱 실행 확인을 한다. `main`에 반영되면 GitHub Releases에 `macos-v<버전>-build<빌드>-<번호>`로 올린다.
