#!/bin/bash
# 美女室友竟然 · 从 DMG 全量部署（换机 / App 丢了 / 想重做时用）
#
#   bash 01_部署.sh [dmg 路径] [目标目录]
#
# 默认：
#   dmg    /Volumes/SSD/Game/原始包/美女室友竟然.dmg
#   目标   /Volumes/SSD/Game/MilkGame
#
# 全程只读挂载原始 dmg，dmg 本身不改动、不当缓存，是这块盘上的「干净底本」。
# 三件事：ditto 展开 → 清理重签（调 02）→ 卸载。不装任何系统组件。
set -eu

DMG="${1:-/Volumes/SSD/Game/原始包/美女室友竟然.dmg}"
DEST="${2:-/Volumes/SSD/Game/MilkGame}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MNT="/tmp/fh_mnt"

[ -f "$DMG" ] || { echo "找不到 dmg：$DMG"; exit 1; }

NEED=$((36 * 1024 * 1024 * 1024))
AVAIL=$(df -k "$(dirname "$DEST")" | awk 'NR==2{print $4}')
if [ "$((AVAIL * 1024))" -lt "$NEED" ]; then
    echo "空间不够：需要约 36 GB，当前可用 $((AVAIL / 1024 / 1024)) GB"
    exit 1
fi

if [ -d "$DEST/美女室友竟然.app" ]; then
    echo "目标已存在：$DEST/美女室友竟然.app"
    echo "要重做请先手动移走它（脚本不替你删 31 GB 的东西）"
    exit 1
fi

echo "==> 1/3 只读挂载 dmg"
mkdir -p "$MNT"
hdiutil attach -readonly -nobrowse -noverify -mountpoint "$MNT" "$DMG" >/dev/null
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true' EXIT INT TERM

SRC="$MNT/MilkGame.app"
[ -d "$SRC" ] || { echo "dmg 里没有 MilkGame.app，结构变了"; exit 1; }

echo "==> 2/3 展开到 $DEST（约 31 GB，10 分钟左右）"
mkdir -p "$DEST/_build"
ditto "$SRC" "$DEST/美女室友竟然.app"

echo "==> 3/3 清理与重签"
bash "$HERE/02_清理与校验.sh" "$DEST/美女室友竟然.app"

echo
echo "dmg 原地保留（不可再生，别删）：$DMG"
