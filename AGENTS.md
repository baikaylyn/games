# AGENTS.md · 游戏台

> 给所有 AI 工具的交接说明。**开工前先读本文件，收工后更新「最近变更」再提交。**
> 更新时间：2026-11-22

## 定位

游戏存档、MOD、构建文档与脚本的归档区。游戏本体大多不在本目录。

## 技术栈

- Shell 脚本 + Markdown 文档
- 无应用代码

## 目录

| 路径 | 内容 |
|---|---|
| `霍格沃茨之遗/存档备份/` | 5 份存档，按 `YYYYMMDD-备注` 命名 |
| `霍格沃茨之遗/mods备份/20261030/` | MOD 文件约 284M（.pak/.ucas/.utoc） |
| `霍格沃茨之遗/文档/` | MOD 制作过程存档，改 mod 前先看 |
| `虐杀原形/` | 仅 `说明.md`；本体在 `/Volumes/SSD/Game/Prototype/Prototype.app`（8.7G） |
| `游戏构建/` | 6 个游戏的重建文档 + `_build` 源码，由 `_同步到本机.sh` 从 SSD 同步 |
| `_脚本/打包到硬盘或网盘.command` | 塞尔达打包脚本 |

## 常用命令

```bash
游戏构建/_同步到本机.sh    # 从 SSD 同步构建源码
```

## 当前状态

- 2026-11-06 按《文件整理规则.md》重组，原名 `~/Games`
- 旧路径 `~/Games` 仍可用（软链接指向本目录）
- `_空备份-20261102-175746` 为空目录，确认后可删

## 注意事项

- **`游戏构建/` 的结构不要手动改动**，否则下次同步会错位；SSD 上的 `/Volumes/SSD/Game/游戏构建/` 是权威源，本机是镜像
- 游戏本体在 SSD，不要复制回本地
- 存档是唯一副本，操作前先备份；存档生效位置是 `~/Library/Application Support/MacNativeGames/HOGWARTS`，本目录只是备份
- 虐杀原形的 Wine prefix 在 `~/Library/Application Support/MacNativeGames/PROTOTYPE`（405 M），**不要删**
- 不要执行游戏程序或改动 `mods备份` 内容

## 最近变更

- 2026-11-23 回写总账：补存档生效位置与 Wine prefix 警示
- 2026-11-22 建立本文件

## GitHub 同步

- 远程：`git@github.com:baikaylyn/games.git`（**公开**）
- 最近同步：2026-11-23 首次推送 AGENTS.md；最新提交以 `git log -1` 为准
