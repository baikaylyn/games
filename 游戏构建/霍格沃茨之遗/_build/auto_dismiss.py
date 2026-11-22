#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自动点掉霍格沃茨之遗的「显卡驱动警告」对话框。

为什么需要它：
  D3DMetal 把自己伪装成 NVIDIA 显卡（驱动版本 512.33），游戏启动时会弹一个
  Win32 模态框 "WARNING: Known issues with graphics driver"，不点掉就一直卡住。
  该对话框是 Wine 内部窗口，用 macOS 辅助功能点击会被 TCC 拒绝，
  这里改为：先把 wine 进程激活成前台应用，再用 CGEventPostToPid 直接投递回车键。

用法：python3 auto_dismiss.py <wine进程pid>
"""
import ctypes
import subprocess
import os
import sys
import time

cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
cg.CGEventPostToPid.argtypes = [ctypes.c_int, ctypes.c_void_p]
cf.CFArrayGetCount.restype = ctypes.c_long
cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
cf.CFDictionaryGetValue.restype = ctypes.c_void_p
cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
cf.CFStringGetCStringPtr.restype = ctypes.c_char_p
cf.CFStringGetCStringPtr.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
cf.CFNumberGetValue.restype = ctypes.c_bool
cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p]
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
cf.CFRelease.argtypes = [ctypes.c_void_p]

UTF8 = 0x08000100
DOUBLE = 13


def _key(d, name):
    k = cf.CFStringCreateWithCString(None, name.encode(), UTF8)
    v = cf.CFDictionaryGetValue(d, k)
    cf.CFRelease(k)
    return v


def _str(d, name):
    v = _key(d, name)
    if not v:
        return None
    p = cf.CFStringGetCStringPtr(v, UTF8)
    return p.decode("utf-8", "replace") if p else None


def _num(d, name):
    v = _key(d, name)
    if not v:
        return None
    out = ctypes.c_double(0)
    if cf.CFNumberGetValue(v, DOUBLE, ctypes.byref(out)):
        return out.value
    return None


def window_names(pid):
    arr = cg.CGWindowListCopyWindowInfo(1, 0)  # kCGWindowListOptionAll
    if not arr:
        return []
    names = []
    for i in range(cf.CFArrayGetCount(arr)):
        d = cf.CFArrayGetValueAtIndex(arr, i)
        if not d:
            continue
        if int(_num(d, "kCGWindowOwnerPID") or 0) != pid:
            continue
        names.append(_str(d, "kCGWindowName") or "")
    return names


def activate(pid):
    """把 wine 进程激活成前台应用。先试无需权限的 ObjC 路径，再退回 AppleScript。"""
    js = (
        'ObjC.import("AppKit");'
        'var a=$.NSRunningApplication.runningApplicationWithProcessIdentifier(%d);'
        'a.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);'
        'a.isActive?"1":"0";' % pid
    )
    try:
        r = subprocess.run(["osascript", "-l", "JavaScript", "-e", js],
                           capture_output=True, text=True, timeout=15)
        if r.stdout.strip() == "1":
            return True
    except Exception:
        pass
    try:
        r = subprocess.run(
            ["osascript", "-e", 'tell application id "org.winehq.wine" to activate'],
            capture_output=True, text=True, timeout=15)
        return r.returncode == 0
    except Exception:
        return False


def press_return(pid):
    for down in (True, False):
        e = cg.CGEventCreateKeyboardEvent(None, 36, down)  # 36 = Return
        cg.CGEventPostToPid(pid, e)
        time.sleep(0.05)


def main():
    if len(sys.argv) < 2:
        print("用法: auto_dismiss.py <wine pid>")
        return 2
    pid = int(sys.argv[1])
    deadline = time.time() + 600
    hits = 0
    tried = 0
    while time.time() < deadline:
        # 游戏已经没了就收工 —— 否则这个进程会一直挂着，还占着启动器的锁文件
        try:
            os.kill(pid, 0)
        except OSError:
            print("[auto] 游戏进程已退出，监视结束", flush=True)
            return 0
        names = window_names(pid)
        if any("WARNING" in n for n in names):
            tried += 1
            activate(pid)
            time.sleep(1.5)
            press_return(pid)
            time.sleep(0.4)
            press_return(pid)
            hits += 1
            print("[auto] 已关闭驱动警告对话框（第 %d 次）" % hits, flush=True)
            if tried == 3:
                print("[auto] 提示：若对话框仍在，请直接用鼠标点它的 OK 按钮", flush=True)
            time.sleep(2)
            continue
        if any("Hogwarts Legacy" in n for n in names):
            print("[auto] 游戏窗口已出现，监视结束（共关闭警告 %d 次）" % hits, flush=True)
            return 0
        time.sleep(2)
    print("[auto] 超时退出", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
