#!/bin/bash
# 重编并安装霍格沃茨之遗的启动器面板。
#
#   bash build_launcher.sh              # 编 hl_launcher.m（面板，默认）
#   bash build_launcher.sh --shim       # 编 launcher.c（无面板的极简启动器）
#
# 三条必须遵守的规矩（踩过的坑，别改）：
#   1. 编译输出必须直接叫 /tmp/Sikarugir —— 签名 identifier 由文件名派生，
#      叫别的名字会和 app 里的文件名不一致，系统判定签名无效直接 SIGKILL。
#   2. 必须先签名、再拷进 bundle。在 bundle 里签会触发 ResourceBuilder 扫 92 GB。
#   3. 拷进 bundle 必须用 ditto --norsrc + xattr -c。直接 cp -f 会带上
#      com.apple.provenance 扩展属性 → "Taskgated Invalid Signature" → SIGKILL。
set -e

APP="${HOGWARTS_APP:-/Volumes/SSD/Game/HogwartsLegacy/Hogwarts Legacy.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/Sikarugir

if [ "$1" = "--shim" ]; then
    echo "==> 编译极简启动器 launcher.c"
    clang -O2 -Wall -o "$OUT" "$HERE/launcher.c"
else
    echo "==> 编译面板启动器 hl_launcher.m"
    clang -fobjc-arc -O2 -Wall -framework AppKit -o "$OUT" "$HERE/hl_launcher.m"
fi

codesign --force --sign - "$OUT"
codesign -dv "$OUT" 2>&1 | grep -E "Identifier|Format"

echo "==> 安装到 $APP/Contents/MacOS/Sikarugir"
ditto --norsrc "$OUT" "$APP/Contents/MacOS/Sikarugir"
chmod 755 "$APP/Contents/MacOS/Sikarugir"
xattr -c "$APP/Contents/MacOS/Sikarugir" 2>/dev/null || true

# 鼠标锁定辅助进程（按 7 切换）。同样必须先在 bundle 外签名再拷进去。
if [ -f "$HERE/hl_mouse.m" ]; then
    echo "==> 编译 hl_mouse"
    clang -fobjc-arc -O2 -Wall -framework AppKit -framework Carbon -o /tmp/hl_mouse "$HERE/hl_mouse.m"
    codesign --force --sign - /tmp/hl_mouse
    ditto --norsrc /tmp/hl_mouse "$APP/Contents/MacOS/hl_mouse"
    chmod 755 "$APP/Contents/MacOS/hl_mouse"
    xattr -c "$APP/Contents/MacOS/hl_mouse" 2>/dev/null || true
fi

echo "==> 完成。第一次双击会弹「访问可移除宗卷」授权，点允许。"
echo "    自检：\"$APP/Contents/MacOS/Sikarugir\" --play  （跳过面板直接启动）"
