#!/bin/bash
# D3DMetal 诊断启动器：与 启动游戏.command 等价，但同步模式/拓扑可通过环境变量覆盖
#   WINEMSYNC=0 WINEESYNC=0 bash run_d3dm.sh      -> 退回 server 同步
APP="/Volumes/SSD/Game/HogwartsLegacy/Hogwarts Legacy.app"
SUP="$APP/Contents/SharedSupport"
R="$APP/Contents/Frameworks/renderer/d3dmetal"
EXT="$R/external"
WINE="$SUP/wine/bin/wine"
GAME_DIR="$SUP/prefix/drive_c/Hogwarts Legacy Complete/Phoenix/Binaries/Win64"

export WINEPREFIX="$SUP/prefix"
export CX_D3DMETALPATH="$R"
export CX_APPLEGPT_LIBD3DSHARED_PATH="$EXT/libd3dshared.dylib"
export CX_APPLEGPTK_LIBD3DSHARED_PATH="$EXT/libd3dshared.dylib"
export DYLD_FRAMEWORK_PATH="$EXT:$APP/Contents/Frameworks"
# 关键：Contents/Frameworks 里有 libfreetype/libpng/libbz2 等依赖链，
# 不加进来 wine 就报 "cannot find the FreeType font library"，导致所有窗口客户区塌成 0
export DYLD_FALLBACK_LIBRARY_PATH="$EXT:$APP/Contents/Frameworks:$SUP/wine/lib"
export WINEDLLPATH_PREPEND="$R/wine"
export D3DMETAL=1
export D3DM_ENABLE_METALFX=1

# 可被外部环境变量覆盖（默认沿用正式脚本的设置）
export WINEESYNC="${WINEESYNC:-1}"
export WINEMSYNC="${WINEMSYNC:-1}"
export WINE_CPU_TOPOLOGY="${WINE_CPU_TOPOLOGY:-4:0,1,2,3}"
export WINEDEBUG="${WINEDEBUG:-err+all}"

echo "=== D3DMetal 诊断启动 @ $(date) ==="
echo "  WINEESYNC=$WINEESYNC WINEMSYNC=$WINEMSYNC CPU_TOPOLOGY=$WINE_CPU_TOPOLOGY"
echo "  WINEDEBUG=$WINEDEBUG"

cd "$GAME_DIR" || exit 1
exec "$WINE" "HogwartsLegacy.exe" "$@"
