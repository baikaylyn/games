#!/bin/bash
# 虐杀原形 · 崩溃率压测（以"是否崩溃"为判据，不再把"启动慢"算失败）
#
# 判定：
#   CRASH = 出现 page fault / starting debugger（真正的 wow64cpu 模式切换崩溃，进程必死）
#   HANG  = 进程没了但没有任何崩溃特征（静默卡死）
#   OK    = 观察窗口结束时进程还活着（无论是否已出帧，出帧数另行记录）
#
# 用法：
#   VARIANT=patched N=12 bash soak3.sh    # 用补丁版 wow64cpu
#   VARIANT=orig    N=10 bash soak3.sh    # 用原版做对照
#   STACK=65520 ...                       # 额外加宿主栈上限
set -u

N="${N:-12}"
WAIT="${WAIT:-45}"
VARIANT="${VARIANT:-patched}"
STACK="${STACK:-0}"

APP="$HOME/Games/Prototype/Prototype.app"
WINE="$APP/Contents/Resources/Wine/bin/wine"
WS="$APP/Contents/Resources/Wine/bin/wineserver"
GAME="$APP/Contents/Resources/Game"
DLLDIR="$APP/Contents/Resources/Wine/lib/wine/x86_64-windows"
SRC="$DLLDIR/wow64cpu.dll.$VARIANT"

[ -f "$SRC" ] || { echo "找不到 $SRC"; exit 1; }

export WINEPREFIX="$HOME/Library/Application Support/MacNativeGames/PROTOTYPE/prefix"
export WINEDEBUG="err+all,fps"
export WINE_CPU_TOPOLOGY="4:0,1,2,3"
export WINEDLLOVERRIDES="d3d9=b;winevulkan=d"

OUT="$HOME/Library/Logs/prototype-crash-$VARIANT-$(date +%H%M%S)"
mkdir -p "$OUT"
echo "变体=$VARIANT 轮数=$N 窗口=${WAIT}s 栈=${STACK:-默认}" | tee "$OUT/summary.txt"

cleanup() {
    "$WS" -k 2>/dev/null; sleep 1
    pkill -9 -f "$APP/Contents/Resources/Wine" 2>/dev/null
    pkill -9 -f "prototypef.exe" 2>/dev/null
    sleep 1
}

ok=0; crash=0; hang=0
for i in $(seq 1 "$N"); do
    cleanup
    cp -f "$SRC" "$DLLDIR/wow64cpu.dll"
    log="$OUT/run$i.log"
    if [ "$STACK" != "0" ]; then
        ( cd "$GAME" && /bin/sh -c "ulimit -s $STACK; exec \"$WINE\" explorer \"/desktop=Prototype,1280x720\" \"$GAME/prototypef.exe\"" ) > "$log" 2>&1 &
    else
        ( cd "$GAME" && "$WINE" explorer "/desktop=Prototype,1280x720" "$GAME/prototypef.exe" ) > "$log" 2>&1 &
    fi
    sleep "$WAIT"
    frames=$(grep -c "wglSwapBuffers" "$log" 2>/dev/null || echo 0)
    if grep -q "page fault" "$log" 2>/dev/null; then
        r="CRASH"; crash=$((crash+1))
    elif pgrep -f prototypef.exe >/dev/null 2>&1; then
        r="OK"; ok=$((ok+1))
    else
        r="HANG"; hang=$((hang+1))
    fi
    echo "  $i: $r  帧行=$frames  行数=$(wc -l < "$log" | tr -d ' ')" | tee -a "$OUT/summary.txt"
done

cleanup
echo "------" | tee -a "$OUT/summary.txt"
echo "结果：OK=$ok CRASH=$crash HANG=$hang 共$N" | tee -a "$OUT/summary.txt"
echo "明细：$OUT"
