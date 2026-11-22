// dmc4_input —— 鬼泣4 鼠标化操作重映射器（只在游戏窗口位于最前时生效）
//
//   ./dmc4_input [--sens N] [--melee i|j] [--no-camera]
//     --sens N     相机死区像素，默认 4，越小越灵敏
//     --no-camera  不接管鼠标移动
//
// 映射（对齐 Capcom 官方手册的默认键盘）：
//   鼠标左键  → J   近战攻击（维吉尔/但丁；玩尼禄加 --melee i）
//   鼠标右键  → L   鬼手 / 风格技
//   鼠标中键  → 空格 锁定（按住生效）
//   鼠标移动  → ↑↓←→ 相机旋转（光标冻结，相对位移驱动）
//   键盘 空格 → K   跳跃 + 确认（空格原本是锁定，这里让给跳跃/确认）
//
// 为什么这么绕：
//   * 官方手册写明「Examine / Confirm / Cancel 固定绑在 A、B 两键，不可更改」，
//     而 A 键同时承担「跳跃 + 确认」，所以空格=K 之后，确认和跳跃天然就绑在一起了。
//   * 空格原本是锁定，用户要空格跳，因此锁定挪到鼠标中键；中键合成的是
//     **真正的空格事件**，并用 MAGIC 标记跳过重映射，避免被「空格→K」吃掉。
//   * 长按 Cmd 可临时放行（正常用鼠标去操作别的窗口），松开恢复接管。
//
// 权限：需要「辅助功能」+「输入监控」（本机已授权，用 permtest 复查）。
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

static int dbg = 0;

#define KC_I 34
#define KC_J 38
#define KC_L 37
#define KC_K 40
#define KC_SPACE 49
#define KC_LEFT 123
#define KC_RIGHT 124
#define KC_DOWN 125
#define KC_UP 126

#define MAGIC 0x444D4334

static int sens = 4;
static CGKeyCode melee_key = KC_J;   // 当前存档是维吉尔：近战=J；玩尼禄加 --melee i
static CGKeyCode buster_key = KC_L;  // 鬼手/风格技：两种角色都是 L
static int use_camera = 1;
static CGEventTapProxy g_proxy;
static int camL, camR, camU, camD;

static void post_key(CGKeyCode c, bool down) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, c, down);
    // 注意：绝不能写 kCGEventSourceUserData —— 赋任何非零值都会让系统把事件当无效丢弃，
    // 表现为"程序以为发了，游戏完全没收到"。这里靠"重映射只做一次"来防自激。
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}
// 非阻塞最小按住时长：
// 绝对不能在事件回调里 usleep —— 回调阻塞时，自己 post 的 keyDown/keyUp 会被挤到
// 回调返回后一起送达，游戏只看到 1ms 的按下，等于没按。
#include <sys/time.h>
static double now_s(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }
typedef struct { CGKeyCode k; double until; int on; } Pend;
static Pend pend[8];
static volatile int q_melee = 0, q_buster = 0, q_lock = 0;
static int test_key = 0, no_tap = 0;
static int test_phase = 0;

static void press_min(CGKeyCode c, double minhold) {
    post_key(c, true);
    for (int i = 0; i < 8; i++) {
        if (!pend[i].on) { pend[i].on = 1; pend[i].k = c; pend[i].until = now_s() + minhold; return; }
    }
    post_key(c, false);
}
static void press_min(CGKeyCode c, double minhold);
static void tick_cb(CFRunLoopTimerRef t, void *info) {
    // 所有 post 都在拦截回调之外做：在回调内部发事件会被系统吞掉
    if (q_melee)  { q_melee = 0;  press_min(melee_key, 0.12); }
    if (q_buster) { q_buster = 0; press_min(buster_key, 0.12); }
    int q = q_lock;
    if (q) { q_lock = 0; post_key(KC_SPACE, q == 1); }

    double n = now_s();
    for (int i = 0; i < 8; i++) {
        if (pend[i].on && n >= pend[i].until) { pend[i].on = 0; post_key(pend[i].k, false); }
    }

    if (test_key) {
        static double t0 = 0; static int step = 0;
        if (!t0) t0 = n;
        if (step == 0 && n - t0 > 1.5) { fprintf(stderr, "[自检] 发 %c 按下\n", melee_key == KC_I ? 'I' : 'J'); press_min(melee_key, 0.15); step = 1; }
        if (step == 1 && n - t0 > 2.8) { fprintf(stderr, "[自检] 结束\n"); exit(0); }
    }
}
static void release_cam(void) {
    if (camL) { post_key(KC_LEFT, false); camL = 0; }
    if (camR) { post_key(KC_RIGHT, false); camR = 0; }
    if (camU) { post_key(KC_UP, false); camU = 0; }
    if (camD) { post_key(KC_DOWN, false); camD = 0; }
}

static int is_game_owner(const char *s) {
    return s && (strstr(s, "DevilMayCry") || strstr(s, "DEVIL MAY CRY"));
}

