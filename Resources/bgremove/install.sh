#!/bin/zsh
# Convertly 정밀 배경 제거 엔진 설치 — 사용자가 「정밀 모드」를 켤 때 앱이 실행한다(필요한 사람만, 약 1.5GB).
#   ~/Library/Application Support/Convertly/bgremove/{venv, bgremove.py, models/birefnet-general/birefnet-general.onnx}
# 진행 상황은 「STEP <단계>」 줄로 알린다. 모델은 .part 로 받고 앱이 크기로 진행률을 잰다.
set -eu
V="$HOME/Library/Application Support/Convertly/bgremove"
HERE="${0:A:h}"
URL="https://github.com/danielgatis/rembg/releases/download/v0.0.0/BiRefNet-general-epoch_244.onnx"
MD5="7a35a0141cbbc80de11d9c9a28f52697"
MDIR="$V/models/birefnet-general"
mkdir -p "$V" "$MDIR"

echo "STEP python"
PY=""
for c in python3.13 python3.12 python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
  p=$(command -v "$c" 2>/dev/null) || continue
  "$p" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null && { PY="$p"; break; }
done
if [ ! -x "$V/venv/bin/python" ]; then
  if [ -n "$PY" ]; then
    "$PY" -m venv "$V/venv"
  else
    # 맥에 파이썬 3.11+ 이 없으면 uv(파이썬 관리 도구)로 전용 파이썬을 받아 쓴다
    arch=$(uname -m); [ "$arch" = arm64 ] && arch=aarch64
    mkdir -p "$V/bin"
    curl -fsSL "https://github.com/astral-sh/uv/releases/latest/download/uv-$arch-apple-darwin.tar.gz" | tar -xz -C "$V/bin" --strip-components 1
    UV_PYTHON_INSTALL_DIR="$V/python" "$V/bin/uv" venv -q --python 3.12 "$V/venv"
  fi
fi

echo "STEP packages"
if [ -x "$V/bin/uv" ]; then
  "$V/bin/uv" pip install -q --python "$V/venv/bin/python" "rembg[cpu]"
else
  "$V/venv/bin/python" -m pip install -q --upgrade pip
  "$V/venv/bin/python" -m pip install -q "rembg[cpu]"
fi
cp "$HERE/bgremove.py" "$V/bgremove.py"

echo "STEP model"
if [ ! -f "$MDIR/birefnet-general.onnx" ]; then
  curl -fL -s -C - -o "$MDIR/birefnet-general.onnx.part" "$URL"
  [ "$(md5 -q "$MDIR/birefnet-general.onnx.part")" = "$MD5" ] || { rm -f "$MDIR/birefnet-general.onnx.part"; echo "모델 파일이 손상됐어요. 다시 시도해 주세요." >&2; exit 4; }
  mv "$MDIR/birefnet-general.onnx.part" "$MDIR/birefnet-general.onnx"
fi
"$V/venv/bin/python" -c "import rembg, onnxruntime" 
echo "STEP done"
