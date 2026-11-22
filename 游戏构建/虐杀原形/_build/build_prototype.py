#!/usr/bin/env python3
"""
把「虐杀原形」组装成一个自包含的 macOS App —— 和塞尔达那两个原生版同一个套路：
原生 arm64 启动器 + 内嵌运行时 + 数据目录分离，整个 .app 可以拷到别的 Apple Silicon Mac 上双击运行。

四步（对应塞尔达 build_app.py 的结构）：
  1. 准备运行时   内嵌 Wine 11.18（x86_64，走 Rosetta 2）
  2. 准备游戏数据 7.9 GB 游戏本体，用 APFS 克隆（同卷不额外占空间）
  3. 编译启动器   原生 arm64 Cocoa，把设置翻译成环境变量
  4. 组装并签名   Info.plist + ad-hoc codesign

用法：
  python3 build_prototype.py            # 完整构建
  python3 build_prototype.py --launcher # 只重编启动器（改完 launcher.m 用这个）
"""

import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))          # 本脚本所在目录


def _default_root():
    """定位 Prototype.app 的父目录。

    脚本可能放在两个地方：
      · ~/Games/Prototype/_build/          —— 和 App 并排（就地重编）
      · /Volumes/SSD/Game/游戏构建/虐杀原形/_build/ —— 归档副本（App 不在这）
    先看同级目录里有没有 Prototype.app，没有就回落到 ~/Games/Prototype。
    也可以显式指定：PROTOTYPE_ROOT=/some/where python3 build_prototype.py --launcher
    """
    sibling = os.path.dirname(HERE)
    if os.path.isdir(os.path.join(sibling, "Prototype.app")):
        return sibling
    return os.path.expanduser("~/Games/Prototype")


ROOT = os.environ.get("PROTOTYPE_ROOT") or _default_root()
SRC = HERE
APP = os.path.join(ROOT, "Prototype.app")
CONTENTS = os.path.join(APP, "Contents")

# 完整重建才需要这两份素材（重新解压 Prototype.rar + 解压 Wine 包到这里）。
# 只重编启动器（--launcher）不需要它们。
WINE_SRC = os.path.join(ROOT, "_src", "Wine")
GAME_SRC = os.path.join(ROOT, "_src", "Game")
LAUNCHER_SRC = os.path.join(SRC, "launcher.m")

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>虐杀原形</string>
    <key>CFBundleDisplayName</key>       <string>虐杀原形</string>
    <key>CFBundleExecutable</key>        <string>Prototype</string>
    <key>CFBundleIdentifier</key>        <string>org.macnativegames.prototype</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>15.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.action-games</string>
