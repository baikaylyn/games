#!/bin/bash
# 把两个塞尔达 Mac 版连同存档打包到外接硬盘 / 网盘同步目录。
# 双击运行，或：  ./打包到硬盘或网盘.command /Volumes/你的硬盘
set -u

GAMES="$HOME/游戏台"
DATA="$HOME/Library/Application Support/MacNativeGames"
NEED_MB=$((36 * 1024))   # 两个 App + 数据，留一点余量

say() { printf '%s\n' "$*"; }
fail() { say ""; say "✗ $*"; say ""; read -r -p "按回车关闭…" _; exit 1; }

# ---------- 目标目录 ----------
if [ $# -ge 1 ]; then
    DEST="$1"
else
    DEST=$(osascript -e 'POSIX path of (choose folder with prompt "选择打包到哪个硬盘 / 文件夹（需要 36 GB 以上空闲）")' 2>/dev/null) || fail "已取消"
fi
DEST="${DEST%/}"
[ -d "$DEST" ] || fail "目标不存在：$DEST"

# ---------- 源文件检查 ----------
TOTK_APP="$GAMES/王国之泪/Tears of the Kingdom M3.app"
BOTW_APP="$GAMES/旷野之息/Breath of the Wild.app"
for p in "$TOTK_APP" "$BOTW_APP"; do
    [ -d "$p" ] || fail "找不到：$p"
done

# ---------- 剩余空间 ----------
FREE_MB=$(df -m "$DEST" | awk 'NR==2 {print $4}')
say "目标：$DEST"
say "目标剩余：$((FREE_MB / 1024)) GB   需要：$((NEED_MB / 1024)) GB"
[ "$FREE_MB" -ge "$NEED_MB" ] || fail "目标空间不足（还差 $(( (NEED_MB - FREE_MB) / 1024 )) GB）"

OUT="$DEST/塞尔达-Mac版"
if [ -e "$OUT" ]; then
    say ""
    say "⚠️  $OUT 已存在。继续会先删除旧的这一份（只删这个目录里的内容）。"
    read -r -p "确认继续？(y/N) " ans
    case "$ans" in y|Y) rm -rf "$OUT" ;; *) fail "已取消" ;; esac
fi
mkdir -p "$OUT"

# ---------- 复制 ----------
# ditto 保留代码签名、扩展属性和符号链接；cp 会把签名弄坏。
copy() {   # $1 源  $2 目标父目录
    local src="$1" dst="$2"
    say "  → $(basename "$src")"
    ditto "$src" "$dst/$(basename "$src")" || fail "复制失败：$src"
}

say ""
say "[1/3] 王国之泪 App（约 16 GB）"
copy "$TOTK_APP" "$OUT/王国之泪"

say "[2/3] 旷野之息 App（约 16 GB）"
copy "$BOTW_APP" "$OUT/旷野之息"

say "[3/3] 存档与设置（约 2 GB）"
mkdir -p "$OUT/游戏数据"
copy "$DATA/BOTW" "$OUT/游戏数据"
copy "$DATA/TOTK" "$OUT/游戏数据"

# ---------- 说明 ----------
cat > "$OUT/说明.txt" <<'TXT'
塞尔达传说 Mac 原生版 —— 迁移说明
=====================================

一、放回哪里
  1. 两个 .app 放到 ~/Games/王国之泪/ 和 ~/Games/旷野之息/
     （放别的路径也能跑，但启动器里的路径提示是按这个位置写的）
  2. 「游戏数据」里的 BOTW、TOTK 两个文件夹，放到
     ~/Library/Application Support/MacNativeGames/
     —— 这里装的是存档、账号、着色器缓存。少了它游戏能开，但没有存档。

二、第一次运行
  从网盘下载来的包会被 macOS 打上「隔离」标记，直接双击可能提示"已损坏"。
  在终端执行一次（把路径换成实际的）：

     xattr -dr com.apple.quarantine ~/Games/王国之泪/"Tears of the Kingdom M3.app"
     xattr -dr com.apple.quarantine ~/Games/旷野之息/"Breath of the Wild.app"

  或者右键 → 打开。从移动硬盘直接拷过来一般没有隔离标记，可以直接双击。

三、要求
  · Apple Silicon（M 系列），macOS 15.0 或更新
  · 首次进游戏会先预热着色器，可能几分钟；之后正常

四、存档
  ~/Library/Application Support/MacNativeGames/TOTK/profile/save/
  ~/Library/Application Support/MacNativeGames/BOTW/profile/save/
  换机器时把这两个目录整个搬过去即可。

五、不含在包里的东西
  原始游戏本体（素材/xci本体 16 GB）和构建源码（_构建源码 3 GB）是重新构建才需要的，
  日常游玩用不到，所以没打进去。
TXT

say ""
say "✓ 完成：$OUT"
say "  合计 $(du -sh "$OUT" 2>/dev/null | cut -f1)"
say ""
read -r -p "按回车关闭…" _
