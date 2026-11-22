#!/usr/bin/env python3
"""霍格沃茨之遗 mod 兼容性预检（v1613387）

用法：
    python3 check_mod.py <文件或目录> [...]
    python3 check_mod.py ~/Downloads/*.zip ~/Downloads/*.rar

判定依据（全部实测，不是猜的）：

  1. **Lua 脚本 mod 一律不可用**
     形态是 `<名字>/Scripts/main.lua` + `enabled.txt`，或 `Phoenix/Binaries/Win64/Mods/...`。
     这类要 UE4SS 注入才跑得起来。而在 450 MB 的主 exe 里搜 `main.lua` / `enabled.txt` /
     `ue4ss` 全是 0 命中 —— 游戏本体根本没有 Lua 加载器，官方 mod 系统只认 `*.pak`
     （exe 里是 `EModsDirectoryMode::CFCore / Flat / None` + `modsDirectory`）。
     没装 UE4SS 就等于装了不生效，装了 UE4SS 又和 v1613387 版本对不上。

  2. **挂载点**必须落在 `Phoenix/Content/` 下。写成 `MyProject/`、`Hermione_Wand/`
     是打包错误，游戏永远读不到。

  3. **改的是哪类资源**决定风险，但**上传日期才是真正的兼容信号**：
       HEADS / HAIR + 2025-12-03 之前 → 高危（结构已变，实测必崩）
       HEADS / HAIR + 2025-12-03 之后 → 可试（当前版本做的，崩了删掉即可）
       CLOTHING / UI / SCRIPT / CONFIG → 低
       SQLiteDB → 只能同时存在一个（UE 整份覆盖，不合并）

  4. **legacy .pak 的 Offset 陷阱**：有些打包工具把 FPakEntry 内联写在数据前面却没改
     Offset（还是 0），游戏读到的是文件头不是数据 —— 这类包从来没生效过。

v1613387 = 官方 2025-12-03 的 PC 热修（Steam BuildID 20773316），也就是当前最新版。
"""

import datetime
import os
import re
import struct
import subprocess
import sys
import tempfile

PAK_MAGIC = 0x5A6F12E1
UTOC_MAGIC = b"-==--==--==--==-"
V1613387_DATE = datetime.date(2025, 12, 3)

RISK = {
    "LUA":      ("不可用", "Lua 脚本 mod，需要 UE4SS；本机没装，游戏本体也不加载 Lua"),
    "HEADS":    ("高",     "头部网格替换"),
    "HAIR":     ("高",     "发型网格替换"),
    "CLOTHING": ("低",     "服装类，不碰头部骨骼"),
    "DATA":     ("中",     "替换游戏数据库，只能同时存在一个"),
    "UI":       ("低",     "界面蓝图/贴图"),
    "SCRIPT":   ("低",     "蓝图类，走 BP Apparate"),
    "CONFIG":   ("低",     "配置文件覆盖"),
    "UNKNOWN":  ("?",      "无法判断"),
}


# ------------------------------------------------------------------ 工具

def _fstr(b, o):
    (n,) = struct.unpack_from("<i", b, o)
    o += 4
    if n == 0:
        return "", o
    if n < 0:
        return b[o:o + (-n) * 2].decode("utf-16-le", "replace").rstrip("\x00"), o + (-n) * 2
    return b[o:o + n - 1].decode("utf-8", "replace"), o + n


def read_pak(path):
    d = open(path, "rb").read()
    if len(d) < 44:
        raise ValueError("文件太小")
    info = d[-44:]
    magic, _ = struct.unpack("<II", info[0:8])
    if magic != PAK_MAGIC:
        raise ValueError("没有 FPakInfo")
    idx_off, idx_size = struct.unpack("<qq", info[8:24])
    idx = d[idx_off:idx_off + idx_size]
    o = 0
    mount, o = _fstr(idx, o)
    (cnt,) = struct.unpack_from("<i", idx, o)
    o += 4
    entries = []
    for _ in range(cnt):
        name, o = _fstr(idx, o)
        off, size, unc = struct.unpack_from("<qqq", idx, o)
        o += 24
        (method,) = struct.unpack_from("<I", idx, o)
        o += 4
        o += 20
        if method != 0:
            (nb,) = struct.unpack_from("<i", idx, o)
            o += 4 + nb * 16
        o += 5
        entries.append(dict(name=name, offset=off, size=size, unc=unc, method=method))
    return mount, entries, d


def read_utoc(path):
    d = open(path, "rb").read()
    if not d.startswith(UTOC_MAGIC):
        raise ValueError("不是 IoStore .utoc")
    ver = d[16]
    paths = set()
    for m in range(len(d) - 7):
        if d[m:m + 7] == b".uasset":
            s = m
            while s > 0 and 32 <= d[s - 1] < 127:
                s -= 1
            paths.add(d[s:m + 7].decode("ascii", "replace"))
    return ver, sorted(paths)


