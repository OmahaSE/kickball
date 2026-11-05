#!/bin/bash
cd "$(dirname "$0")"
pkill -x ClaudeThinking 2>/dev/null
echo "메뉴바 아이콘을 준비하는 중이에요. 10~30초만 기다려 주세요..."
APP=ClaudeThinking.app
BIN=$APP/Contents/MacOS/ClaudeThinking
if [ ! -x "$BIN" ] || [ ClaudeThinking.swift -nt "$BIN" ]; then
  # 컴파일러와 버전이 맞는 SDK를 고른다 (27.0 SDK는 현재 컴파일러와 안 맞음)
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
  [ -d "$SDK" ] || SDK=$(xcrun --show-sdk-path)
  mkdir -p "$APP/Contents/MacOS"
  swiftc -O -sdk "$SDK" ClaudeThinking.swift -o "$BIN" || { echo "만들기 실패. 위 내용을 Claude에게 보여 주세요."; exit 1; }
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>service.ggear.ClaudeThinking</string>
  <key>CFBundleName</key><string>ClaudeThinking</string>
  <key>CFBundleDisplayName</key><string>Claude Thinking</string>
  <key>CFBundleExecutable</key><string>ClaudeThinking</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>고양이가 딛고 설 발판(글자 줄·버튼 윗변)을 화면에서 찾는 데 써요. 화면은 기기 밖으로 나가지 않아요.</string>
</dict></plist>
PLIST
  codesign --force --sign - "$APP" 2>/dev/null   # 임시 서명: 권한 창이 앱 이름으로 뜨게
fi
open "$APP"
echo "완료! 메뉴바 별 아이콘을 확인하세요. ClaudeThinking.app은 응용 프로그램 폴더로 옮겨도 돼요. 이 창은 닫아도 돼요."
