#!/bin/bash
# 生成《总重建指引.md》—— 把六个游戏的重建内容合并成一份。
#
# 为什么用脚本生成而不是手写：
#   这份总文档的正文就是各游戏分文档的原文（零信息损失），
#   改完任何一个分文档后重跑本脚本即可，不会出现"总文档和分文档说法不一致"。
#
#   bash _生成总文档.sh
#
# 依赖的源文档（缺了会跳过并告警）：
#   塞尔达-重建实操指引.md        （本机）
#   霍格沃茨之遗-重建实操指引.md  （本机）
#   虐杀原形/说明.md              （只有固态）—— 使用视角
#   虐杀原形/重建实操指引.md       （只有固态）—— 构建视角
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SSD="/Volumes/SSD/Game/游戏构建"
OUT="$HERE/总重建指引.md"

SRC_ZELDA="$HERE/塞尔达/重建实操指引.md"
[ -f "$SRC_ZELDA" ] || SRC_ZELDA="$HERE/塞尔达-重建实操指引.md"
SRC_HL="$HERE/霍格沃茨之遗/重建实操指引.md"
[ -f "$SRC_HL" ] || SRC_HL="$HERE/霍格沃茨之遗-重建实操指引.md"
SRC_PROTO="$SSD/虐杀原形/说明.md"
[ -f "$SRC_PROTO" ] || SRC_PROTO="$HERE/虐杀原形/说明.md"
SRC_PROTO_BUILD="$SSD/虐杀原形/重建实操指引.md"
[ -f "$SRC_PROTO_BUILD" ] || SRC_PROTO_BUILD="$HERE/虐杀原形/重建实操指引.md"
SRC_PHK="$HERE/港诡实录/重建实操指引.md"
SRC_DMC4="$HERE/鬼泣4/重建实操指引.md"
SRC_MILK="$HERE/MilkGame/重建实操指引.md"

for f in "$SRC_ZELDA" "$SRC_HL" "$SRC_PROTO" "$SRC_PROTO_BUILD" "$SRC_PHK" "$SRC_DMC4" "$SRC_MILK"; do
    [ -f "$f" ] || echo "⚠️  缺少源文档：${f}（这一部分会被跳过）" >&2
done

