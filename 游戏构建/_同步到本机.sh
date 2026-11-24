#!/bin/bash
# 把固态上的「构建文档 + 构建源码」同步到本机 ~/Games/游戏构建/。
#
#   bash _同步到本机.sh
#
# 为什么要有这一步：固态是外置盘，拔了就没法查文档、也没法重编启动器。
# 本机只存文档和小体积源码（几十 KB~几百 KB），游戏本体和构建工作树都留在固态。
#
# 规矩：**每次改完任何一份文档或 _build 源码，跑一次这个脚本，再跑 _生成总文档.sh。**
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DST="$HOME/Games/游戏构建"
mkdir -p "$DST"

n=0
take() {  # take <源文件> <目标文件>
    [ -f "$1" ] || { echo "  跳过（没有）：$1"; return; }
    cp -f "$1" "$2" && n=$((n + 1))
}

# ---- 总目录 / 索引（改了就要同步，别让本机那份过期）----
take "$HERE/说明.md"                        "$DST/说明.md"

# ---- 分文档（同名放本机根目录，方便直接打开）----
take "$HERE/塞尔达/重建实操指引.md"        "$DST/塞尔达-重建实操指引.md"
take "$HERE/霍格沃茨之遗/重建实操指引.md"   "$DST/霍格沃茨之遗-重建实操指引.md"
take "$HERE/虐杀原形/说明.md"              "$DST/虐杀原形-说明.md"
take "$HERE/虐杀原形/重建实操指引.md"       "$DST/虐杀原形-重建实操指引.md"
take "$HERE/港诡实录/重建实操指引.md"       "$DST/港诡实录-重建实操指引.md"
take "$HERE/鬼泣4/重建实操指引.md"          "$DST/鬼泣4-重建实操指引.md"
take "$HERE/MilkGame/重建实操指引.md"      "$DST/MilkGame-重建实操指引.md"

# ---- 构建源码（重编启动器/测量都要用）----
mkdir -p "$DST/霍格沃茨之遗/_build" "$DST/虐杀原形/_build" "$DST/港诡实录/_build" "$DST/鬼泣4/_build" "$DST/MilkGame/_build"
for f in "$HERE/霍格沃茨之遗/_build"/*; do
    [ -f "$f" ] && take "$f" "$DST/霍格沃茨之遗/_build/$(basename "$f")"
done
for f in "$HERE/虐杀原形/_build"/*.m "$HERE/虐杀原形/_build"/*.py "$HERE/虐杀原形/_build"/*.sh; do
    [ -f "$f" ] && take "$f" "$DST/虐杀原形/_build/$(basename "$f")"
done
for f in "$HERE/港诡实录/_build"/*; do
    [ -f "$f" ] && take "$f" "$DST/港诡实录/_build/$(basename "$f")"
done
for f in "$HERE/鬼泣4/_build"/*; do
    [ -f "$f" ] && take "$f" "$DST/鬼泣4/_build/$(basename "$f")"
done
for f in "$HERE/MilkGame/_build"/*; do
    [ -f "$f" ] && take "$f" "$DST/MilkGame/_build/$(basename "$f")"
done

# ---- 总文档与生成脚本 ----
take "$HERE/总重建指引.md"   "$DST/总重建指引.md"
take "$HERE/_生成总文档.sh"  "$DST/_生成总文档.sh"
take "$HERE/_同步到本机.sh"  "$DST/_同步到本机.sh"
chmod +x "$DST/_生成总文档.sh" "$DST/_同步到本机.sh" 2>/dev/null

echo "已同步 $n 个文件 → $DST"
du -sh "$DST" | awk '{print "本机游戏构建目录占用：" $1}'
