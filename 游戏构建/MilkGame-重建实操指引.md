# 美女室友竟然 · 重建实操指引
### Five Hearts Under One Roof · Season 1 · Mac 原生

> **这份文档只解决一件事**：哪天这个 App 打不开、被误删、或者换了新 Mac，凭这块固态上的东西，
> 把它一模一样地做回来——双击就进、不弹「已损坏」、不需要关 Gatekeeper、不装任何系统组件。
>
> 当前最佳状态快照时间：**2026-11-05 12:30**（已实测：启动 → 标题界面 → 正常退出，退出码 0）。
>
> 本文件放在两个地方，内容完全一致：
> - 本机 `~/Games/游戏构建/MilkGame-重建实操指引.md`（盘没插也能看）
> - 固态 `/Volumes/SSD/Game/游戏构建/MilkGame/重建实操指引.md`（和构建脚本在一起）

---

## 第 0 节 · 情况判别表（先看这里，九成不用重装）

| 症状 | 真正原因 | 怎么办 | 耗时 |
|---|---|---|---|
| 弹「**已损坏，无法打开**」 | 复制/下载带上了 `com.apple.quarantine` | `xattr -cr "$APP"` | 5 秒 |
| 双击后 Dock 图标一闪就没，没有任何报错 | 改过 bundle 内容但没重签，签名失效 | `bash _build/02_清理与校验.sh` | 10 秒 |
| 启动后黑屏几秒自己退回桌面 | 残留 `ipcserver` 占着端口，Steam 模拟器没起来 | `rm -f "$APP/Contents/Config/ipcserver.pid"`，再 `pkill -f ipcserver` | 5 秒 |
| 菜单栏 / 程序坞显示 `MilkGame` | 显示名被改回去了 | `bash _build/02_清理与校验.sh` | 10 秒 |
| 弹「想要访问可移除宗卷上的文件」 | App 在固态上，首次启动系统要授权 | 点**允许**（一次性） | 1 秒 |
| 想改画质 / 全屏 | 游戏内设置，不是启动器 | 进游戏 → 设置；配置存在 `~/Library/Preferences/com.storytaco.pc01client.plist` | — |
| 存档没了 | — | 见第 6 节，`userdata.sav` 是唯一存档文件 | — |
| App 整个没了 | — | 从 dmg 重装，见第 3 节 | 约 15 分钟 |

**结论：只有「App 整个没了」才需要走第 3 节，其余都是几秒钟的小事。**

---

## 第 1 节 · 现状快照

```
/Volumes/SSD/Game/
├── 原始包/
│   └── 美女室友竟然.dmg                                   26 GB   干净底本（只读，别删）
└── MilkGame/
    └── 美女室友竟然.app                                    31 GB   游戏本体（自包含，双击即玩）

/Volumes/SSD/Game/游戏构建/MilkGame/
├── 重建实操指引.md                                          本文件
└── _build/
    ├── 01_部署.sh          从 dmg 展开 → 清理 → 重签（换机时一条命令）
    ├── 02_清理与校验.sh     清残留 / 装启动器 / 改显示名 / 重签 / 去隔离
    ├── 03_体检.sh          启动一次、等窗口、截图、报进程
    └── load_clean.sh       清理版启动器（替换 App 内的 Contents/MacOS/load）
```

**关键技术栈**：

```
Unity 2022.3.53f1 (df4e529d20d3) 通用二进制（x86_64 + arm64）
  → 原生 Mach-O，Apple Silicon 上直接跑 arm64，不经过 Rosetta 2
  → Metal 3 → Apple M4 GPU
  → Steamworks 被 Nemirtingas SteamEmu（nsteame）接管：ipcserver + steamclient.dylib
```

**版本坐标（重建后必须对得上）**：

