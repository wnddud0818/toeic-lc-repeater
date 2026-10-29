# SwiftUI 아이폰 앱과 PC → 아이폰 전달

## 첫 버전의 결정

음성 인식·문장 분리·번역은 기존 PC 파이프라인에서 처리하고, 아이폰은 가져온 레슨을 오프라인으로 재생한다. 앱 설치 파일과 학습 자료의 전달을 분리한다.

| 대상 | 전달 경로 | 이유 |
|---|---|---|
| 아이폰 앱 | macOS/Xcode 또는 GitHub Actions → unsigned IPA → Feather에서 서명·설치 | 판매자에게 앱 소스·음원·계정 정보를 전달할 필요가 없다. |
| 레슨 | PC에서 `.lcrlesson` 내보내기 → AirDrop/iCloud Drive/파일 공유 → 앱에서 가져오기 | 서버 주소·로그인·상시 실행 중인 맥 없이 사용한다. |
| 향후 선택지 | 같은 와이파이에서 레슨 다운로드, 클라우드 동기화 | 필요하면 추가할 수 있지만 첫 버전에는 계정·서버·네트워크 권한을 요구하지 않는다. |

‘PC에서 만들기’는 현재 지원되는 맥 파이프라인으로 레슨을 처리한다는 뜻이다. **내보내기 도구 자체는 Python 표준 라이브러리만 사용**하므로 처리된 폴더가 있으면 Windows/Linux에서도 실행할 수 있다. SwiftUI 앱의 컴파일에는 macOS/Xcode가 필요하다. Windows PC에서도 GitHub Actions의 macOS 빌드 결과를 내려받을 수 있다.

## 레슨 옮기기

1. 업데이트한 맥 앱/웹 플레이어에서 처리가 끝난 레슨을 연다.
2. **아이폰용 레슨 내보내기**를 눌러 `.lcrlesson` 파일을 저장한다.
3. Mac이면 AirDrop 또는 iCloud Drive, 다른 PC면 iCloud Drive 등으로 아이폰 ‘파일’ 앱에 전달한다.
4. 아이폰 LC Repeater의 **가져오기**에서 파일을 고른다. 파일의 공유/열기 메뉴로 앱에 전달해도 된다.
5. 가져오기가 끝나면 원본 PC 연결 없이 학습한다. 가져오는 동안에는 앱을 열어 둔다.

기존 데이터 폴더를 직접 내보낼 수도 있다.

```bash
python3 export_lesson.py "data/<레슨-id>" -o "output/lesson.lcrlesson"

# 기존 맥 앱 데이터는 이 경로에 있다.
python3 export_lesson.py \
  "$HOME/Library/Application Support/LC Repeater/data/<레슨-id>" \
  -o "output/lesson.lcrlesson"
```

내보내기는 `lesson.json`, `master.wav`, 완료 상태만 읽는다. 모델·Claude 로그인·원본 MP3는 필요하지 않다. 번역이 실패한 완료 레슨도 영어와 빈 번역으로 내보낼 수 있다.

## 앱 빌드와 Feather 설치

### Mac에서 빌드

Xcode 16 이상, iOS 17 이상을 기준으로 한다. 별도 Swift 패키지 의존성은 없다.

```bash
bash scripts/build_ios.sh
```

`dist/LC-Repeater-unsigned.ipa`가 만들어진다. Xcode 프로젝트를 열어 실행할 수도 있다.

```bash
open ios/LCRepeater.xcodeproj
```

### GitHub에서 빌드

`.github/workflows/ios.yml`은 관련 브랜치 푸시/PR 및 수동 실행을 지원한다. Actions에서 성공한 실행의 **LC-Repeater-iOS-unsigned** 아티팩트 ZIP을 다운로드하고, 압축을 풀어 IPA를 꺼낸다. 이 ZIP 자체를 Feather에 넣는 것은 아니다.

빌드에는 Apple 로그인·인증서·UDID가 필요하지 않다. 사용자 인증서를 GitHub Secrets나 저장소에 올리지 않는다. 워크플로는 Swift/Python 계약 테스트, 실제 iPhone용 컴파일, 시뮬레이터 컴파일·실행·레슨 가져오기 및 음원 열기를 수행한다. 시뮬레이터 검증은 Python으로 만든 합성 음원을 사용하며, 가져오기용 실행 인자는 Debug 빌드에만 포함된다.

### Feather에서 설치

1. 아이폰의 Feather에 유효한 `.p12`와 아이폰 UDID가 포함된 `.mobileprovision`을 가져온다.
2. `LC-Repeater-unsigned.ipa`를 가져온다.
3. 해당 인증서로 서명하고 설치한다.

기본 Bundle ID는 `com.firstghrn.lcrepeater.ios`다. 프로파일의 App ID/허용 권한과 일치해야 한다. 명시적 App ID가 다른 경우 Feather에서 맞추거나 아래처럼 빌드한다. 앱 업데이트 때에는 Bundle ID를 유지한다. Team/프로파일 변경에 따른 기존 데이터 유지 여부는 기기에서 확인하고 원본 레슨 파일을 별도로 보관한다.

