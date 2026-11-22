#!/bin/bash
# 鬼泣4 · 一键应用「最低画质 + 显存优化」
#
#   bash _应用优化.sh
#
# 做三件事：
#   1. 把 config.ini 写成最低画质定版（1024x576）
#   2. 往 user.reg 的 [Software\Wine\Direct3D] 写显存/CSMT/离屏/renderer —— 这是帧率翻倍的关键
#   3. 核对 Info.plist 的后端开关
#
# 会先自动退出游戏和 wineserver（否则注册表改动会被回写覆盖）。
set -u

APP="${DMC_APP:-/Volumes/SSD/Game/DMC4/Devil May Cry 4.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -d "$APP" ] || { echo "❌ 找不到 App：$APP"; echo "   用 DMC_APP=<路径> 指定"; exit 1; }

CFG="$APP/Contents/SharedSupport/prefix/drive_c/users/Kegworks/AppData/Local/CAPCOM/DEVILMAYCRY4SPECIALEDITION/config.ini"
REG="$APP/Contents/SharedSupport/prefix/user.reg"
PLIST="$APP/Contents/Info.plist"

echo "==> 1/4 退出游戏与 wineserver"
pkill -9 -f "Devil May Cry 4.app" 2>/dev/null
pkill -9 -f DevilMayCry4        2>/dev/null
pkill -9 -f wineserver          2>/dev/null
sleep 3

echo "==> 2/4 写 config.ini（最低画质 1024x576）"
mkdir -p "$(dirname "$CFG")"
[ -f "$CFG" ] && cp -p "$CFG" "$HERE/config.ini.bak" 2>/dev/null
cp -f "$HERE/config.ini" "$CFG"
echo "    $(grep -E '^(Resolution|Quality|EffectVolume|TextureDetail)=' "$CFG" | tr '\n' ' ')"

echo "==> 3/4 写注册表 [Software\\Wine\\Direct3D]"
[ -f "$REG" ] || { echo "❌ 找不到 user.reg：$REG"; exit 1; }
[ -f "$HERE/user.reg.bak" ] || cp -p "$REG" "$HERE/user.reg.bak"

python3 - "$REG" <<'PY'
import re, sys
p = sys.argv[1]
txt = open(p, encoding='utf-8', errors='surrogateescape').read()

want = {
    'VideoMemorySize': '4096',
    'csmt': '3',
    'OffscreenRenderingMode': 'fbo',
    'renderer': 'vulkan',
}

m = re.search(r'^\[Software\\\\Wine\\\\Direct3D\][^\n]*\n(?:#time=[^\n]*\n)?', txt, re.M)
if not m:
    sys.exit("❌ user.reg 里没有 [Software\\\\Wine\\\\Direct3D] 节")

head = m.group(0)
body_start = m.end()

# 找到本节结束位置（下一个 [ 或文件尾）
nxt = txt.find('\n[', body_start)
body_end = nxt if nxt != -1 else len(txt)
body = txt[body_start:body_end]

for k, v in want.items():
    line = f'"{k}"="{v}"'
    if re.search(r'^"%s"=' % re.escape(k), body, re.M):
        body = re.sub(r'^"%s"=.*$' % re.escape(k), line, body, count=1, flags=re.M)
    else:
        body = line + '\n' + body.lstrip('\n') if body.strip() else line + '\n'

txt = txt[:body_start] + body + txt[body_end:]
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(txt)
print("    已写入：" + ", ".join(f"{k}={v}" for k, v in want.items()))
PY

echo "==> 4/4 核对 Info.plist 后端开关"
for kv in "D3DMETAL:1" "DXMT:0" "DXVK:0" "D9VK:0" "MOLTENVKCX:1"; do
    k="${kv%%:*}"; v="${kv##*:}"
    cur=$(plutil -extract "$k" raw "$PLIST" 2>/dev/null || echo "(无)")
    if [ "$cur" != "$v" ]; then
        plutil -replace "$k" -string "$v" "$PLIST" 2>/dev/null || plutil -insert "$k" -string "$v" "$PLIST"
        echo "    $k: $cur → $v（已修正）"
    else
        echo "    $k: $v ✓"
    fi
done

# 交付默认关 HUD；要量帧率时手动开
cur_hud=$(plutil -extract METAL_HUD raw "$PLIST" 2>/dev/null || echo "(无)")
echo "    METAL_HUD: ${cur_hud}（量帧率时用 plutil -replace METAL_HUD -string 1 打开）"

echo
echo "✅ 完成。启动：open -a \"$APP\""