def ucas_mount(utoc_path):
    ucas = utoc_path[:-5] + ".ucas"
    if not os.path.exists(ucas):
        return ""
    blob = open(ucas, "rb").read(8192)
    m = blob.find(b"Phoenix/")
    if m < 0:
        m = blob.find(b"phoenix/")
    if m < 0:
        return ""
    s = m
    while s > 0 and blob[s - 1:s] in (b".", b"/"):
        s -= 1
    return blob[s:m + 8].decode("ascii", "replace")


def classify(paths):
    j = " ".join(paths).lower()
    if "head_sc" in j or "/heads/" in j or "headbase" in j:
        return "HEADS"
    if "_hair" in j or "/hair" in j or "stuhair" in j or "haircap" in j:
        return "HAIR"
    if any(k in j for k in ("clothing", "jacket_", "pants_", "_low_", "_upp_",
                            "outfit", "dada", "robe", "glove", "cloak", "mask")):
        return "CLOTHING"
    if "sqlitedb" in j or ".sqlite" in j:
        return "DATA"
    if "/ui/" in j or "ui_bp_" in j or "reticle" in j:
        return "UI"
    if "/script/" in j or "blueprint" in j or "apparate" in j:
        return "SCRIPT"
    if any(p.lower().endswith(".ini") for p in paths):
        return "CONFIG"
    return "UNKNOWN"


def date_from_name(name):
    """从 Nexus 下载文件名里取上传日期。两种格式：
       xxx-2399-1-0-1766549757.zip        → 结尾 10 位 epoch
       xxx 2595 1.0.2 2026-10-27T21-41Z.zip → 中间 ISO 片段
    """
    m = re.search(r"-(\d{10})\.(?:zip|rar|7z)$", name, re.I)
    if m:
        try:
            return datetime.date.fromtimestamp(int(m.group(1)))
        except (ValueError, OSError):
            pass
    m = re.search(r"(\d{4})-(\d{2})-(\d{2})T\d{2}-\d{2}Z", name)
    if m:
        try:
            return datetime.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except ValueError:
            pass
    return None


# ------------------------------------------------------------------ 扫描

def scan_tree(root):
    """返回 (findings, is_lua, first_mtime)"""
    paks, utocs, inis = [], [], []
    lua = False
    mtime = None
    for dp, _dn, fs in os.walk(root):
        for f in fs:
            full = os.path.join(dp, f)
            low = f.lower()
            if low.endswith(".pak"):
                paks.append(full)
            elif low.endswith(".utoc"):
                utocs.append(full)
            elif low.endswith(".ini"):
                inis.append(full)
            elif low == "main.lua" or low == "enabled.txt":
                lua = True
            if "binaries/win64/mods" in full.lower().replace("\\", "/"):
                lua = True
            if mtime is None:
                try:
                    mtime = os.path.getmtime(full)
                except OSError:
                    pass
    return paks, utocs, inis, lua, mtime


def analyze(paks, utocs, inis, lua, label, date):
    rows = []
    if lua:
        rows.append(dict(name=label, kind="LUA", paths=[], note="Scripts/main.lua + enabled.txt"))
        return rows

    # utoc 优先（IoStore 的真数据在里面）
    for u in utocs:
        base = os.path.basename(u)[:-5]
        try:
            ver, paths = read_utoc(u)
        except ValueError as e:
            rows.append(dict(name=base, kind="UNKNOWN", paths=[], note=str(e)))
            continue
        kind = classify(paths)
        if not paths:
            rows.append(dict(name=base, kind="UNKNOWN", paths=[],
                             note=f"IoStore v{ver}，资源列表读不出（索引压缩/加密）"))
            continue
        note = f"IoStore v{ver}，{len(paths)} 个资源"
        mount = ucas_mount(u)
        if mount and not mount.lower().startswith("../../../phoenix"):
            note += f"；挂载点异常（{mount}）→ 永不生效"
        rows.append(dict(name=base, kind=kind, paths=paths, note=note))

    # 没有 utoc 的 legacy pak
    for p in paks:
        base = os.path.basename(p)
        if any(os.path.basename(u)[:-5] == base[:-4] for u in utocs):
            continue                       # 已经被 utoc 那条覆盖
        sz = os.path.getsize(p)
        try:
            mount, entries, d = read_pak(p)
        except ValueError:
            if sz < 1024:
                rows.append(dict(name=base, kind="SCRIPT", paths=[],
                                 note=f"{sz} 字节 IoStore 存根（真数据在同名 .ucas/.utoc）"))
            else:
                rows.append(dict(name=base, kind="UNKNOWN", paths=[],
                                 note=f"{sz} 字节但没有索引 → 坏包，游戏读不到"))
            continue
        names = [e["name"] for e in entries]
        kind = classify(names + [mount])
        notes = [f"{len(entries)} 个条目"]
        if not mount.lower().startswith("../../../phoenix"):
            notes.append(f"挂载点异常（{mount}）→ 永不生效")
        if entries and entries[0]["method"] == 0 and entries[0]["offset"] == 0 \
                and b"SQLite format 3" in d[:4096]:
            notes.append("Offset 写成 0 但数据在 53 字节后 → 从来没生效过")
        rows.append(dict(name=base, kind=kind, paths=names, note="；".join(notes)))

    for i in inis:
        rows.append(dict(name=os.path.basename(i), kind="CONFIG", paths=[],
                         note="配置文件，直接覆盖生效"))
    if not rows:
        rows.append(dict(name=label, kind="UNKNOWN", paths=[], note="没找到 .pak/.utoc/.ini/.lua"))
    return rows


