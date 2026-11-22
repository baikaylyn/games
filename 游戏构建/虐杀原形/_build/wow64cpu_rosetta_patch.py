#!/usr/bin/env python3
"""给 wow64cpu.dll 打 Rosetta 2 模式切换补丁（虐杀原形启动崩溃的根治手段）。

## 为什么需要它

虐杀原形是 PE32（32 位）游戏，在 Apple Silicon 上走 Wine 的 WoW64：一个 64 位进程里
装载 32 位 PE，每次系统调用都要在 32 位和 64 位模式之间切换。Rosetta 2 在某些情况下
**没有真正切换模式**，于是 CPU 还在 32 位模式下执行 64 位的转移指令，把指令里的位移
字段当成地址去读，产生这类崩溃：

    wine: Unhandled page fault on read access to 00002DC1 at address 7BF21239
    err:virtual:virtual_setup_exception nested exception on signal stack ...
    err:seh:NtRaiseException Exception frame is not in stack limits ...

其中 0x7BF20000 是 wow64cpu.dll 的装载基址，偏移 0x1239 / 0x1135 分别是 syscall 和
unixcall 两个 32→64 位入口 thunk。反汇编能看到它们在 32 位模式下被解码成
`mov edx,[rip+0x2dc1]`，读到的就是那个不存在的低地址。

## 补的是什么

1. 32→64 位入口（两个 thunk）：改成先跳到一段"能判断当前 CPU 模式"的 trampoline，
   用 push cs / retf 重新做一次远转移，直到真正进入 64 位模式为止。
2. 64→32 位返回（两个 ljmp 站点）：改成在 64 位栈上构造 iretq 帧后 iretq 返回，
   和 wow64cpu 自己的全上下文返回路径一致（直接 ljmp 有时不会切回 32 位）。

## 来源与适配

补丁逻辑取自 altium-wine 项目的 patches/wow64cpu-rosetta-trampoline.py（针对
wine-staging 11.16 编写，脚本会校验字节、不匹配就拒绝打）。本机是 wine-staging 11.18，
实测四个站点的字节**完全一致**，代码洞（.text 尾部 0xCC 填充）也够用，因此可直接套用。

## 用法

    python3 wow64cpu_rosetta_patch.py --check    # 只校验，不改文件
    python3 wow64cpu_rosetta_patch.py            # 打补丁（先备份 .orig）
    python3 wow64cpu_rosetta_patch.py --revert   # 从 .orig 还原

打完必须重新签名（脚本不会自动做，见输出提示）：
    codesign --force --deep -s - ~/Games/Prototype/Prototype.app
"""
import argparse
import hashlib
import os
import shutil
import struct
import sys

DLL = os.path.expanduser(
    "~/Games/Prototype/Prototype.app/Contents/Resources/Wine/lib/wine/x86_64-windows/wow64cpu.dll")

# wine-staging 11.16/11.18 (x86_64-windows) 的绝对地址
SYSCALL_ENTRY = 0x7A40110C
UNIXCALL_ENTRY = 0x7A401210
LEA_SYSCALL = (0x7A40140E, 0x7A401415, bytes.fromhex("488d0d"), -0x309)
LEA_UNIXCALL = (0x7A401430, 0x7A401437, bytes.fromhex("488d15"), -0x227)
RETURN_SITES = (0x7A4011A2, 0x7A40128B)
RETURN_BYTES = bytes.fromhex("458bb5c4000000" "4987e6" "41ff2e")


def load(path):
    b = bytearray(open(path, "rb").read())
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    optsize = struct.unpack_from("<H", b, pe + 20)[0]
    base = struct.unpack_from("<Q", b, pe + 24 + 24)[0]
    sec0 = pe + 24 + optsize
    secs = []
    for i in range(nsec):
        s = sec0 + 40 * i
        vs, va, rs, ro = struct.unpack_from("<IIII", b, s + 8)
        secs.append((vs, va, rs, ro, s))

    def off(v):
        r = v - base
        for vs, va, rs, ro, _ in secs:
            if va <= r < va + rs:
                return ro + r - va
        raise SystemExit("地址 0x%x 不在文件内" % v)

    return b, base, secs, off


def verify(b, off):
    """校验四个站点——任何一个不匹配就说明这不是我们验证过的构建，拒绝打。"""
    for at, nxt, opc, disp in (LEA_SYSCALL, LEA_UNIXCALL):
        o = off(at)
        if bytes(b[o:o + 3]) != opc or struct.unpack_from("<i", b, o + 3)[0] != disp:
            return False, "0x%x 处字节不符（期望 %s）" % (at, opc.hex())
    for at in RETURN_SITES:
        if bytes(b[off(at):off(at) + len(RETURN_BYTES)]) != RETURN_BYTES:
            return False, "0x%x 处返回序列不符" % at
    return True, "四个站点全部匹配"