| 组件 | 版本 / 标识 |
|---|---|
| 游戏 | 美女室友竟然 S1，`CFBundleShortVersionString = 1.3.0`（外层 plist 写 2025.04.21） |
| Unity | 2022.3.53f1，build guid `df4e529d20d3` |
| Bundle ID | `com.storytaco.pc01client`（**别改**，存档和偏好设置都挂在这个 ID 上） |
| Steam AppID | `3021100`（`Contents/Config/steam_appid.txt`） |
| Steam 模拟器 | Nemirtingas SteamEmu，配置 `Contents/Config/nsteame_settings/NemirtingasSteamEmu.json` |
| 主体积 | 31 GB，其中 `Data/resources.resource` 单文件 33,441,571,867 字节（FMV 视频全在里面） |
| 宿主 | macOS 15.6，MacBook Air M4 / 16 GB |

> **和前四个游戏的区别**：这个不用 Wine。原始包提供的就是**官方 macOS 构建**（通用二进制），
> 所以能做到真原生：零翻译层、零 prefix、冷启动约 20 秒。S2 那个 Mac DMG 同理。

---

## 第 2 节 · 结构说明（为什么是「两层 App」）

```
美女室友竟然.app/                      ← 外层：壳，负责设环境 + 起 Steam 模拟器
└── Contents/
    ├── Info.plist                    CFBundleExecutable = load
    ├── MacOS/
    │   ├── load                      ← 启动器（我们替换成了清理版）
    │   ├── ipcserver                 Steam 模拟器的 IPC 服务端
    │   ├── steamclient.dylib         假 steamclient（游戏通过 DYLD 加载它）
    │   └── reset                     原包的 launchd 辅助工具（现在不用）
    ├── Config/
    │   ├── steam_appid.txt           3021100
    │   └── nsteame_settings/         模拟器配置 + applogs.txt
    ├── Resources/
    │   └── load.orig.sh              原版启动器备份（只作对照，别执行）
    └── Game/
        └── MilkGame.app/             ← 内层：真正的 Unity 游戏（31 GB 全在这）
```

外层存在的唯一理由：**在启动游戏之前把三个环境变量塞进去**，这是 Steam 模拟器工作的前提。

```sh
SteamAppId=3021100
SteamGameId=3021100
STEAMEMU_SETTINGS_DIR=…/Contents/Config
DYLD_LIBRARY_PATH=…/Contents/MacOS      # 让游戏找到 steamclient.dylib
```

把内层直接双击是**不行**的——没有这几个变量，游戏会卡在 SteamAPI_Init 然后自己退出。

---

## 第 3 节 · 从零部署（换 Mac / App 丢了走这里）

前提：固态挂在 `/Volumes/SSD`，`原始包/美女室友竟然.dmg` 在。全程不需要 sudo，不改系统设置。

```sh
cd "/Volumes/SSD/Game/游戏构建/MilkGame/_build"
bash 01_部署.sh
```

脚本做三件事：

1. **只读挂载** dmg 到 `/tmp/fh_mnt`（`-nobrowse`，不弹 Finder 窗口）
2. `cp -Rp` 展开 `MilkGame.app` → `/Volumes/SSD/Game/MilkGame/美女室友竟然.app`（约 31 GB，5–10 分钟）
3. 调 `02_清理与校验.sh` 收尾

> **为什么用 `cp -Rp` 而不是 `ditto`**：ditto 会先把每个文件写成 `.BC.T_xxxxxx` 临时名再改名，
> 一旦改名被拦（受限环境、只读目标），整包会停在一堆临时文件上——而临时名一眼看不出是 31 GB 的正片，
> 清理残留时极易连正片一起删掉。`cp -Rp` 直接落到最终文件名，没有这个坑。

想自己一步步来：

```sh
hdiutil attach -readonly -nobrowse -mountpoint /tmp/fh_mnt "/Volumes/SSD/Game/原始包/美女室友竟然.dmg"
cp -Rp "/tmp/fh_mnt/MilkGame.app" "/Volumes/SSD/Game/MilkGame/美女室友竟然.app"
hdiutil detach /tmp/fh_mnt
bash 02_清理与校验.sh
```