def verdict(row, date):
    kind = row["kind"]
    risk, why = RISK[kind]
    note = row["note"]

    if "永不生效" in note or "从来没生效过" in note or "坏包" in note:
        return "❌ 别装", "包本身有问题，装了等于没装"
    if kind == "LUA":
        return "❌ 别装", "游戏本体没有 Lua 加载器，UE4SS 也没装"
    if kind in ("HEADS", "HAIR"):
        if date and date >= V1613387_DATE:
            return "⚠️ 可试", f"{date} 上传，晚于 v1613387，崩了就删"
        d = date.isoformat() if date else "日期未知"
        return "❌ 高危", f"{d}，早于 v1613387，头部结构已变，实测必崩"
    if kind == "DATA":
        return "⚠️ 只能一个", "数据库整份覆盖，装了就要把别的数据库 mod 移走"
    if kind == "UNKNOWN":
        return "? 未知", "读不出资源，装前先备份"
    return "✅ 可装", why


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2

    tmp = tempfile.mkdtemp(prefix="hlmod.")
    results = []

    for arg in argv[1:]:
        p = os.path.expanduser(arg)
        if not os.path.exists(p):
            print(f"跳过（不存在）：{p}")
            continue

        if os.path.isdir(p):
            paks, utocs, inis, lua, mt = scan_tree(p)
            date = datetime.date.fromtimestamp(mt) if mt else None
            for r in analyze(paks, utocs, inis, lua, os.path.basename(p), date):
                results.append((os.path.basename(p), r, date))
            continue

        date = date_from_name(os.path.basename(p))
        dest = os.path.join(tmp, re.sub(r"[^\w.-]", "_", os.path.basename(p)))
        os.makedirs(dest, exist_ok=True)
        if p.lower().endswith((".zip", ".rar", ".7z")):
            subprocess.run(["/usr/bin/tar", "-xf", p, "-C", dest],
                           check=False, capture_output=True)
            paks, utocs, inis, lua, mt = scan_tree(dest)
            if date is None and mt:
                date = datetime.date.fromtimestamp(mt)
            for r in analyze(paks, utocs, inis, lua, os.path.basename(p), date):
                results.append((os.path.basename(p), r, date))
        else:
            kind = "utoc" if p.lower().endswith(".utoc") else "pak"
            paks = [p] if kind == "pak" else []
            utocs = [p] if kind == "utoc" else []
            inis = [p] if p.lower().endswith(".ini") else []
            for r in analyze(paks, utocs, inis, False, os.path.basename(p), date):
                results.append((os.path.basename(p), r, date))

    print(f"{'mod / 文件':<34}{'日期':<12}{'类型':<10}{'结论':<12}说明")
    print("-" * 118)
    for src, r, date in results:
        v, why = verdict(r, date)
        ds = date.isoformat() if date else "—"
        print(f"{r['name'][:32]:<34}{ds:<12}{r['kind']:<10}{v:<12}{r['note']}")
        if r["paths"]:
            print(f"{'':<34}{'':<12}{'':<10}{'':<12}改的资源：{', '.join(r['paths'][:4])}"
                  + (" …" if len(r["paths"]) > 4 else ""))
        print(f"{'':<34}{'':<12}{'':<10}{'':<12}→ {why}")

    print()
    bad = [x for x in results if verdict(x[1], x[2])[0].startswith("❌")]
    ok = [x for x in results if verdict(x[1], x[2])[0].startswith("✅")]
    trial = [x for x in results if verdict(x[1], x[2])[0].startswith("⚠️")]
    print(f"汇总：✅ 可装 {len(ok)} 个 ｜ ⚠️ 可试/受限 {len(trial)} 个 ｜ ❌ 别装 {len(bad)} 个")
    if bad:
        print("❌ 这些直接删掉，不用试：")
        for src, r, _d in bad:
            print(f"   · {r['name']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
