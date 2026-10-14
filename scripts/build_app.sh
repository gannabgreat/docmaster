#!/bin/zsh
# Convertly.app 을 만든다. Xcode 없이 Command Line Tools 만으로 된다.
#   zsh scripts/build_app.sh            → build/Convertly.app
#   zsh scripts/build_app.sh --install  → /Applications 에도 복사
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)

[[ -f build/AppIcon.icns ]] || swift scripts/make_icon.swift build

APP=build/Convertly.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Convertly" "$BIN/convertly-cli" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp build/AppIcon.icns "$APP/Contents/Resources/"
# hwp 엔진·편집기(rhwp-studio 오프라인 사본, MIT)
ditto Resources/rhwp-studio "$APP/Contents/Resources/rhwp-studio"
ditto Resources/bgremove "$APP/Contents/Resources/bgremove"

# 본인 맥 전용 자체 서명(ad-hoc). 다른 맥 배포는 Developer ID 서명·공증이 따로 필요하다.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built: $PWD/$APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Convertly.app
  ditto "$APP" /Applications/Convertly.app
  echo "installed: /Applications/Convertly.app"
fi
