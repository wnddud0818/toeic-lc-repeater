# 아이폰에서 음원 전사·번역하기

앱 시작 화면에서 두 가지 경로를 선택한다.

- **컴퓨터에서 불러오기**: 기존 `.lcrlesson` 가져오기와 보관함·반복 재생을 사용한다. iOS 17 이상을 유지한다.
- **기기에서 시작하기**: 파일 앱에서 영어 음원을 선택해 애플 모델로 전사·문장 분리·영어→한국어 번역을 수행한다. iOS 26 이상과 `SpeechTranscriber` 지원 기기가 필요하다.

기기 처리 레슨도 같은 보관함에 저장하고, 기존 블러 카드·반복·속도·구간 조절로 학습한다.
시작 화면의 **내 레슨 보기**에서 기존 레슨을 다시 열 수 있다. 파일 앱에서 `.lcrlesson`을 열면 기존 가져오기 경로로 연결한다.

## 사용 순서

1. **기기에서 시작하기**를 선택한다. 앱이 영어 전사와 영한 번역의 기기·언어 지원을 확인한다.
2. **음원 선택하기**로 MP3·M4A·WAV 등의 파일을 고른다.
3. 앱이 먼저 선택한 파일을 읽고 음원을 준비한다. 필요한 번역 언어 다운로드에 동의한다. 영어 전사 모델도 필요하면 시스템이 다운로드한다.
4. 영어 전사 → 문장 분리 → 한국어 번역 → 저장 순서로 진행한다. 처리 중에는 앱을 열어 둔다.
5. 완료되면 새 레슨의 플레이어가 열린다. 모델이 준비되어 있으면 오프라인으로 처리할 수 있다.

번역 도중 실패하거나 취소해도 화면을 닫기 전까지 전사 결과·완료된 번역을 유지하며 **번역 다시 시도**가 가능하다.
닫거나 다른 파일을 고르면 저장하지 않은 작업을 정리한다. 앱이 강제 종료된 작업은 다음 실행 때 정리하며 작업 재개는 지원하지 않는다.
완료된 레슨은 기존 가져온 레슨과 마찬가지로 앱 데이터에 보관한다.

파일 선택은 UIKit의 문서 선택기를 사용하고 오디오 파일만 허용한다. 선택한 파일을 로컬 사본으로 가져온 뒤,
선택창이 닫힌 후에 처리를 시작한다. AVFoundation으로 실제 내용을 읽어 확인하며 읽을 수 없는 음원은 모델 다운로드 전에 오류를 표시한다.

## 모델과 처리

- 전사: `SpeechAnalyzer` + `SpeechTranscriber`, 영어(en-US), 최종 결과와 오디오 시간 정보 사용.
- 번역: `TranslationSession`, 영어(en) → 한국어(ko), 문장 ID를 사용한 배치 번역.
- Apple Intelligence·Foundation Models·Claude CLI·외부 AI API는 사용하지 않는다.
- iOS 26.4 이상은 번역 세션과 지원 언어 확인에 `.lowLatency`를 명시해 일반 번역 모델을 선택한다. 그 이전 OS는 기존 일반 번역 API를 사용한다.
- 음원은 AVFoundation으로 스트리밍 변환하여 32kHz·모노·PCM16 WAV로 저장한다. 외부 FFmpeg·Whisper 모델을 앱에 추가하지 않는다.
- 파일 입력만 사용하므로 마이크 권한을 요청하지 않는다. 클라우드 Speech API인 `SFSpeechRecognizer`로 대체하지 않는다.
- 전사 시간 정보·문장부호·쉼으로 반복 구간을 만든다. 한 타임스탬프가 여러 단어를 포함하면 시간을 나누어 추정한다. 안내문 구분은 간단한 규칙을 사용하며 LLM의 오인식 교정은 제공하지 않는다.
- 원본 최대 1GiB, 변환된 WAV 최대 2GiB. 용량이 크거나 장시간인 음원은 처리 시간·여유 공간이 더 필요하다.

애플은 `SpeechTranscriber`의 고정 지원 기종 목록 대신 `isAvailable` 검사를 안내한다.
지원되지 않는 기기·언어·OS에는 이유와 컴퓨터 가져오기 경로를 보여 준다. 시뮬레이터의 전사 모델 미지원도 정상적으로 처리한다.

## 빌드·검증

Xcode/iOS SDK 26.4 이상으로 빌드한다. 가져오기·재생의 앱 최소 OS는 iOS 17로 유지한다.
GitHub Actions는 macOS 26에서 실제 기기용 IPA와 시뮬레이터 앱을 컴파일한다.

자동 검증은 문장 시간·분리 규칙·번역 ID 매칭의 Swift 테스트, 기존 Python→Swift 가져오기 계약,
시뮬레이터의 시작 화면·기존 가져오기·오디오 변환·로컬 레슨 저장·재생 파일 열기를 포함한다.
로컬 파이프라인 검사에서는 합성 음원과 고정 전사·번역 문장을 사용하며, 실제 모델 추론 성공으로 취급하지 않는다.

실기기에서는 최초 모델 다운로드, 실제 토익 음원의 전사·번역 품질, 처리 취소·재시도, 비행기 모드 처리,
긴 음원의 발열·소요 시간과 화면 잠금/백그라운드 전환을 확인해야 한다. CI는 실기기 모델 실행을 검증하지 않는다.

공식 API 근거:

- [SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber)
- [TranslationSession](https://developer.apple.com/documentation/translation/translationsession)
- [일반 모델과 Apple Intelligence 모델의 구분](https://developer.apple.com/documentation/translation/translationsession/configuration/init(source:target:preferredstrategy:))