# 补丁写在 .text 尾部代码洞的起点，这 6 个字节就是 trampoline 的开头（xor ecx,ecx / 41 89 c9 / e3）
TRAMP_SIG = bytes.fromhex("31c94189c9e3")


def state(b, off, secs, base):
    """返回 'patched' / 'stock' / 'unknown'。

    不能按 VirtualSize 反推 trampoline 位置——打完补丁 VirtualSize 会被改大，
    再算一次就漂了（踩过）。直接在整个 .text 的原始数据里找补丁签名。"""
    text_vs, text_va, text_rs, text_ro = secs[0][0], secs[0][1], secs[0][2], secs[0][3]
    if TRAMP_SIG in b[text_ro:text_ro + text_rs]:
        return "patched"
    ok, _ = verify(b, off)
    return "stock" if ok else "unknown"


def plan(base, secs, off):
    text_vs, text_va, text_rs, _, text_hdr = secs[0]
    tramp1 = base + text_va + ((text_vs + 0xF) & ~0xF) + 0x10
    tramp2 = tramp1 + 0x20
    ret1 = tramp1 + 0x40
    ret2 = tramp1 + 0x80
    end = ret2 + 0x40
    if end - base - text_va > text_rs:
        raise SystemExit("代码洞不够大")
    return tramp1, tramp2, ret1, ret2, end, text_hdr


def patch(src):
    b, base, secs, off = load(src)
    ok, why = verify(b, off)
    if not ok:
        raise SystemExit("拒绝打补丁：" + why)
    tramp1, tramp2, ret1, ret2, end, text_hdr = plan(base, secs, off)
    if any(x not in (0, 0xCC) for x in b[off(tramp1):off(tramp1) + (end - tramp1)]):
        raise SystemExit("代码洞不干净（可能已经打过补丁）")

    def put(addr, code):
        b[off(addr):off(addr) + len(code)] = code

    def tramp(addr, real):
        code = bytes.fromhex("31c9" "4189c9" "e30d" "e800000000" "59" "83c1f4" "6a2b" "51" "cb")
        return code + b"\xe9" + struct.pack("<i", real - (addr + 0x19))

    put(tramp1, tramp(tramp1, SYSCALL_ENTRY))
    put(tramp2, tramp(tramp2, UNIXCALL_ENTRY))
    for (at, nxt, _, _), tgt in ((LEA_SYSCALL, tramp1), (LEA_UNIXCALL, tramp2)):
        struct.pack_into("<i", b, off(at) + 3, tgt - nxt)

    stub = bytes.fromhex(
        "4989e6" "8b1424" "48891424" "418b95bc000000" "4889542408"
        "9c" "5a" "4889542410" "418b95c4000000" "4889542418"
        "418b95c8000000" "4889542420" "48cf")
    put(ret1, stub)
    put(ret2, stub)
    for at, tgt in zip(RETURN_SITES, (ret1, ret2)):
        put(at, b"\xe9" + struct.pack("<i", tgt - (at + 5)) + b"\xcc" * (len(RETURN_BYTES) - 5))

    struct.pack_into("<I", b, text_hdr + 8, ret2 + len(stub) - base - secs[0][1])
    open(src, "wb").write(b)
    return tramp1, tramp2, ret1, ret2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只校验，不修改")
    ap.add_argument("--revert", action="store_true", help="从 .orig 还原")
    ap.add_argument("--dll", default=DLL)
    a = ap.parse_args()
    dll = os.path.expanduser(a.dll)

    if a.revert:
        bak = dll + ".orig"
        if not os.path.exists(bak):
            raise SystemExit("找不到备份 " + bak)
        shutil.copyfile(bak, dll)
        print("已还原 %s（重新签名后生效）" % dll)
        return

    b, base, secs, off = load(dll)
    st = state(b, off, secs, base)
    ok, why = verify(b, off)
    print("当前文件：%s" % dll)
    print("sha256(前16位)：%s" % hashlib.sha256(bytes(b)).hexdigest()[:16])
    label = {"patched": "已打补丁", "stock": "未打补丁（原版）", "unknown": "未知构建"}[st]
    print("状态：%s" % label)
    if st == "stock":
        print("站点校验：%s" % why)
    if a.check:
        return
    if st == "patched":
        print("已经打过了，不用重复打。要还原用 --revert。")
        return
    if st == "unknown":
        raise SystemExit("拒绝打补丁：%s，不是验证过的构建" % why)

    bak = dll + ".orig"
    if not os.path.exists(bak):
        shutil.copyfile(dll, bak)
        print("已备份原文件 → %s" % bak)
    t = patch(dll)
    print("补丁完成：trampoline 0x%X / 0x%X，iretq 返回桩 0x%X / 0x%X" % t)
    print("新 sha256(前16位)：%s" % hashlib.sha256(open(dll, "rb").read()).hexdigest()[:16])
    print("\n下一步必须重新签名：")
    print("  codesign --force --deep -s - ~/Games/Prototype/Prototype.app")


if __name__ == "__main__":
    sys.exit(main())
