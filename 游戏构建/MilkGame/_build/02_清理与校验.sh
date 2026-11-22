#!/bin/bash
# 美女室友竟然 · 清理 / 重签 / 去隔离
#
#   bash 02_清理与校验.sh [App 路径] [--force-inner]
#
# 这个脚本只动 App 自己，不碰系统：
#   · 不执行安装包里的「双击修复损毁」——那个脚本会 `sudo spctl --master-disable`
#     把整台机器的 Gatekeeper 关掉，是拿系统安全换一次能打开，绝不能跑。
#   · 不往 launchd 里装/删任何服务（原版启动器会动真 Steam 的 ipctool）。
#
# 为什么要重签：替换 Contents/MacOS/load 之后，外层 bundle 的密封签名就失效了。
# macOS 15 / Apple Silicon 上签名无效的 App 直接被 SIGKILL，连报错都没有。
#
# 关于耗时：内层 App 里有 31 GB 的 resources.resource，重签要把它整体哈希一遍，
# 在 USB 固态上约 5–15 分钟。所以内层只在「确实改过」时才重签，平时只签外层（秒级）。
set -u

APP="${1:-/Volumes/SSD/Game/MilkGame/美女室友竟然.app}"
FORCE_INNER=0
for a in "$@"; do [ "$a" = "--force-inner" ] && FORCE_INNER=1; done
HERE="$(cd "$(dirname "$0")" && pwd)"
INNER="$APP/Contents/Game/MilkGame.app"

[ -d "$APP" ] || { echo "找不到 App：$APP"; exit 1; }

if pgrep -f "$APP/Contents" >/dev/null 2>&1; then
    echo "==> App 正在运行，先退出"
    pkill -f "$APP/Contents" 2>/dev/null
    sleep 2
fi

echo "==> 1/6 清掉打包残留"
find "$APP" -name '.DS_Store' -delete 2>/dev/null
find "$APP" -name '._*' -delete 2>/dev/null
rm -f "$APP/Contents/Config/ipcserver.pid" 2>/dev/null

echo "==> 2/6 安装清理版启动器（去掉 launchctl 与全局 pkill）"
if [ ! -f "$APP/Contents/Resources/load.orig.sh" ]; then
    cp -p "$APP/Contents/MacOS/load" "$APP/Contents/Resources/load.orig.sh"
    echo "    原版已备份 → Contents/Resources/load.orig.sh"
fi
rm -f "$APP/Contents/MacOS/load.orig" 2>/dev/null
# steam_appid.txt 是数据，不该待在 Contents/MacOS —— 那里只放可执行代码，
# 混进一个纯文本会让 codesign 报 "code object is not signed at all"。
if [ -f "$APP/Contents/MacOS/steam_appid.txt" ]; then
    mv -f "$APP/Contents/MacOS/steam_appid.txt" "$APP/Contents/Config/steam_appid.txt"
    echo "    steam_appid.txt → Contents/Config/"
fi
ditto --norsrc "$HERE/load_clean.sh" "$APP/Contents/MacOS/load"
chmod 755 "$APP/Contents/MacOS/load"
xattr -c "$APP/Contents/MacOS/load" 2>/dev/null

echo "==> 3/6 改显示名（Finder / 程序坞 / 菜单栏 不再显示 MilkGame）"
# 只在值不同时才写，写了才需要重签内层——避免每次都白跑一遍 31 GB 的哈希
patch_name() {
    local PL="$1"
    [ -f "$PL" ] || return 1
    local cur
    cur="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PL" 2>/dev/null)"
    [ "$cur" = "美女室友竟然" ] && return 1
    /usr/libexec/PlistBuddy -c "Set :CFBundleName 美女室友竟然" "$PL" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleName string 美女室友竟然" "$PL" 2>/dev/null
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName 美女室友竟然" "$PL" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string 美女室友竟然" "$PL" 2>/dev/null
    return 0
}
INNER_TOUCHED=0
patch_name "$APP/Contents/Info.plist" && echo "    外层 Info.plist 已改"
patch_name "$INNER/Contents/Info.plist" && { INNER_TOUCHED=1; echo "    内层 Info.plist 已改"; }
[ "$INNER_TOUCHED" = 0 ] && echo "    名字已是目标值，内层无需重签"
echo "    CFBundleIdentifier 保持 com.storytaco.pc01client 不变（存档路径靠它）"

echo "==> 4/6 中性化 Steam 模拟器的身份（原包带着别人的账号名）"
python3 - "$APP/Contents/Config/nsteame_settings/NemirtingasSteamEmu.json" <<'PY'
import json, sys, os
p = sys.argv[1]
if not os.path.exists(p):
    print("    没有配置文件，跳过")
    raise SystemExit
with open(p, encoding="utf-8") as f:
    cfg = json.load(f)
user = cfg.setdefault("SteamEmu", {}).setdefault("User", {})
before = (user.get("UserName"), user.get("SteamId"))
user["UserName"] = "Player"
user["SteamId"] = 76561197960287930
user.setdefault("Language", "schinese")
app = cfg["SteamEmu"].setdefault("Application", {})
app.setdefault("AppId", 3021100)
with open(p, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"    账号名 {before[0]!r} → 'Player'，SteamId {before[1]} → 76561197960287930")
PY

echo "==> 5/6 重签（ad-hoc，从内到外）"
if [ "$INNER_TOUCHED" = 1 ] || [ "$FORCE_INNER" = 1 ]; then
    echo "    内层：重签中，31 GB 哈希，USB 固态约 5–15 分钟…"
    time codesign --force --sign - --timestamp=none "$INNER" 2>&1 | sed 's/^/    /'
else
    echo "    内层：未改动，保留原签名"
fi
echo "    外层："
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/      /'

echo "==> 6/6 去隔离并校验"
xattr -cr "$APP" 2>/dev/null
if codesign --verify --strict --verbose=2 "$APP" 2>&1 | grep -q "valid on disk"; then
    echo "    签名校验：通过"
else
    echo "    签名校验：失败 —— 把上面的输出发我"
    exit 1
fi

echo
echo "架构：$(/usr/bin/lipo -archs "$INNER/Contents/MacOS/MilkGame" 2>/dev/null)"
echo "体积：$(du -sh "$APP" | awk '{print $1}')"
echo "完成。双击 $APP 即可。"
