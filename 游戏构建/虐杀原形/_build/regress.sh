#!/bin/bash
# 启动器回归验证：走 GUI 启动器的完整路径（open -a Prototype.app + autoplay 标记），
# 连续 N 轮，每轮看三件事：游戏进程在不在、日志有没有新内容、启动器日志怎么判的。
#
# 为什么要用 autoplay 标记而不是 --args --play：
#   实测 macOS 15 上 `open --args` 不一定把参数送进进程，面板会出来但就是不开始。
#   标记文件是启动器自己读的，任何启动方式都成立。
#
# 用法：bash regress.sh [轮数]（默认 3）
set -u
N="${1:-3}"
APP="$HOME/Games/Prototype/Prototype.app"
D="$HOME/Library/Application Support/MacNativeGames/PROTOTYPE"
L="$D/logs/prototype.log"
LL="$D/logs/launcher.log"
WS="$APP/Contents/Resources/Wine/bin/wineserver"

cleanup() {
    pkill -f "Prototype.app/Contents/MacOS/Prototype" 2>/dev/null
    sleep 1
    "$WS" -k 2>/dev/null
    sleep 1
    pkill -9 -f "Resources/Wine" 2>/dev/null
    pkill -9 -f "prototypef.exe" 2>/dev/null
    sleep 2
}

cleanup
for i in $(seq 1 "$N"); do
    echo "===== 第 $i 轮 ====="
    before=$(wc -l < "$L" 2>/dev/null || echo 0)
    launcher_before=$(wc -l < "$LL" 2>/dev/null || echo 0)
    touch "$D/autoplay"
    open -a "$APP"
    sleep "${OBSERVE:-70}"

    gp=$(pgrep -f "prototypef.exe" | wc -l | tr -d ' ')
    after=$(wc -l < "$L" 2>/dev/null || echo 0)
    echo "  游戏进程=$gp  wine 日志新增=$((after-before)) 行"
    echo "  启动器日志："
    tail -n +$((launcher_before + 1)) "$LL" 2>/dev/null | sed 's/^/    /'
    cleanup
done
