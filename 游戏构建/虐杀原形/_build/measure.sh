#!/bin/bash
# 虐杀原形 · 可重复性能/稳定性测量脚本
#
# 目的：不靠体感，用同一套环境变量跑一次固定时长的启动，把
#   ① 是否崩在启动阶段  ② 帧率区间  ③ CPU 占用  落到一个文本里。
# 改了启动器参数之后跑一遍，拿两份结果对比就知道有没有用。
#
# 用法：
#   bash measure.sh              # 默认跑 120 秒
#   bash measure.sh 180          # 跑 180 秒
#   TAG=对比环境 bash measure.sh # 结果文件名带标签
#
# 结尾会自动杀掉整个 Wine 会话，不会留下孤儿进程。

set -u
SECS="${1:-120}"
TAG="${TAG:-baseline}"

APP="$HOME/Games/Prototype/Prototype.app"
WINE="$APP/Contents/Resources/Wine/bin/wine"
GAME="$APP/Contents/Resources/Game"
PREFIX="$HOME/Library/Application Support/MacNativeGames/PROTOTYPE/prefix"
OUT="$HOME/Library/Logs/prototype-measure-$TAG-$(date +%H%M%S)"
RES="${RES:-1280x720}"
CORES="${CORES:-4}"

mkdir -p "$OUT"

# —— 与启动器完全一致的环境 ——
export WINEPREFIX="$PREFIX"
export WINEDEBUG="${WINEDEBUG:-err+all,fps}"
export WINE_CPU_TOPOLOGY="$CORES:$(seq -s, 0 $((CORES-1)))"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-d3d9=b;winevulkan=d}"

cd "$GAME" || exit 1
echo "环境：" > "$OUT/summary.txt"
echo "  WINEDEBUG=$WINEDEBUG" >> "$OUT/summary.txt"
echo "  WINE_CPU_TOPOLOGY=$WINE_CPU_TOPOLOGY" >> "$OUT/summary.txt"
echo "  WINEDLLOVERRIDES=$WINEDLLOVERRIDES" >> "$OUT/summary.txt"
echo "  桌面=$RES  时长=${SECS}s" >> "$OUT/summary.txt"

START=$(date +%s)
"$WINE" explorer "/desktop=Prototype,$RES" "$GAME/prototypef.exe" > "$OUT/wine.log" 2>&1 &
WPID=$!

# 每 2 秒采一次 CPU，最多采 $SECS 秒；游戏进程没了就提前收工
: > "$OUT/cpu.txt"
while [ $(( $(date +%s) - START )) -lt "$SECS" ]; do
    PIDS=$(pgrep -f "$APP/Contents/Resources/Wine" | tr '\n' ' ')
    if [ -z "$PIDS" ]; then echo "$(date +%H:%M:%S) 无进程" >> "$OUT/cpu.txt"; break; fi
    ARGS=""; for p in $PIDS; do ARGS="$ARGS -p $p"; done
    CPU=$(ps -o %cpu= $ARGS 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s}')
    RSS=$(ps -o rss= $ARGS 2>/dev/null | awk '{s+=$1} END {printf "%.0f", s/1024}')
    echo "$(date +%H:%M:%S) cpu=${CPU}% rss=${RSS}MB" >> "$OUT/cpu.txt"
    sleep 2
done

# —— 收场：先礼后兵，不留残留会话 ——
"$APP/Contents/Resources/Wine/bin/wineserver" -k 2>/dev/null
sleep 1
pkill -9 -f "$APP/Contents/Resources/Wine" 2>/dev/null
pkill -9 -f "prototypef.exe" 2>/dev/null

{
    echo
    echo "== 崩溃特征 =="
    grep -cE "page fault|not in stack limits|nested exception" "$OUT/wine.log" | xargs echo "  命中条数:"
    echo
    echo "== 帧率（wglSwapBuffers）=="
    grep -oE "wglSwapBuffers @ approx [0-9.]+fps" "$OUT/wine.log" | grep -oE "[0-9.]+" > "$OUT/fps.txt"
    if [ -s "$OUT/fps.txt" ]; then
        awk 'NR==1{min=$1} {max=$1; s+=$1; n++} END{
            printf "  样本 %d 条  最低 %.0f  中位 %.0f  最高 %.0f  均值 %.1f\n", n, min, s/n, max, s/n}' "$OUT/fps.txt"
        # 只统计后半程（此时已进菜单/游戏内，排除了片头的高帧率）
        HALF=$(awk 'NR>n/2' n=$(wc -l < "$OUT/fps.txt") "$OUT/fps.txt")
        if [ -n "$HALF" ]; then
            echo "$HALF" | awk 'NR==1{min=$1} {max=$1; s+=$1; n++} END{
                printf "  后半程 %d 条  最低 %.0f  中位 %.0f  最高 %.0f\n", n, min, s/n, max}'
        fi
    else
        echo "  没有帧率样本（没进到绘制阶段）"
    fi
    echo
    echo "== CPU（末 5 个采样）=="
    tail -5 "$OUT/cpu.txt" | sed 's/^/  /'
} | tee -a "$OUT/summary.txt"

echo
echo "结果目录：$OUT"
