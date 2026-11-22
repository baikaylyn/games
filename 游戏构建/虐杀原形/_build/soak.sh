#!/bin/bash
# 虐杀原形 · 启动稳定性压测
#
# 背景：这个游戏在 Wine + Rosetta 下启动阶段会概率性崩溃（page fault → winedbg 挂住），
# 实测大约一半。启动器里有看门狗自动重试，但"一半"到底是几成，得数出来。
#
# 判定标准（不靠眼睛，靠日志）：
#   成功 = 30 秒内出现 wglSwapBuffers 行（wined3d 真的开始出帧了）
#   失败 = 出现 page fault / starting debugger，或者 30 秒内一行帧都没出
#
# 用法：
#   bash soak.sh 5                          # 现有配置跑 5 次
#   OVERRIDES="d3d9=b;winevulkan=d;vulkan-1=d" bash soak.sh 5   # 换配置跑 5 次
#   TAG=加点东西 bash soak.sh 5

set -u
N="${1:-5}"
TAG="${TAG:-soak}"
WAIT="${WAIT:-30}"
OVERRIDES="${OVERRIDES:-d3d9=b;winevulkan=d}"

APP="$HOME/Games/Prototype/Prototype.app"
WINE="$APP/Contents/Resources/Wine/bin/wine"
WS="$APP/Contents/Resources/Wine/bin/wineserver"
GAME="$APP/Contents/Resources/Game"
export WINEPREFIX="$HOME/Library/Application Support/MacNativeGames/PROTOTYPE/prefix"
export WINEDEBUG="err+all,fps"
export WINE_CPU_TOPOLOGY="${CORES:-4}:0,1,2,3"
export WINEDLLOVERRIDES="$OVERRIDES"

OUT="$HOME/Library/Logs/prototype-soak-$TAG-$(date +%H%M%S)"
mkdir -p "$OUT"
echo "配置：WINEDLLOVERRIDES=$OVERRIDES  轮数=$N  每次观察=${WAIT}s" | tee "$OUT/result.txt"

ok=0; bad=0
for i in $(seq 1 "$N"); do
    "$WS" -k 2>/dev/null; sleep 1
    pkill -9 -f "$APP/Contents/Resources/Wine" 2>/dev/null
    pkill -9 -f "prototypef.exe" 2>/dev/null
    sleep 1

    ( cd "$GAME" && "$WINE" explorer "/desktop=Prototype,1280x720" "$GAME/prototypef.exe" ) \
        > "$OUT/run$i.log" 2>&1 &
    sleep "$WAIT"

    if grep -q "wglSwapBuffers" "$OUT/run$i.log"; then
        v=$(grep -oE "@ approx [0-9.]+fps" "$OUT/run$i.log" | tail -1 | grep -oE "[0-9.]+")
        echo "  第 $i 次：成功（出帧，末帧 ${v:-?} fps）" | tee -a "$OUT/result.txt"
        ok=$((ok+1))
    elif grep -qE "page fault|starting debugger|not in stack limits" "$OUT/run$i.log"; then
        echo "  第 $i 次：失败（启动期崩溃）" | tee -a "$OUT/result.txt"
        bad=$((bad+1))
    else
        echo "  第 $i 次：失败（${WAIT}s 内没出帧）" | tee -a "$OUT/result.txt"
        bad=$((bad+1))
    fi
done

"$WS" -k 2>/dev/null; sleep 1
pkill -9 -f "$APP/Contents/Resources/Wine" 2>/dev/null
pkill -9 -f "prototypef.exe" 2>/dev/null

echo "结果：$ok / $((ok+bad)) 次成功" | tee -a "$OUT/result.txt"
echo "明细：$OUT"
