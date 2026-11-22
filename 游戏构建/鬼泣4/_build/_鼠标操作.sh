#!/bin/bash
# 鬼泣4 特别版 · 鼠标化操作一键启动
#
#   bash _鼠标操作.sh              # 玩 NERO（开局角色，近战=I / 枪=J）
#   bash _鼠标操作.sh --melee j    # 换但丁 / 维吉尔（近战=J / 枪=I）
#   bash _鼠标操作.sh --sens 10    # 视角更迟钝（默认 6，越小越灵敏）
#   bash _鼠标操作.sh --no-capture # 不锁鼠标（允许光标离开游戏框）
#   bash _鼠标操作.sh --nogame     # 游戏已在跑，只启动重映射器
#
# ── 键位映射（底层重映射，不改游戏内设置）──────────────────────
#   鼠标左键            → 近战攻击
#   鼠标右键            → 鬼手 / 风格技
#   鼠标中键 / 侧键 / F → 枪械攻击
#   键盘 左右 Shift     → 锁定目标（按住）
#   键盘 空格           → 跳跃 + 确认（游戏里二者本就是同一个键）
#   鼠标移动            → 转视角（光标锁在游戏框内，不会滑出去）
#   长按 Cmd            → 临时放行，去操作别的窗口
#   Ctrl+C              → 退出重映射器
#
# ── 生效条件 ────────────────────────────────────────────────
#   * 只在游戏窗口位于最前时接管输入，切到别的窗口自动放行
#   * 游戏内键位必须保持 Capcom 出厂值（MELEE I / GUN J / JUMP K /
#     BRINGER L / TRIGGER N / LOCK-ON 空格 / EXCEED Q）
#     被改乱了就进 SYSTEMS → 角色页 → DEFAULT 一键复原
#
# ── 退出后光标若不跟手 ───────────────────────────────────────
#   bash _鼠标操作.sh --release    # 只还原鼠标关联
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE" || exit 1

APP="/Volumes/SSD/Game/DMC4/Devil May Cry 4.app"
SRC="$HERE/dmc4_input_v4.c"
BIN="$HERE/dmc4_input_v4"

# ── 参数分流：只把 --nogame 留在本脚本，其余透传给重映射器 ──
NOGAME=0
PASSTHRU=()
for a in "$@"; do
    case "$a" in
        --nogame) NOGAME=1 ;;
        *) PASSTHRU+=("$a") ;;
    esac
done

# ── 编译（源码比二进制新就重编）────────────────────────────
if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
    echo "==> 编译 dmc4_input_v4"
    clang -O2 -framework ApplicationServices -framework CoreFoundation \
          -framework CoreGraphics -o "$BIN" "$SRC" || {
        echo "编译失败"; exit 1; }
fi

# ── 权限自检 ────────────────────────────────────────────────
if [ -x "$HERE/permtest" ]; then
    if ! "$HERE/permtest" >/dev/null 2>&1; then
        echo "⚠️  缺少「辅助功能 / 输入监控」权限，鼠标接管不会生效。"
        echo "   系统设置 → 隐私与安全性 → 辅助功能 → 允许本终端"
    fi
fi

# ── 启动游戏 ────────────────────────────────────────────────
if [ "$NOGAME" -eq 0 ]; then
    # 关键：游戏每次退出都会把 config.ini 重写（TextureDetail 会被改回 HIGHEST），
    # 所以必须在启动前把定版配置重新写回去，否则最低画质从来没真正生效过。
    # 键位由重映射器负责，不靠游戏内绑定，所以不需要 config 可写。
    CFGG="$APP/Contents/SharedSupport/prefix/drive_c/users/Kegworks/AppData/Local/CAPCOM/DEVILMAYCRY4SPECIALEDITION/config.ini"
    if [ -f "$HERE/config.ini" ]; then
        mkdir -p "$(dirname "$CFGG")"
        cp -f "$HERE/config.ini" "$CFGG"
        echo "==> 已写回定版画质（TextureDetail=$(grep -E '^TextureDetail=' "$CFGG" | cut -d= -f2)）"
    fi

    WID=""
    if [ -x "$HERE/winid" ]; then
        WID=$("$HERE/winid" 2>/dev/null | grep -i "Devil" | head -1 | awk '{print $1}')
    fi
    if [ -z "${WID:-}" ]; then
        echo "==> 启动鬼泣4"
        open -a "$APP" || { echo "启动失败：$APP"; exit 1; }
        echo "==> 等待游戏窗口..."
        for _ in $(seq 1 60); do
            sleep 2
            WID=$("$HERE/winid" 2>/dev/null | grep -i "Devil" | head -1 | awk '{print $1}')
            [ -n "${WID:-}" ] && break
        done
        [ -z "${WID:-}" ] && { echo "超时：没等到游戏窗口"; exit 1; }
        echo "    窗口已出现（ID ${WID}）"
        sleep 4   # 让它把 CG / 标题画面播完
    else
        echo "==> 游戏已在运行（窗口 ID ${WID}）"
    fi

    # 把焦点抢给游戏窗口：点它的标题栏。
    # 注意：绝不能在这里用 open -a 抢焦点，那会激活 Kegworks 启动器本体，
    # 游戏丢掉 key window 后键盘彻底失效且拿不回来（坑 #12）。
    if [ -x "$HERE/click" ]; then
        echo "==> 把焦点交给游戏（点标题栏）"
        "$HERE/click" 500 45 1 >/dev/null 2>&1
        sleep 0.8
    fi

    # 切到英文/ASCII 键盘，避免中文输入法吃掉按键
    # （必须带参数 keylayout.ABC；只跑 ./swic 不带参数只是列出清单，不切换）
    if [ -x "$HERE/swic" ]; then
        "$HERE/swic" keylayout.ABC >/dev/null 2>&1
    fi
fi

# ── 启动重映射器 ────────────────────────────────────────────
echo "==> 启动鼠标重映射（Ctrl+C 退出）"
echo ""
exec "$BIN" ${PASSTHRU[@]+"${PASSTHRU[@]}"}
