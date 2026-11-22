#!/bin/bash
# 重编并安装「港诡实录」的启动器面板，替换掉原厂在 macOS 15 上必坏的 Kegworks.exe。
#
#   bash build_launcher.sh
#
# 三条规矩（和霍格沃茨那份一样，别改成 cp）：
#   1. 编译输出必须直接叫 /tmp/Kegworks —— ad-hoc 签名的 identifier 由文件名派生，
#      和 bundle 里的文件名不一致会被判签名无效。
#   2. 先签名、再拷进 bundle。
#   3. 拷进 bundle 用 ditto --norsrc + xattr -c，别用 cp -f（会带 com.apple.provenance）。
set -e

APP="${PHK_APP:-/Volumes/SSD/Game/ParanormalHK/Paranormal HK.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT=/tmp/Kegworks

echo "==> 编译 phk_launcher.m"
clang -fobjc-arc -O2 -Wall -framework AppKit -framework ApplicationServices \
      -o "$OUT" "$HERE/phk_launcher.m"

codesign --force --sign - "$OUT"
codesign -dv "$OUT" 2>&1 | grep -E "Identifier|Format"

if [ ! -f "$APP/Contents/MacOS/Kegworks.orig" ]; then
    echo "==> 备份原厂启动器 → Kegworks.orig"
    cp -p "$APP/Contents/MacOS/Kegworks" "$APP/Contents/MacOS/Kegworks.orig"
fi

echo "==> 安装到 $APP/Contents/MacOS/Kegworks"
ditto --norsrc "$OUT" "$APP/Contents/MacOS/Kegworks"
chmod 755 "$APP/Contents/MacOS/Kegworks"
xattr -c "$APP/Contents/MacOS/Kegworks" 2>/dev/null || true

echo "==> 完成。自检：\"$APP/Contents/MacOS/Kegworks\" --play"
