# Windows 앱

Windows 10 1809 이상 / Windows 11의 Intel·AMD 64비트(x64) PC용이다.

## 설치와 사용

1. `LC-Repeater-Setup-x64.exe`를 실행한다. 현재 사용자에게 설치되며 관리자 권한은 필요하지 않다.
2. WebView2 Runtime이 없다면 설치 프로그램이 Microsoft의 공식 설치 도구를 실행한다. 이 경우 인터넷 연결이 필요하다.
3. 시작 메뉴에서 **LC Repeater**를 연다. 첫 실행 때 음성 인식 모델(약 547MB)을 받는다.
4. MP3·M4A·WAV 등의 음원을 올리면 문장별로 나눠 반복해서 들을 수 있다. FFmpeg와 whisper-cli는 앱에 포함된다.
5. 한국어 번역을 쓰려면 [Claude Code의 Windows 설치 안내](https://code.claude.com/docs/en/setup)를 따라 설치하고 터미널에서 로그인한다. 설치 후 앱을 다시 열면 된다. 번역 없이도 영어 반복 학습은 쓸 수 있다.

영어 블러 → 영어 공개 → 한국어 → 다시 블러 전환과 **아이폰용 레슨 내보내기**도 제공한다.
윈도우의 iCloud Drive 등으로 `.lcrlesson` 파일을 아이폰에 옮겨 iOS 앱에서 가져오면 된다.

데이터·모델·로그·WebView 설정은 `%LOCALAPPDATA%\LC Repeater\`에 저장한다.
프로그램을 업데이트하거나 제거해도 이 폴더는 삭제하지 않는다. 다른 폴더를 쓰려면 `LCR_SUPPORT_DIR`를 지정한다.
별도의 코드 서명 인증서를 사용하지 않은 설치 파일이다.

## 빌드

GitHub Actions의 **Build and verify Windows app**이 Windows x64에서 빌드하고
`LC-Repeater-Windows-x64` artifact에 설치 파일·SHA-256·검증 결과를 저장한다.
소스가 main에 반영되거나 PR이 열릴 때 실행된다. 웹에서 수동 실행할 수도 있다.

로컬 빌드는 Windows의 Python 3.12 x64, Visual Studio C++ 빌드 도구, MSYS2 MINGW64, Inno Setup 6이 필요하다.
워크플로가 준비하는 `build/windows-tools/ffmpeg.exe`, `whisper-cli.exe`, `licenses/`를 만든 뒤
PowerShell에서 `./build_windows.ps1`, Inno Setup에서 `installer/windows.iss`를 실행한다.
Microsoft의 WebView2 bootstrapper도 워크플로와 같이 `build/`에 준비해야 한다.

FFmpeg 9.0.2는 네트워크 기능과 외부 코덱 라이브러리를 제외한 오디오 도구로 빌드한다.
LGPL 2.1 라이선스, 해당 소스 압축본, 빌드 스크립트를 앱의 `_internal/licenses/`에 포함한다.
Whisper v1.9.5의 MIT 라이선스도 함께 들어 있다. Windows 버전은 CPU로 음성을 인식한다.

## 검증 범위

Windows CI에서 실제 설치 프로그램을 실행한 뒤 설치된 EXE를 검사한다.
한글 경로의 WAV·AAC 변환, tiny.en 모델의 실제 Whisper 추론, 네이티브 WebView2 창의 카드 전환,
문장 이동 시 블러 초기화, 재생 구간 WAV 응답, iOS 레슨 내보내기를 확인한다.
큰 기본 모델의 전체 교재 처리와 실제 스피커 청취는 이 자동 검증에 포함하지 않는다.
