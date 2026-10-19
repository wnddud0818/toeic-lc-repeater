#!/usr/bin/env bash
# 브라우저로 쓸 때(개발용) whisper.cpp 설치 + 모델 다운로드 (처음 한 번만)
# 맥 앱은 build_app.sh로 만들고, 모델은 앱이 처음 열릴 때 내려받는다.
set -euo pipefail
cd "$(dirname "$0")"

MODEL="${WHISPER_MODEL_NAME:-ggml-large-v3-turbo-q5_0.bin}"

command -v whisper-cli >/dev/null || brew install whisper-cpp

mkdir -p models
if [ ! -f "models/$MODEL" ]; then
  curl -L --fail -o "models/$MODEL.part" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL"
  mv "models/$MODEL.part" "models/$MODEL"
fi

echo "준비 완료: $(command -v whisper-cli), models/$MODEL"