</dict>
</plist>
"""


def run(cmd, **kw):
    print("  $", " ".join(cmd))
    subprocess.run(cmd, check=True, **kw)


def step_wine():
    """第 1 步：内嵌 Wine 运行时。

    放 Resources 而不是 Frameworks：codesign 把 Frameworks 当嵌套代码，要求里面每个 Mach-O 都有
    签名，而 Wine 树有几百个未签名 dylib，签不过来（code object is not signed at all）。
    放 Resources 就是普通数据，只签 App 本体，几秒完成。
    """
    dst = os.path.join(CONTENTS, "Resources", "Wine")
    if os.path.isdir(dst):
        print("  运行时已存在，跳过")
        return
    print(f"  复制 Wine → {dst}")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    # -c 用 APFS clonefile：同卷时不占额外空间，且比逐字节复制快得多
    run(["cp", "-cR", WINE_SRC, dst])


def step_game():
    """第 2 步：游戏本体。"""
    dst = os.path.join(CONTENTS, "Resources", "Game")
    if os.path.isdir(dst):
        print("  游戏数据已存在，跳过")
        return
    size = sum(os.path.getsize(os.path.join(dp, f))
               for dp, _, fs in os.walk(GAME_SRC) for f in fs) / 1e9
    print(f"  克隆游戏数据 {size:.1f} GB → {dst}")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    run(["cp", "-cR", GAME_SRC, dst])


def step_launcher():
    """第 3 步：编译原生启动器。"""
    dst = os.path.join(CONTENTS, "MacOS", "Prototype")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    print(f"  编译 launcher.m → {dst}")
    run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wall",
         "-o", dst, LAUNCHER_SRC, "-framework", "AppKit"])
    run(["strip", "-x", dst])


def step_tweaks():
    """运行时的必要改动（必须在签名之前做，因为改的是 bundle 里的文件）。

    禁用 MoltenVK：wined3d 初始化时会无条件建一个 Vulkan 实例做能力探测，
    即使 WINEDLLOVERRIDES 里写了 winevulkan=d 也挡不住（那段探测是 unix 侧直接
    dlopen MoltenVK 的）。而这个初始化在 Rosetta 下会概率性把进程带崩，日志表现是
    `err:seh:send_debug_event Exception c0000005 in system thread` 然后几秒内退出。
    实测：开着 4 次启动挂 1~2 次；禁掉之后连续 4 次全成功。
    D3D9 走的是 OpenGL，本来就用不到 Vulkan，禁掉没有副作用。
    """
    mv = os.path.join(CONTENTS, "Resources", "Wine", "lib", "libMoltenVK.dylib")
    if os.path.isfile(mv):
        dst = mv + ".disabled"
        if os.path.exists(dst):
            os.remove(dst)
        os.rename(mv, dst)
        print("  已禁用 MoltenVK（改名为 libMoltenVK.dylib.disabled）")
    else:
        print("  MoltenVK 已是禁用状态")


def step_app():
    """第 4 步：Info.plist + 签名。"""
    print("  写 Info.plist")
    with open(os.path.join(CONTENTS, "Info.plist"), "w") as f:
        f.write(INFO_PLIST)
    os.makedirs(os.path.join(CONTENTS, "Resources"), exist_ok=True)
    with open(os.path.join(CONTENTS, "PkgInfo"), "w") as f:
        f.write("APPL????")
    # 上一次签名被打断会留下 Contents/MacOS/Prototype.cstemp。它会被写进资源封印，
    # 下次校验就报 "a sealed resource is missing or invalid"（踩过）。
    subprocess.run(["find", APP, "-name", "*.cstemp", "-delete"], check=False)
    subprocess.run(["xattr", "-cr", APP], check=False)
    print("  ad-hoc 签名（16 GB 级别的包不加 --deep，只签本体，几秒完成）")
    # 签名要求固定成 identifier，不要让它退回默认的 cdhash 形式。
    # 默认要求里带 cdhash，而 ad-hoc 签名每次重建都会变 → 辅助功能/文稿目录这些
    # TCC 授权全部失效，用户每次重建都得重新点一遍开关（鬼泣4 那边踩了很久）。
    # 固定成 identifier 之后，重建不再影响已有授权。
    run(["codesign", "--force", "--sign", "-",
         "--requirements",
         '=designated => identifier "org.macnativegames.prototype"',
         APP])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--launcher", action="store_true", help="只重编启动器")
    a = ap.parse_args()

    if not a.launcher:
        for p in (WINE_SRC, GAME_SRC):
            if not os.path.isdir(p):
                sys.exit(f"缺少素材：{p}")
        os.makedirs(CONTENTS, exist_ok=True)

    print("[1/4] 运行时")
    if not a.launcher:
        step_wine()
    print("[2/4] 游戏数据")
    if not a.launcher:
        step_game()
    print("[3/4] 启动器")
    step_launcher()
    print("[4/4] 运行时改动 + 组装与签名")
    step_tweaks()
    step_app()

    print(f"\n完成：{APP}")
    print("首次启动会自动初始化 Wine 环境（约 1 分钟），存档在 ~/Documents/Prototype")


if __name__ == "__main__":
    main()
