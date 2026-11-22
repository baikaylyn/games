#!/bin/bash
# 港诡实录：一次启动 → 抓游戏窗口 → 裁出 Metal HUD，报「窗口是否出现」。
#   bash measure.sh <标签>
# 依赖 _build/winid（首次运行会自动编译）。
# 帧率必须靠 Metal HUD 看（UE4 Shipping 没有控制台），所以启动器里要勾「显示 Metal HUD」。
set -u
APP="${PHK_APP:-/Volumes/SSD/Game/ParanormalHK/Paranormal HK.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-run}"
OUTDIR="/tmp/phk-measure-$TAG"
mkdir -p "$OUTDIR"

[ -x /tmp/winid ] || clang -O2 -framework ApplicationServices -o /tmp/winid "$HERE/winid.c"

# 必须连启动器本体一起杀：只杀 wine 的话 open -a 只是"激活"已存在的启动器，
# autoplay 标记不会被消费，游戏永远不起（踩过，静默失败）
for p in $(/usr/bin/pgrep -f "Paranormal HK.app/Contents"); do kill -9 $p 2>/dev/null; done
"$APP/Contents/SharedSupport/wine/bin/wineserver" -k 2>/dev/null
sleep 3

touch "$HOME/Library/Application Support/MacNativeGames/PARANORMAL/autoplay"
open -a "$APP"

WID=""
for i in $(seq 1 30); do          # 最多等 90 秒
    sleep 3
    WID=$(/tmp/winid PuzzleGame 2>/dev/null | awk '{print $1}' | head -1)
    [ -n "$WID" ] && break
done

if [ -z "$WID" ]; then
    echo "$TAG: 90 秒内没有游戏窗口（启动失败）"
    exit 1
fi

sleep 6                            # 让 HUD 稳定几秒再抓
W=$(/tmp/winid PuzzleGame | head -1 | awk '{print $4}')
screencapture -l "$WID" -x "$OUTDIR/window.png"
sips -g pixelWidth "$OUTDIR/window.png" | tail -1
# HUD 在窗口右上角
PW=$(sips -g pixelWidth "$OUTDIR/window.png" | tail -1 | awk '{print $2}')
sips -c 200 420 --cropOffset 0 $((PW - 420)) "$OUTDIR/window.png" --out "$OUTDIR/hud.png" >/dev/null 2>&1
sips -Z 1000 "$OUTDIR/hud.png" --out "$OUTDIR/hud-big.png" >/dev/null 2>&1

echo "$TAG: 窗口 $WID ($W) → $OUTDIR/hud-big.png"
echo "本机内存压力：$(vm_stat | awk '/Pages free/{f=$3} /Pages active/{a=$3} END{print "free=" f " active=" a}')"
