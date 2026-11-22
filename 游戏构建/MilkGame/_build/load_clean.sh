#!/bin/bash
# 美女室友竟然（Five Hearts Under One Roof · Season 1）启动器
#
# 这个文件会替换 App 里原来的 Contents/MacOS/load。
#
# 原版 load 有两个问题，这里都去掉了：
#   1. 启动和退出时各调一次 launchctl（remove / load 真 Steam 的 ipctool 服务）——
#      那是往用户的 launchd 里装东西，属于改系统设置，本机没装 Steam 时纯属空转。
#   2. 无条件 pkill ipcserver —— 会误杀同一时间在跑的别的实例。
#
# 保留的是必须的部分：Steam 模拟器的三个环境变量 + ipcserver 的起停。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"          # …/Contents/MacOS
CONTENTS="$(cd "$HERE/.." && pwd)"             # …/Contents

GAME_APP=""
for c in "$CONTENTS/Game"/*.app; do
    [ -d "$c" ] && GAME_APP="$c" && break
done
if [ -z "$GAME_APP" ]; then
    osascript -e 'display alert "找不到游戏本体" message "Contents/Game 下没有 .app，安装包可能不完整。" as critical' >/dev/null 2>&1
    exit 1
fi

EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$GAME_APP/Contents/Info.plist" 2>/dev/null)"
[ -n "${EXEC_NAME:-}" ] || EXEC_NAME="MilkGame"

APP_ID="$(tr -d '[:space:]' < "$CONTENTS/Config/steam_appid.txt" 2>/dev/null)"
[ -n "${APP_ID:-}" ] || APP_ID="$(tr -d '[:space:]' < "$HERE/steam_appid.txt" 2>/dev/null)"
[ -n "${APP_ID:-}" ] || APP_ID="3021100"

export SteamAppId="$APP_ID"
export SteamGameId="$APP_ID"
export STEAMEMU_SETTINGS_DIR="$CONTENTS/Config"
export DYLD_LIBRARY_PATH="$HERE${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

cd "$HERE" || exit 1

# 上一轮崩溃可能留下 ipcserver 占着 mach 端口，用 pid 文件精确回收（不碰别人的进程）
PIDFILE="$CONTENTS/Config/ipcserver.pid"
if [ -f "$PIDFILE" ]; then
    OLD_PID="$(cat "$PIDFILE" 2>/dev/null)"
    if [ -n "${OLD_PID:-}" ] && ps -p "$OLD_PID" -o comm= 2>/dev/null | grep -q ipcserver; then
        kill "$OLD_PID" 2>/dev/null
        sleep 1
    fi
fi

./ipcserver >/dev/null 2>&1 &
IPC_PID=$!
echo "$IPC_PID" > "$PIDFILE"

cleanup() {
    kill "$IPC_PID" 2>/dev/null
    wait "$IPC_PID" 2>/dev/null
    rm -f "$PIDFILE"
}
trap cleanup EXIT INT TERM HUP

"$GAME_APP/Contents/MacOS/$EXEC_NAME"