# 去掉源文档开头的 "# 标题" 行和结尾的「最后更新」行，其余原样保留
body() {
    awk 'NR==1 && /^# /{next} {print}' "$1" \
      | grep -v '^最后更新：' \
      | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

{
cat <<'HEADER'
# 游戏构建 · 总重建指引

> **这份是七个游戏完整重建内容的合并版。** 正文直接取自各游戏的分文档（原文照搬，没有删减），
> 前面加了统一的情况判别表和跨游戏通用规矩。
>
> 放在两处，内容完全一致：
> - 本机 `~/Games/游戏构建/总重建指引.md`（盘没插也能看）
> - 固态 `/Volumes/SSD/Game/游戏构建/总重建指引.md`（和构建源码在一起）
>
> ⚠️ **这份是生成出来的**，别手改。改了任何一个分文档之后，重跑 `bash _生成总文档.sh`。
> 分文档仍是权威源：`塞尔达-重建实操指引.md`、`霍格沃茨之遗-重建实操指引.md`、`虐杀原形/说明.md`（使用）、`虐杀原形/重建实操指引.md`（构建）、`港诡实录/重建实操指引.md`、`鬼泣4/重建实操指引.md`、`MilkGame/重建实操指引.md`。

## 目录

| 部分 | 内容 | 对应分文档 |
|---|---|---|
| 第 0 部分 | 先判断：90% 的情况不用重建 + 跨游戏通用规矩 | — |
| 第 1 部分 | **王国之泪 / 旷野之息**（Mac 原生，含从零重建全流程） | `塞尔达-重建实操指引.md` |
| 第 2 部分 · 2.A | **虐杀原形** 使用说明：启动器每一项、看门狗、20+ 条坑位、存档、性能 | `虐杀原形/说明.md` |
| 第 2 部分 · 2.B | **虐杀原形** 构建文档：四步流程、MoltenVK、固定签名、wow64cpu、验收 | `虐杀原形/重建实操指引.md` |
| 第 3 部分 | **霍格沃茨之遗**（Wine + D3DMetal，含 15 条坑位） | `霍格沃茨之遗-重建实操指引.md` |
| 第 4 部分 | **港诡实录**（Wine + D3DMetal，UE4，含 16 条坑位与内存实测） | `港诡实录/重建实操指引.md` |
| 第 5 部分 | **鬼泣4 特别版**（Wine + wined3d→MoltenVK，32 位/DX10，含 26 条坑位、性能翻倍实录与鼠标化操控） | `鬼泣4/重建实操指引.md` |
| 第 6 部分 | **美女室友竟然 S1**（Mac 原生 arm64，含清理清单与 7 条坑位） | `MilkGame/重建实操指引.md` |
| 附录 | 不可再生清单、文档地图 | — |

---

# 第 0 部分 · 先判断，再动手

## 0.1 情况判别表（90% 的情况根本不用重建）

| 症状 | 哪个游戏 | 怎么办 | 耗时 |
|---|---|---|---|
| App 不见了 / 被误删 | 全部 | 从固态对应目录拷回来，见各部分开头的「最快恢复」 | 5–10 分钟 |
| 双击没反应、也不报错 | 霍格沃茨 | `pkill -9 -f 'windows.system32'; pkill -9 -f HogwartsLegacy` 再双击 | 10 秒 |
| 卡在 `wineboot --init` | 霍格沃茨 | 同上 | 10 秒 |
| 弹「想要访问可移除宗卷」 | 霍格沃茨 | 点**允许**（一次性） | 1 秒 |
| 只有标题栏没画面（"小横条"） | 霍格沃茨 | `DYLD_FALLBACK_LIBRARY_PATH` 少了 `Contents/Frameworks`，重编启动器 | 2 分钟 |
| 弹「显卡驱动警告」 | 霍格沃茨 | 面板勾上「屏蔽驱动警告」（`D3DM_VENDOR_ID=0x1002`） | 5 秒 |
| 进游戏崩 `EXCEPTION_ACCESS_VIOLATION` | 霍格沃茨 | 删掉 `D3DM_BOUNDS_CHECK` / `D3DM_ALLOW_HOOKING` / `D3DM_ENABLE_ASYNC_COMMIT` | 1 分钟 |
| 启动卡死 / 死锁 | 虐杀原形 | 检查 `WINE_CPU_TOPOLOGY=4:0,1,2,3`；`WINEDEBUG` 不能是 `-all` | 1 分钟 |
| 点开始游戏没反应、日志空白 | 虐杀原形 | 后端选了 DXVK 但 `Game/` 里没有 `d3d9.dll`（现在会自动切回 wined3d） | 5 秒 |
| 卡在黑窗口不动 | 虐杀原形 | 别动，看门狗 20~25 秒自动重来（最多 5 次）；`logs/launcher.log` 有判定依据 | 最长 2 分钟 |
| 启动 3 秒左右直接退出 | 虐杀原形 | **MoltenVK 没禁掉**（`Exception c0000005 in system thread`）；`launcher.log` 里找 `MoltenVK：未禁用` | 1 分钟 |
| 窗口停在左上角、不居中 | 虐杀原形 | 启动器没拿到「辅助功能」授权；允许后 Cmd+Q 重开一次 | 30 秒 |
| 启动器崩 `FileUtilsError` | 塞尔达 | macOS 26+ 会崩，见第 1 部分 | — |
| 改了 `runtime/*.c` 想生效 | 塞尔达 | 只重编 runtime，**不用全量重建**（2–4 分钟） | 5 分钟 |
| 双击闪退、日志空白（`FileUtilsError`） | 港诡实录 | 原厂 Kegworks 启动器在 macOS 15 必挂，重编启动器 | 20 秒 |
| 弹「已损坏，无法打开」 | 港诡实录 | `xattr -dr com.apple.quarantine "$APP"` | 5 秒 |
| 改了画质重进又变回默认 | 港诡实录 | 正常：游戏退出会重写 `GameUserSettings.ini`，改面板而不是改文件 | — |
| 画面正常但**巨卡**（15~20 fps） | 鬼泣4 | 注册表 `VideoMemorySize` 没写，跑 `鬼泣4/_build/_应用优化.sh` | 2 分钟 |
| 人物变成**全黑剪影** | 鬼泣4 | 有人加了 `WINE_D3D_CONFIG=renderer=gl`，删掉即可 | 1 分钟 |
| 菜单里回车 / ESC 没反应 | 鬼泣4 | 中文输入法在吃按键，切 ABC 英文键盘（`./swic keylayout.ABC`，**不带参数不会切换**） | 5 秒 |
| 鼠标移到游戏框外 / 左键不变攻击 | 鬼泣4 | 重映射器没跑，起 `鬼泣4/_build/_鼠标操作.sh`；退出后光标不跟手就加 `--release` | 10 秒 |
| 最低画质没生效、内存一直 2.2 GB | 鬼泣4 | 游戏把 `TextureDetail` 回写成 `HIGHEST`，启动前要重写 config（`_鼠标操作.sh` 已内置） | 10 秒 |
| 启动后黑屏几秒自己退回桌面 | 美女室友 | 残留 `ipcserver` 占端口：`pkill -f ipcserver`，删掉 `Contents/Config/ipcserver.pid` | 5 秒 |
| 双击后 Dock 一闪就没 | 美女室友 | 改过 bundle 没重签：`bash MilkGame/_build/02_清理与校验.sh` | 10 秒 |
| 菜单栏显示 `MilkGame` | 美女室友 | 同上，脚本会把显示名改回「美女室友竟然」 | 10 秒 |
| 改了启动器面板 | 四个 Wine 游戏 | 一条命令重编启动器 | 3 秒 |

## 0.2 七个游戏一览

| 游戏 | 位置 | 大小 | 技术栈 | 原生？ | 全量重建 |
|---|---|---|---|---|---|
| 王国之泪 | `塞尔达-Mac版/王国之泪/Tears of the Kingdom M3.app` | 16 GB | Mac 原生 arm64 + Metal 3 | ✅ | ~55 分钟 |
| 旷野之息 | `塞尔达-Mac版/旷野之息/Breath of the Wild.app` | 16 GB | Mac 原生 arm64 + Metal 3 | ✅ | ~55 分钟 |
| 虐杀原形 | `~/Games/Prototype/Prototype.app` | 8.6 GB | Wine 11.18 + Rosetta 2 + wined3d | ❌ PE32/i386 | 重新打包 ~20 分钟 |
| 霍格沃茨之遗 | `HogwartsLegacy/Hogwarts Legacy.app` | 92 GB | Wine 10.0 + D3DMetal GPTK 3.0-3 | ❌ PE32+/x64 | 从 dmg 重装 ~40 分钟 |
| 港诡实录 | `ParanormalHK/Paranormal HK.app` | 16 GB | Wine KegworksCX 24.0.7 + D3DMetal 3.0b5 | ❌ PE32+/x64 | 从 dmg 重装 ~10 分钟 |
| 鬼泣4 特别版 | `DMC4/Devil May Cry 4.app` | 27 GB | Wine KegworksCX 24.0.7 + wined3d→MoltenVK | ❌ PE32/i386 | 从 dmg 重装 ~10 分钟 |
| 美女室友竟然 S1 | `MilkGame/美女室友竟然.app` | 31 GB | Unity 2022.3.53 原生通用二进制（arm64 + x86_64） | ✅ | 从 dmg 重装 ~15 分钟 |

> 塞尔达两个是**真原生**（源码在 `游戏构建/塞尔达/_构建源码/`，能改能重编）；
> 美女室友是**官方 macOS 构建**（通用二进制，arm64 直接跑，没过翻译层）。
> 另外四个是 Windows 程序套 Wine，**不可能原生移植**（x86 指令在 ARM 上必须翻译）。
> 其中虐杀原形和鬼泣4 是 **32 位**程序，要走 WoW64 的 32/64 位切换，那条路径在 Rosetta 2 上有缺陷；
> 虐杀原形直接崩，鬼泣4 能跑但慢（50 fps 封顶），而且**装不进 DXVK/DXMT 的大 32 位 DLL**。
> 霍格沃茨和港诡实录都是 64 位，直接当 64 位进程跑，所以稳得多。

## 0.3 跨游戏通用的四条规矩

1. **签名**（三个自编译启动器都适用）
   - 先在 bundle **外面**签名，再拷进去。在 bundle 内签会扫整个 App（16–92 GB，十几分钟且常失败）。
   - 拷进去必须 `ditto --norsrc` + `xattr -c`，`cp -f` 会导致 `SIGKILL (Code Signature Invalid)`。
   - 编译输出**文件名要和 App 内的可执行文件名一致**（ad-hoc 签名的 identifier 由文件名派生）。
2. **Wine 系的路径必须纯英文**。中文路径会被 Wine 转成 `????`，prefix 建不起来。
3. **搬动时保留符号链接**：用 `ditto` / `cp -R` / `rsync -a`，**别用 Finder 拖拽或 `cp -RL`**。
   搬完自检：
   ```sh
   find "/Volumes/SSD/Game/游戏构建" -type l | while read l; do [ -e "$l" ] || echo "断链: $l"; done
   ```
4. **别在外置 USB 盘上直接构建**：慢 3–5 倍，而且中途拔盘即废。先拷到本机再编。

---

HEADER

if [ -f "$SRC_ZELDA" ]; then
    echo "# 第 1 部分 · 王国之泪 / 旷野之息（Mac 原生）"
    echo
    body "$SRC_ZELDA"
    echo
    echo "---"
    echo
fi

if [ -f "$SRC_PROTO" ]; then
    echo "# 第 2 部分 · 虐杀原形（Wine）"
    echo
    echo "## 2.A · 使用说明与坑位清单"
    echo
    body "$SRC_PROTO"
    echo
    echo "---"
    echo
fi

if [ -f "$SRC_PROTO_BUILD" ]; then
    echo "## 2.B · 虐杀原形构建文档（从零重建 / 重编 / 签名 / 验收）"
    echo
    echo "> 以下是**构建视角**的完整文档，日常使用与坑位清单见上面 2.A。"
    echo
    body "$SRC_PROTO_BUILD"
    echo
    echo "---"
    echo
fi

if [ -f "$SRC_HL" ]; then
    echo "# 第 3 部分 · 霍格沃茨之遗（Wine + D3DMetal）"
    echo
    body "$SRC_HL"
    echo
    echo "---"
    echo
fi

if [ -f "$SRC_PHK" ]; then
    echo "# 第 4 部分 · 港诡实录（Wine + D3DMetal，UE4）"
    echo
    body "$SRC_PHK"
    echo
    echo "---"
    echo
fi

if [ -f "$SRC_DMC4" ]; then
    echo "# 第 5 部分 · 鬼泣4 特别版（Wine + wined3d→MoltenVK，32 位 / DX10）"
    echo
    body "$SRC_DMC4"
    echo
    echo "---"
    echo
fi

if [ -f "$SRC_MILK" ]; then
    echo "# 第 6 部分 · 美女室友竟然 S1（Mac 原生 arm64）"
    echo
    body "$SRC_MILK"
    echo
    echo "---"
    echo
fi

cat <<'FOOTER'
# 附录

## A. 不可再生清单（丢了就真做不回来了）

| 游戏 | 不可再生的东西 |
|---|---|
| 王国之泪 | `塞尔达-Mac版/王国之泪/素材/xci本体/[0100F2C0115B6000][v0].xci`（17.5 GB） |
| 旷野之息 | `塞尔达-Mac版/旷野之息/素材/…[01007ef00011e000][v0].nsp`（14.5 GB） |
| 塞尔达（共用） | 两份 `ProdKeys.-v22.5.0/` 里的 `prod.keys` + `title.keys`；`塞尔达/_构建源码/Source/`（24 MB） |
| 虐杀原形 | `Prototype.rar`（固态根目录），丢了要重新找 |
| 霍格沃茨之遗 | `HogwartsLegacy/_installer/` 的原始 dmg（88 GB，v1613387） |
| 港诡实录 | `港诡实录+Paranormal+HK+v1.04+[www.getmacapp.com].dmg`（7.4 GB，改造前的干净底本） |
| 鬼泣4 特别版 | 固态根下 `鬼泣4 Devil May Cry 4 Special Edition v20230105 [www.getmacapp…].dmg`（改造前的干净底本）；`nativeDX10/` 那 25 GB 资源只在 App 里，删了没法单独补 |
| 美女室友竟然 S1 | `原始包/美女室友竟然.dmg`（26 GB，干净底本） |

其余（App 本体、工作树、着色器缓存）都能重新生成。**建议把这几样单独备份到别的盘或网盘。**

## B. 文档地图

| 文件 | 管什么 |
|---|---|
| **`总重建指引.md`** | **本文件**：七个游戏合并版（由脚本生成，别手改） |
| `说明.md` | 归档总目录 + 第六节「当前最佳配置快照」（参数速查） |
| `塞尔达-重建实操指引.md` | 王国之泪 / 旷野之息的权威分文档 |
| `霍格沃茨之遗-重建实操指引.md` | 霍格沃茨之遗的权威分文档 |
| `虐杀原形/说明.md` | 虐杀原形**使用**分文档（固态 `游戏构建/虐杀原形/` 与 `~/Games/Prototype/`、本机 `~/Games/游戏构建/虐杀原形-说明.md` 各一份） |
| `虐杀原形/重建实操指引.md` | 虐杀原形**构建**分文档（固态 `游戏构建/虐杀原形/` 与本机 `~/Games/游戏构建/虐杀原形-重建实操指引.md` 各一份） |
| `港诡实录/重建实操指引.md` | 港诡实录的权威分文档（固态 `游戏构建/港诡实录/` 与本机 `~/Games/游戏构建/` 各一份） |
| `鬼泣4/重建实操指引.md` | 鬼泣4 特别版的权威分文档（固态 `游戏构建/鬼泣4/` 与本机 `~/Games/游戏构建/` 各一份） |
| `MilkGame/重建实操指引.md` | 美女室友竟然 S1 的权威分文档（固态 `游戏构建/MilkGame/` 与本机 `~/Games/游戏构建/` 各一份） |

固态上每个游戏是一个子目录（`塞尔达/`、`霍格沃茨之遗/`、`虐杀原形/`、`港诡实录/`、`鬼泣4/`、`MilkGame/`），
里面的文档都**只讲自己那一个游戏**。

---

最后更新：2026-11-05
FOOTER
} > "$OUT"

echo "已生成：$OUT"
wc -l "$OUT" | awk '{print "行数：" $1}'
ls -l "$OUT" | awk '{print "大小：" $5 " 字节"}'

if [ -d "$SSD" ] && [ "$OUT" != "$SSD/总重建指引.md" ]; then
    cp -f "$OUT" "$SSD/总重建指引.md" && echo "已同步到固态：$SSD/总重建指引.md"
fi

# 生成完顺手同步到本机（文档 + _build 源码），这样拔盘也能查、能重编
if [ -f "$HERE/_同步到本机.sh" ]; then
    bash "$HERE/_同步到本机.sh" | tail -2
fi
