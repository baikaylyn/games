#!/bin/bash
# hudread <窗口ID> [次数] [间隔秒>
cd /tmp/dmc4 || exit 1
WID="$1"; N="${2:-3}"; GAP="${3:-2}"
for i in $(seq 1 "$N"); do
    f="/tmp/dmc4/hud_${i}.png"
    screencapture -x -o -l "$WID" "$f" 2>/dev/null
    echo "--- 第 $i 张 ---"
    ./ocr "$f" | awk '$3 >= 0.70 {print}' | head -14
    sleep "$GAP"
done