---

## 第 4 节 · 清理清单（改了什么、为什么）

原包是第三方二次打包的，外壳里塞了几样**不能留**的东西。逐条记下来，免得下次又踩。

| # | 原包里的东西 | 处理 | 原因 |
|---|---|---|---|
| 1 | `双击修复损毁`（dmg 根目录） | **不复制、不执行** | 它执行 `sudo spctl --master-disable`，把整台机器的 Gatekeeper 关掉。为了开一个游戏而永久削弱系统防线，不能接受 |
| 2 | `load` 里的 `launchctl remove/load com.valvesoftware.steam.ipctool` | 删除 | 往用户的 launchd 里装卸服务＝改系统设置。本机没装 Steam，这两行纯属空转 |
| 3 | `load` 里的 `pkill ipcserver` | 改成 pid 文件精确回收 | 全局 pkill 会误杀同时运行的其它实例 |
| 4 | `steam_appid.txt` 放在 `Contents/MacOS/` | 挪到 `Contents/Config/` | `Contents/MacOS` 只该放可执行代码。混入纯文本后 `codesign` 直接报 `code object is not signed at all`，整个签名流程卡死 |
| 5 | 模拟器身份：`fengqs2` / `76561198441937569` | `Player` / `76561197960287930` | 原包带着打包者随机生成的账号名，换台机器没意义，也不该顶着别人的 ID |
| 6 | `CFBundleName = MilkGame` | `美女室友竟然` | 程序坞、菜单栏、Finder 都显示这个名字。Bundle ID 保持不变，存档路径不受影响 |
| 7 | dmg 里的 `常见问题.rtf`、`.background/`、`.DS_Store` | 不复制 | 广告站链接和窗口背景图，与游戏无关 |
| 8 | `Contents/Resources/load.orig.sh` | **保留**（只作对照） | 想确认「原版到底改了什么」时用，不要执行 |

清理后仍然保留的东西：`ipcserver`、`steamclient.dylib`、`reset`（42 KB，不再调用，删了怕影响模拟器的自检逻辑）、
`_CodeSignature`（重签后由系统重写）。

---

## 第 5 节 · 坑位清单（这次真踩到的）

1. **`ditto` 在受限环境里会整包变成临时文件**
   现象：复制「完成」后目录里全是 `.BC.T_xxxxxx`，目标文件名一个都没有；删残留时 31 GB 一起没了。
   解法：用 `cp -Rp`，或者复制完先 `find -name '.BC.T_*'` 数一下再决定删不删。

2. **`Contents/MacOS` 里不能有非可执行文件**
   现象：`codesign` 报 `code object is not signed at all`，`In subcomponent: …/steam_appid.txt`。
   解法：数据文件挪到 `Contents/Config`，启动器改成从那里读（`load_clean.sh` 已兼容两个位置）。

3. **内层重签很慢，别以为卡死了**
   33 GB 的 `resources.resource` 要整体哈希一遍：实测 **4 分 26 秒**（USB 固态）。
   所以 `02` 脚本只在「显示名真的变了」时才重签内层，平时只签外层（秒级）。
   要强制重签：`bash 02_清理与校验.sh "$APP" --force-inner`。

4. **外层 `CFBundleExecutable` 是个 shell 脚本**
   签名能通过，但**必须** `xattr -cr` 清干净；带着 `com.apple.provenance` 之类属性会 `SIGKILL`。

5. **挂载 dmg 一定加 `-nobrowse`**
   否则 Finder 会弹一个窗口，打断正在跑的自动化。