```bash
LCR_BUNDLE_ID=com.example.myrepeater bash scripts/build_ios.sh
```

Feather 자체의 최초 설치와 인증서 구매는 이 저장소가 수행하지 않는다.

## 포함된 학습 기능

- 레슨 여러 개 가져오기/삭제, 영어 블러 → 영어 공개 → 한국어 순서로 전환하는 카드, 문장 목록
- 새 문장은 영어 블러부터 시작하며, 가려진 영어는 VoiceOver로도 읽지 않는다.
- 1~100회 또는 무한 반복, 0~3초 쉼, 문장 길이만큼 쉬는 섀도잉
- 음높이를 유지한 0.7~1.3배속, 반복 후 정지/다음 문장
- 시험 안내 건너뛰기, 문장 앞뒤 0.1초 조절
- 설정·문장 위치·구간 저장, 앱을 다시 열어 이어 듣기
- 네이티브 오디오 세션과 백그라운드 오디오, 잠금 화면 재생/정지·이전/다음
- 이어폰 분리 시 일시정지, 전화 중단 처리. 오디오 엔진 구성이 바뀌면 현재 문장에서 수동 재시작

반복과 쉼은 `AVAudioPlayerNode`에 미리 예약한 PCM 버퍼로 재생한다. `AVAudioUnitTimePitch`로 속도를 바꾸고, 명시적 쉼 시간은 배속과 무관하게 유지한다. 메인 타이머는 화면 진행률 갱신에만 사용한다. 기기별 잠금/전화/Bluetooth 동작은 아래 실기기 점검을 거친다.

아이폰에서 고친 구간은 로컬 데이터다. PC와 동기화하거나 PC에 되돌려 보내는 기능은 첫 버전에 없다. 같은 레슨을 다시 가져오면 기존 항목을 덮어쓰지 않고 별도 항목으로 추가한다. 앱 삭제 시 앱 내부 레슨·설정도 지워지므로 `.lcrlesson` 원본은 보관한다.

## 파일 형식 v1

추가 ZIP 라이브러리 없이 양쪽에서 스트리밍 처리하는 단일 문서다. 경계가 변하지 않도록 재생용 `master.wav`를 변환 없이 담는다. WAV는 32kHz/모노/16비트 PCM으로 약 230MB/시간이다. 첫 버전의 크기 상한은 음원 2GiB, JSON 8MiB다. AAC 압축 전송은 재생 경계 검증 후 별도 버전으로 추가할 수 있다.

| 순서 | 바이트 | 내용 |
|---|---|---|
| 1 | 8 | ASCII `LCRLESS1` |
| 2 | 8 | manifest 길이, unsigned 64-bit little endian |
| 3 | 위 길이만큼 | UTF-8 JSON manifest |
| 4 | `audio.byte_count` | WAV 원본 바이트 |

manifest 예시:

```json
{
  "format": "toeic-lc-repeater.lesson",
  "version": 1,
  "lesson": {
    "id": "lesson-id", "title": "레슨", "duration": 2.0, "created": 1700000000,
    "sentences": [{"i": 1, "start": 0.1, "end": 1.5, "en": "Hello.", "ko": "안녕하세요.", "kind": "content"}]
  },
  "audio": {
    "format": "wav", "byte_count": 128044, "sha256": "<64 hex characters>",
    "sample_rate": 32000, "channels": 1, "sample_width": 2
  }
}
```

가져올 때 전체 길이·버전·문장 ID·구간·음원 형식·음원 길이·SHA-256을 확인한다. SHA-256은 전달 중 손상 검사이며 제작자 인증은 아니다. 외부 ID나 파일명을 저장 경로에 사용하지 않고 앱이 생성한 UUID 폴더에 저장한다. 완료 전 임시 폴더에서 검증하고, 성공 후에만 보관함에 추가한다.

## 검증

```bash
python3 -m unittest discover -s tests -v
python3 scripts/generate_ios_project.py --check
python3 tests/make_fixture.py /tmp/contract.lcrlesson
LCR_TEST_FIXTURE=/tmp/contract.lcrlesson swift test --package-path ios
```

실기기에서는 실제 교재 음원으로 다음을 확인해야 한다. 저장소/CI에는 교재 음원과 개인 인증서를 올리지 않는다.

- AirDrop/iCloud Drive 가져오기 후 비행기 모드에서 재생
- 앱 종료·재실행 후 레슨/구간/현재 문장 복원
- 0.7×/1.3×에서 반복 횟수·고정 쉼·섀도잉·다음 문장 전환
- 화면 잠금 후 10분 이상 반복, 무한 반복, 잠금 화면 버튼
- 전화 수신 후 재개, 유선/Bluetooth 이어폰 분리·재연결
- 동일 Bundle ID로 앱 업데이트 후 기존 데이터 유지

시뮬레이터 빌드 성공은 실제 아이폰의 백그라운드 오디오/Feather 설치 성공을 보장하지 않는다.
