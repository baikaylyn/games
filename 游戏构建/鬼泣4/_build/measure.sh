#!/bin/bash
# 鬼泣4 · 量帧率
#
#   bash measure.sh            # 默认量 6 次
#   bash measure.sh 10 3       # 量 10 次，每次间隔 3 秒
#
# 流程：自动退出旧进程 → 启动 → 点标题栏抢焦点 → 连按回车进关卡
#      → 按住前进 + 连打攻击 → 每 N 秒抓一张「只含游戏窗口」的截图
#      → 最后把右上角 Metal HUD 拼成一张 hud.png，直接看数字
#
# 为什么必须「只抓游戏窗口」：screencapture -l <窗口号> 不带遮挡层，
# 否则聊天窗口会盖住 HUD。窗口号用自带的 winid 取。
#
# 前提：Info.plist 的 METAL_HUD=1（否则没有数字可读）
#   plutil -replace METAL_HUD -string 1 "$APP/Contents/Info.plist"
set -u

APP="${DMC_APP:-/Volumes/SSD/Game/DMC4/Devil May Cry 4.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${DMC_OUT:-/tmp/dmc4_measure}"
ROUNDS="${1:-6}"
GAP="${2:-3}"

[ -d "$APP" ] || { echo "❌ 找不到 App：$APP"; exit 1; }
PLIST="$APP/Contents/Info.plist"
[ "$(plutil -extract METAL_HUD raw "$PLIST" 2>/dev/null)" = "1" ] || {
    echo "⚠️  METAL_HUD 不是 1，没有帧率数字可读。现在打开："
    plutil -replace METAL_HUD -string 1 "$PLIST"
}

mkdir -p "$OUT"
cd "$HERE" || exit 1

echo "==> 编译辅助工具"
for t in click keypress keyhold winid; do
    [ -x "./$t" ] || clang -O2 -framework ApplicationServices -o "$t" "$t.c" 2>/dev/null
done
[ -x ./swic ] || clang -O2 -framework Carbon -o swic swic.c 2>/dev/null

echo "==> 退出旧进程"
pkill -9 -f "Devil May Cry 4.app" 2>/dev/null
pkill -9 -f DevilMayCry4        2>/dev/null
pkill -9 -f wineserver          2>/dev/null
sleep 3

./swic keylayout.ABC >/dev/null 2>&1   # 切英文键盘，避免输入法吃掉回车
echo "==> 启动，等 70 秒"
open -a "$APP"
sleep 70

WID=$(./winid | grep -i "CRY" | awk '{print $1}' | head -1)
[ -z "$WID" ] && { echo "❌ 游戏窗口没出现"; exit 1; }
echo "   窗口号 $WID  $(./winid | grep -i 'CRY')"

# 点标题栏抢焦点（别用 open -a，那会激活启动器本体、抢走 key window）
./click 235 48 1 >/dev/null 2>&1; sleep 1
./keypress 36 1 0 >/dev/null 2>&1; sleep 4
./keypress 36 1 0 >/dev/null 2>&1; sleep 6
./keypress 36 1 0 >/dev/null 2>&1; sleep 8

echo "==> 压力采样（按住前进 + 连打攻击，共 $ROUNDS 次）"
( ./keyhold 13 $(( ROUNDS * GAP * 1000 + 2000 )) >/dev/null 2>&1 ) &
for i in $(seq 1 "$ROUNDS"); do
    sleep "$GAP"
    ./keypress 38 2 120 >/dev/null 2>&1        # J = 攻击
    screencapture -x -l "$WID" -o "$OUT/f$i.png" 2>/dev/null
    echo "    第 $i 张"
done
wait

echo "==> 拼接 HUD"
python3 - "$OUT" "$ROUNDS" <<'PY'
import sys, os
from PIL import Image
out, n = sys.argv[1], int(sys.argv[2])
files = [os.path.join(out, f"f{i}.png") for i in range(1, n + 1)]
files = [f for f in files if os.path.exists(f)]
if not files:
    sys.exit("没有截图")
ps = []
for f in files:
    im = Image.open(f); w, h = im.size
    ps.append(im.crop((max(0, w - 430), 20, w - 6, 110)))
W = max(c.width for c in ps); H = sum(c.height for c in ps)
canvas = Image.new("RGB", (W, H), (0, 0, 0)); y = 0
for c in ps:
    canvas.paste(c, (0, y)); y += c.height
canvas = canvas.resize((int(W * 1.9), int(H * 1.9)), Image.LANCZOS)
dst = os.path.join(out, "hud.png")
canvas.save(dst)
print("   ", dst)
PY

echo
echo "✅ 原始截图在 $OUT/f*.png，HUD 汇总在 $OUT/hud.png"
echo "   读法：FPS 那行就是帧率，Pre 是每帧毫秒（互为倒数），GPU 是 GPU 毫秒"