6. **游戏默认不写日志**
   `~/Library/Logs/Unity/` 是空的。要排查就手动带参数跑一条：

   ```sh
   APP="/Volumes/SSD/Game/MilkGame/美女室友竟然.app"
   export SteamAppId=3021100 SteamGameId=3021100 \
          STEAMEMU_SETTINGS_DIR="$APP/Contents/Config" \
          DYLD_LIBRARY_PATH="$APP/Contents/MacOS"
   cd "$APP/Contents/MacOS" && ./ipcserver & \
   "$APP/Contents/Game/MilkGame.app/Contents/MacOS/MilkGame" -logfile /tmp/fh_unity.log
   ```

   日志里这几条是**正常噪音**，不用管：
   - `Metal: Error creating pipeline state (UI/BlurNomal)` —— 一个 UI 模糊 shader 不兼容，游戏自动降级
   - `error messaging the mach port for IMKCFRunLoopWakeUpReliable` —— 输入法与后台进程通信的提示
   - `DOTWEEN ► SAFE MODE ► … 5 missing target or field errors` —— UI 补间找不到目标，引擎自己兜住了

7. **`ipcserver` 退出不干净会挡住下一次启动**
   `load_clean.sh` 用 `Contents/Config/ipcserver.pid` 精确回收；pid 文件残留就手动删。

---

## 第 6 节 · 存档与设置

| 内容 | 位置 |
|---|---|
| 存档 | `~/Library/Application Support/com.storytaco.pc01client/SavesDir/userdata.sav` |
| 画质 / 音量 / 语言 | `~/Library/Preferences/com.storytaco.pc01client.plist` |
| 模拟器日志 | `Contents/Config/nsteame_settings/applogs.txt`（`LogLevel: off`，正常是空的） |

- 备份存档只要拷 `SavesDir` 这一个目录。
- 换机器后把 `SavesDir` 放回同一路径即可，游戏认的是 Bundle ID，不是路径。
- 语言默认 `ChineseSimplified`（`Storytaco_Localization`），别在 plist 里手改成英文除非你想要英文。

---

## 第 7 节 · 验收（三步，30 秒）

```sh
APP="/Volumes/SSD/Game/MilkGame/美女室友竟然.app"

# 1. 签名有效
codesign --verify --strict "$APP" && echo "签名 OK"

# 2. 去隔离
xattr -cr "$APP"

# 3. 启动并截图（默认等 35 秒）
bash "/Volumes/SSD/Game/游戏构建/MilkGame/_build/03_体检.sh"
```

做对了会看到：进程 `…/Game/MilkGame.app/Contents/MacOS/MilkGame` 在跑、
一个 1920×1080 或全屏的游戏窗口、截图里是标题画面。

---

## 第 8 节 · 不可再生清单

| 东西 | 位置 | 说明 |
|---|---|---|
| 原始 dmg | `/Volumes/SSD/Game/原始包/美女室友竟然.dmg`（26 GB） | 丢了要重新找源；App 能从它完整重建 |
| 内层 Unity 资源 | App 里的 `Data/resources.resource`（33.4 GB） | 全部 FMV 视频，没有单独备份渠道 |

App 本体、签名、启动器都能从 dmg 重新生成，只有上面两样是根。

---

## 第 9 节 · 和 Season 2 的关系

固态 `原始包/` 里还有一份 `Five.Hearts.Under.One.Roof.season.2.v2025.11.24.MacOS-U2B.dmg`（26 GB），
是**第二季的原生 Mac 包**，结构和这一份同源（同样两层 App + Nemirtingas 模拟器）。

要做第二季时，把 `01_部署.sh` 里的 dmg 路径和 App 名换掉即可，`02` / `03` 不用改；
唯一要确认的是内层 `.app` 的名字（不叫 `MilkGame.app` 的话，`02` 里的 `$INNER` 要跟着改）。

> 早前那份 Windows 分卷安装包（`Downloads/原包/…win7,win10,win11…`）只下到 5.8%，
> 而且安装器带机器码授权校验——那条路已经放弃，不用再回头。

---

最后更新：2026-11-05
