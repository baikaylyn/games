#!/bin/bash
# ============================================================================
# 霍格沃茨之遗 —— 启动器（单一 App，双击即玩）
#
# 替代原 Sikarugir 启动器（它在 macOS 15 上会报 FileUtilsError 崩掉）。
# 技术栈：D3DMetal（苹果 D3D12→Metal）+ 内嵌 Wine 10.0（跑在 Rosetta 2 下）
#
# 可选环境变量（不改也能玩）：
#   HL_LOG=1          把 Wine 日志写到 ~/Library/Logs/HogwartsLegacy.log
#   HL_HUD=1          显示 Metal 性能 HUD（右上角，调试用）
#   HL_CPUS=4:0,1,2,3 覆盖 CPU 拓扑（默认就是这个）
#   WINEDEBUG=err+all 覆盖日志级别（调试用，会明显掉帧）
# ============================================================================

MACOS_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$(cd "$MACOS_DIR/../.." && pwd)"
SUP="$APP/Contents/SharedSupport"
R="$APP/Contents/Frameworks/renderer/d3dmetal"
EXT="$R/external"
WINE="$SUP/wine/bin/wine"
GAME_DIR="$SUP/prefix/drive_c/Hogwarts Legacy Complete/Phoenix/Binaries/Win64"

if [ ! -x "$WINE" ]; then
    osascript -e 'display alert "找不到内嵌 Wine" message "固态盘插好了吗？\n\n期望路径：'"$WINE"'"' >/dev/null 2>&1
    exit 1
fi

# —— 防重复启动 ——
if pgrep -f "HogwartsLegacy.exe" >/dev/null 2>&1; then
    osascript -e 'display alert "游戏已经在运行了" message "先退出当前窗口再启动。"' >/dev/null 2>&1
    exit 0
fi

export WINEPREFIX="$SUP/prefix"

# —— D3DMetal 接线 ——
export CX_D3DMETALPATH="$R"
export CX_APPLEGPT_LIBD3DSHARED_PATH="$EXT/libd3dshared.dylib"
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$EXT/libd3dshared.dylib"
export DYLD_FRAMEWORK_PATH="$EXT:$APP/Contents/Frameworks"
# 必须包含 Contents/Frameworks：libfreetype / libgnutls / libMoltenVK 都在这里。
# 少了它 Wine 找不到字体 → 所有窗口客户区塌成 0（只剩标题栏的"小横条"），
# 游戏会永远卡在一个点不动的对话框上。这是踩了很久的坑，别删。
export DYLD_FALLBACK_LIBRARY_PATH="$EXT:$APP/Contents/Frameworks:$SUP/wine/lib"
export WINEDLLPATH_PREPEND="$R/wine"

# —— 渲染后端 ——
export D3DMETAL=1
export D3DM_ENABLE_METALFX=1
# 注意：不要加 D3DM_BOUNDS_CHECK=0 / D3DM_ALLOW_HOOKING=0。
# 实测这两个开关会在「准备着色器」阶段触发
# EXCEPTION_ACCESS_VIOLATION reading address 0x00000001e702000b 并崩溃。
# 看起来 D3DMetal 内部依赖边界检查/hooking 通路，不是"纯浪费"。

# —— 同步原语 ——
export WINEESYNC=1
export WINEMSYNC=1

# —— CPU 拓扑 ——
# 注意：去掉这一行实测会崩 EXCEPTION_ACCESS_VIOLATION（D3DMetal 内部依赖稳定的
# 核数上报）。4:0,1,2,3 = 报 4 个逻辑核，映射到 4 个性能核。
export WINE_CPU_TOPOLOGY="${HL_CPUS:-4:0,1,2,3}"

# —— 日志 ——
if [ "${HL_LOG:-0}" = "1" ]; then
    export WINEDEBUG="${WINEDEBUG:-err+all}"
else
    # 默认全关：游戏运行时每帧都会刷 RtlGetDeviceFamilyInfoEnum /
    # get_dummy_preferred_ui_language 之类的 fixme，格式化+写盘是实打实的开销。
    export WINEDEBUG="${WINEDEBUG:--all}"
fi

if [ "${HL_HUD:-0}" = "1" ]; then
    export MTL_HUD_ENABLED=1
fi

# —— 防 App Nap / 降频 ——
# macOS 会把"用户没在交互"的进程降 QoS、赶到能效核上。游戏全屏时正是这种状态。
/usr/bin/caffeinate -dims -w $$ >/dev/null 2>&1 &
CAFF=$!

cd "$GAME_DIR" || exit 1

TRACE="$HOME/Library/Logs/HogwartsLegacy-launcher.log"
mkdir -p "$(dirname "$TRACE")" 2>/dev/null
_log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$TRACE" 2>/dev/null; }
_log "启动器开始：APP=$APP"

if [ "${HL_LOG:-0}" = "1" ]; then
    LOGDIR="$HOME/Library/Logs"
    mkdir -p "$LOGDIR"
    "$WINE" "HogwartsLegacy.exe" "$@" > "$LOGDIR/HogwartsLegacy.log" 2>&1 &
else
    "$WINE" "HogwartsLegacy.exe" "$@" >/dev/null 2>&1 &
fi
WPID=$!
_log "wine 已拉起：pid=$WPID  拓扑=$WINE_CPU_TOPOLOGY  WINEDEBUG=$WINEDEBUG"

# 兜底：自动点掉「显卡驱动警告」对话框。
# 该对话框是 Wine 内部 Win32 窗口，用辅助功能点击会被 TCC 拒绝，
# 所以脚本走 CGEventPostToPid 直接投递回车键（纯 ctypes，系统 python3 就能跑）。
PY="$(command -v python3 2>/dev/null || echo /usr/bin/python3)"
if [ -x "$PY" ] && [ -f "$MACOS_DIR/auto_dismiss.py" ]; then
    "$PY" "$MACOS_DIR/auto_dismiss.py" "$WPID" >/dev/null 2>&1 &
fi

wait "$WPID"
RC=$?
_log "wine 退出：code=$RC"
kill "$CAFF" >/dev/null 2>&1
exit 0