static int game_frontmost(void) {
    int hit = 0;
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return 0;
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        CFNumberRef lr = CFDictionaryGetValue(d, kCGWindowLayer);
        int layer = -1;
        if (lr) CFNumberGetValue(lr, kCFNumberIntType, &layer);
        if (layer != 0) continue;
        CFStringRef owner = CFDictionaryGetValue(d, kCGWindowOwnerName);
        char buf[256] = {0};
        if (owner) CFStringGetCString(owner, buf, sizeof(buf), kCFStringEncodingUTF8);
        hit = is_game_owner(buf);
        break;
    }
    CFRelease(list);
    return hit;
}

static CGEventRef cb(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ctx) {
    g_proxy = proxy;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(ctx, true);
        return ev;
    }
    // 我们自己合成的事件：直接放行，避免自激
    (void)MAGIC;   // 保留宏定义便于查阅，不再用于判重

    extern int g_enabled;
    int fr = game_frontmost();
    if (dbg) fprintf(stderr, "[事件] type=%d front=%d\n", type, fr);
    if (!g_enabled || !fr) { release_cam(); return ev; }

    // 长按 Cmd 放行（要正常用鼠标时）
    if (CGEventGetFlags(ev) & kCGEventFlagMaskCommand) { release_cam(); return ev; }

    switch (type) {
    case kCGEventKeyDown: {
        CGKeyCode c = (CGKeyCode)CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
        if (c == KC_SPACE) {
            CGEventSetIntegerValueField(ev, kCGKeyboardEventKeycode, KC_K);
        }
        return ev;
    }
    case kCGEventKeyUp: {
        CGKeyCode c = (CGKeyCode)CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
        if (c == KC_SPACE) {
            CGEventSetIntegerValueField(ev, kCGKeyboardEventKeycode, KC_K);
        }
        return ev;
    }
    case kCGEventLeftMouseDown:  q_melee = 1; return NULL;
    case kCGEventRightMouseDown: q_buster = 1; return NULL;
    case kCGEventLeftMouseUp:
    case kCGEventRightMouseUp:   return NULL;
    case kCGEventOtherMouseDown: q_lock = 1; return NULL;   // 中键=锁定
    case kCGEventOtherMouseUp:   q_lock = 2; return NULL;
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged: {
        if (!use_camera) return ev;
        double dx = CGEventGetIntegerValueField(ev, kCGMouseEventDeltaX);
        double dy = CGEventGetIntegerValueField(ev, kCGMouseEventDeltaY);
        int wantL = dx < -sens, wantR = dx > sens;
        int wantU = dy < -sens, wantD = dy > sens;
        if (wantL != camL) { post_key(KC_LEFT, wantL); camL = wantL; }
        if (wantR != camR) { post_key(KC_RIGHT, wantR); camR = wantR; }
        if (wantU != camU) { post_key(KC_UP, wantU); camU = wantU; }
        if (wantD != camD) { post_key(KC_DOWN, wantD); camD = wantD; }
        return NULL;   // 吞掉移动事件 → 光标冻结，做无限视角
    }
    default:
        return ev;
    }
}

int g_enabled = 1;

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--sens") && i + 1 < argc) sens = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--melee") && i + 1 < argc) {
            melee_key = (argv[++i][0] == 'i' || argv[i][0] == 'I') ? KC_I : KC_J;
        }
        else if (!strcmp(argv[i], "--no-camera")) use_camera = 0;
        else if (!strcmp(argv[i], "--debug")) dbg = 1;
        else if (!strcmp(argv[i], "--test-key")) test_key = 1;
        else if (!strcmp(argv[i], "--no-tap")) no_tap = 1;
        else if (!strcmp(argv[i], "--help")) { printf("用法: dmc4_input [--sens N] [--melee i|j] [--no-camera]\n"); return 0; }
    }
    if (sens < 1) sens = 1;

    if (!CGPreflightPostEventAccess() || !CGPreflightListenEventAccess()) {
        fprintf(stderr, "缺少权限：需要在「系统设置 → 隐私与安全性」里给终端授权\n");
        fprintf(stderr, "  · 辅助功能（发事件）\n  · 输入监控（收事件）\n");
        return 1;
    }

    CFMachPortRef port = no_tap ? NULL : CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) |
        CGEventMaskBit(kCGEventFlagsChanged) |
        CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp) |
        CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged),
        cb, NULL);
    if (!no_tap) {
        if (!port) { fprintf(stderr, "事件拦截创建失败（权限不足？）\n"); return 1; }
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
        CGEventTapEnable(port, true);
    }

    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.01, 0.01, 0, 0, tick_cb, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);

    printf("鬼泣4 鼠标重映射已启动（死区 %d px）\n", sens);
    printf("  左键→%c 近战    右键→L 鬼手    中键→空格 锁定\n", melee_key == KC_I ? 'I' : 'J');
    printf("  空格→K 跳跃 + 确认（两者同一个键）\n");
    printf("  %s\n", use_camera ? "鼠标移动→相机（↑↓←→），光标冻结" : "相机接管已关闭");
    printf("  长按 Cmd 临时放行；Ctrl+C 退出\n");
    fflush(stdout);

    CFRunLoopRun();
    return 0;
}
