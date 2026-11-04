#!/bin/bash
cd "$(dirname "$0")"
pkill -x ClaudeThinking 2>/dev/null
echo "메뉴바 아이콘을 준비하는 중이에요. 10~30초만 기다려 주세요..."
if [ ! -x ./ClaudeThinking ] || [ ClaudeThinking.swift -nt ClaudeThinking ]; then
  # 컴파일러와 버전이 맞는 SDK를 고른다 (27.0 SDK는 현재 컴파일러와 안 맞음)
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
  [ -d "$SDK" ] || SDK=$(xcrun --show-sdk-path)
  swiftc -O -sdk "$SDK" ClaudeThinking.swift -o ClaudeThinking || { echo "만들기 실패. 위 내용을 Claude에게 보여 주세요."; exit 1; }
fi
nohup ./ClaudeThinking >/dev/null 2>&1 &
disown
echo "완료! 메뉴바 오른쪽 위 별 아이콘을 확인하세요. 이 창은 닫아도 돼요."
