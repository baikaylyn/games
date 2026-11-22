#!/bin/bash
# 鬼泣4 · 还原成出厂设置（想从头再调一遍时用）
#
#   bash _恢复原样.sh
#
# 干两件事：config.ini 换回工厂原始值（最高画质 1280x720）、
#           清掉 user.reg 里 [Software\Wine\Direct3D] 下我们加的四项。
set -u

APP="${DMC_APP:-/Volumes/SSD/Game/DMC4/Devil May Cry 4.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$APP/Contents/SharedSupport/prefix/drive_c/users/Kegworks/AppData/Local/CAPCOM/DEVILMAYCRY4SPECIALEDITION/config.ini"
REG="$APP/Contents/SharedSupport/prefix/user.reg"

[ -d "$APP" ] || { echo "❌ 找不到 App：$APP"; exit 1; }

echo "==> 退出游戏与 wineserver"
pkill -9 -f "Devil May Cry 4.app" 2>/dev/null
pkill -9 -f DevilMayCry4        2>/dev/null
pkill -9 -f wineserver          2>/dev/null
sleep 3

echo "==> 还原 config.ini"
if [ -f "$HERE/config.ini.工厂原始" ]; then
    cp -f "$HERE/config.ini.工厂原始" "$CFG"
    echo "    已换回工厂原始（1280x720 / 最高画质）"
else
    echo "    ⚠️  没有 config.ini.工厂原始，跳过"
fi

echo "==> 清掉 Direct3D 下的优化项"
if [ -f "$HERE/user.reg.bak" ]; then
    cp -f "$HERE/user.reg.bak" "$REG"
    echo "    已用 user.reg.bak 整份还原"
else
    python3 - "$REG" <<'PY'
import re, sys
p = sys.argv[1]
txt = open(p, encoding='utf-8', errors='surrogateescape').read()
for k in ('VideoMemorySize', 'csmt', 'OffscreenRenderingMode', 'renderer'):
    txt = re.sub(r'^"%s"=.*\n' % re.escape(k), '', txt, flags=re.M)
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(txt)
print("    已逐项删除（没有 user.reg.bak，只能按名字删）")
PY
fi

echo
echo "✅ 已还原。注意：还原后帧率会回到 17~20 fps，这是正常的。"
