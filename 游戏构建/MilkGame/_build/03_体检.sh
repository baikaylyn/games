#!/bin/bash
# 美女室友竟然 · 启动自检
#
#   bash 03_体检.sh [等几秒，默认 35]
#
# 做三件事：拉起 App → 等它出窗口 → 截图并报「进程在不在 / 有没有窗口」。
# 出图在 /tmp/fh-window.png，人眼看一眼就知道成没成。
set -u

APP="${FH_APP:-/Volumes/SSD/Game/MilkGame/美女室友竟然.app}"
WAIT="${1:-35}"
SHOT="${FH_SHOT:-/tmp/fh-window.png}"

[ -d "$APP" ] || { echo "找不到 App：$APP"; exit 1; }

echo "==> 清掉上一轮进程"
pkill -f "$APP/Contents" 2>/dev/null
pkill -f "MilkGame.app/Contents/MacOS/MilkGame" 2>/dev/null
sleep 2

echo "==> 启动"
open -a "$APP"
sleep "$WAIT"

echo "==> 进程"
PID="$(pgrep -f "$APP/Contents/Game/MilkGame.app/Contents/MacOS/MilkGame" | head -1)"
if [ -n "$PID" ]; then
    echo "    游戏进程在：PID $PID"
    ps -p "$PID" -o %cpu=,rss= 2>/dev/null | awk '{printf "    CPU %s%%，内存 %.0f MB\n", $1, $2/1024}'
else
    echo "    ⚠️ 没找到游戏进程"
fi

echo "==> 窗口"
python3 - "$SHOT" <<'PY'
import sys, Quartz
shot = sys.argv[1]
wins = []
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID):
    b = w.get('kCGWindowBounds', {})
    if int(b.get('Width', 0)) >= 640 and int(b.get('Height', 0)) >= 360:
        wins.append((w.get('kCGWindowOwnerName', ''), int(b.get('Width')), int(b.get('Height')), w.get('kCGWindowNumber')))
for owner, w, h, num in wins:
    print(f"    {owner}: {w}x{h} (id {num})")
if not wins:
    print("    ⚠️ 没有大窗口")
PY

screencapture -x "$SHOT"
echo "==> 截图：$SHOT"
