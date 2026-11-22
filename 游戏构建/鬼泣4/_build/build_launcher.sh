#!/bin/bash
# 重建「鬼泣4 启动器.app」
#
#   bash build_launcher.sh
#   DMC4_LAUNCHER_APP=<路径> bash build_launcher.sh   # 换输出位置
#
# 重映射器不再作为子进程，而是编译进启动器本体（同一个签名 / 同一份 TCC 授权）。
#
# 注意：ad-hoc 签名每次重建都会变 cdhash，**TCC 辅助功能授权会失效**。
#       给启动器授权之后，别再重建；要改面板就先改完再授权。
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${DMC4_LAUNCHER_APP:-/Volumes/SSD/Game/DMC4/鬼泣4 启动器.app}"
GAME="${DMC4_APP:-/Volumes/SSD/Game/DMC4/Devil May Cry 4.app}"

echo "==> 1/4 编译重映射器对象（main 改名为 dmc4_input_main）"
clang -O2 -c "$HERE/dmc4_input_v4.c" -Dmain=dmc4_input_main -o /tmp/dmc4_input_v4.o

echo "==> 2/4 编译启动器（链接重映射器）"
clang -O2 -fobjc-arc -framework Cocoa -framework ApplicationServices \
      "$HERE/dmc4_launcher.m" /tmp/dmc4_input_v4.o \
      -o /tmp/DMC4Launcher

echo "==> 3/4 组装 bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [ ! -f "$APP/Contents/Info.plist" ]; then
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>鬼泣4 启动器</string>
	<key>CFBundleDisplayName</key><string>鬼泣4 启动器</string>
	<key>CFBundleIdentifier</key><string>com.macnativegames.dmc4.launcher</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleExecutable</key><string>DMC4Launcher</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>LSMinimumSystemVersion</key><string>11.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST
fi
# 用 ditto --norsrc 覆盖，避免带 com.apple.provenance（霍格沃茨踩过的坑）
ditto --norsrc /tmp/DMC4Launcher "$APP/Contents/MacOS/DMC4Launcher"
if [ ! -f "$APP/Contents/Resources/AppIcon.icns" ] && [ -f "$GAME/Contents/Resources/Kegworks.icns" ]; then
    cp "$GAME/Contents/Resources/Kegworks.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
chmod +x "$APP/Contents/MacOS/DMC4Launcher"

# 兜底用的独立重映射器（.command 会用到）
if [ ! -x "$HERE/dmc4_input_v4" ] || [ "$HERE/dmc4_input_v4.c" -nt "$HERE/dmc4_input_v4" ]; then
    echo "     顺带重编独立版 dmc4_input_v4（.command 兜底用）"
    clang -O2 -framework ApplicationServices -framework CoreFoundation \
          -framework CoreGraphics -o "$HERE/dmc4_input_v4" "$HERE/dmc4_input_v4.c"
fi

echo "==> 4/4 签名（用稳定的 designated requirement，重建后授权不失效）"
codesign --force --deep --sign - \
  --requirements '=designated => identifier "com.macnativegames.dmc4.launcher"' \
  "$APP"
xattr -cr "$APP" 2>/dev/null || true

echo
echo "✅ 完成：$APP"
echo "   首次授权：系统设置 → 隐私与安全性 → 辅助功能 → 勾选「鬼泣4 启动器」，"
echo "   然后完全退出启动器（Cmd+Q）再重新打开。"
echo "   签名要求已固定为 identifier，之后重建不会重置授权。"
