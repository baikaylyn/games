// dmc4_input v4 —— 鬼泣4 鼠标化操作重映射器 + 鼠标捕获
//
//   ./dmc4_input                 # 默认按 NERO（开局角色）：近战 I / 枪 J
//   ./dmc4_input --melee j       # 换但丁 / 维吉尔（近战 J / 枪 I）
//   ./dmc4_input --sens 8        # 视角死区（越大越钝）
//   ./dmc4_input --no-capture    # 不捕获鼠标（允许光标离开窗口）
//   ./dmc4_input --debug         # 打印每条拦截决策
//
// 映射：
//   鼠标左键              → 近战攻击（NERO: I，但丁/维吉尔: J）
//   鼠标右键              → 鬼手 / 风格技（L）
//   鼠标中键 / 侧键(4,5)  → 枪械攻击（J 或 I，取近战键的另一个）
//   键盘 F                → 枪械攻击（左手备用）
//   键盘 左/右 Shift      → 锁定（按住生效）
//   键盘 空格             → 跳跃 + 确认（二者本就是同一个键）
//   鼠标移动              → 转视角（↑↓←→）
//
// 鼠标捕获（v4 新增）：
//   游戏在最前时调 CGAssociateMouseAndMouseCursorPosition(false)，
//   把物理鼠标位移与系统光标位置解耦 —— 光标钉在窗口中央不动，
//   位移只用来转视角，因此**光标永远不会滑出游戏窗口**。
//   这是 FPS 游戏标准做法，比"吞掉 MouseMoved"干净得多：
//   后者在鼠标快速移动时仍会漏出光标。
//   长按 Cmd 临时解除捕获，方便去点别的窗口。
//
// 游戏内键位必须保持 Capcom 出厂值，重映射器才有稳定的目标：
//   MELEE I / GUN J / JUMP K / DEVIL BRINGER L / DEVIL TRIGGER N / LOCK-ON 空格 / EXCEED Q
//   出厂值可在 SYSTEMS → 角色页 → DEFAULT 一键恢复。
//
// 六个必须遵守的技术细节（血泪）：
//   1. 合成按键绝不能写 kCGEventSourceUserData：赋任何非零值都会被系统当无效事件丢弃。
//   2. 点按必须 ≥ 1 帧（游戏 16~25fps），这里用 120ms 最小按住时长。
//   3. 不能在事件拦截回调里 usleep：回调阻塞会把自己发的事件挤到一起送达。
//      回调只置标志位，发送放到 CFRunLoopTimer 里。
//   4. 自己合成的事件会带本进程 PID（kCGEventSourceUnixProcessID），据此跳过二次改写，
//      否则「Shift→空格」会被「空格→K」吃掉，锁定变成跳跃。
//   5. 前台判断（CGWindowListCopyWindowInfo）必须缓存：鼠标每秒产生上百条移动事件，
//      每次都全量遍历窗口列表会直接吃满 CPU 并引入输入延迟。
//   6. 视角要用累积位移判定，不能用单次事件 delta：慢速移动时每次 delta 只有 1，
//      永远达不到阈值，看起来就是"视角不跟手"。
#include <ApplicationServices/ApplicationServices.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>

#define KC_I 34
#define KC_J 38
#define KC_L 37
#define KC_K 40
#define KC_SPACE 49
#define KC_F 3
#define KC_LSHIFT 56
#define KC_RSHIFT 60
#define KC_LEFT 123
#define KC_RIGHT 124
#define KC_DOWN 125
#define KC_UP 126
#define KC_ESC 53

static int sens = 6;
static int use_camera = 1;
static int use_capture = 1;
static int dbg = 0;
static CGKeyCode melee_key = KC_I;   // 默认 NERO：I 近战 / J 枪
static CGKeyCode gun_key = KC_J;
static CGKeyCode buster_key = KC_L;
static CGKeyCode jump_key = KC_K;

static int camL, camR, camU, camD;
static int lock_held = 0;

// 视角累积器：慢速移动也要能累积过阈值（单次事件 delta 常常只有 1）
static double acc_x = 0, acc_y = 0;
static double last_move_t = 0;

typedef struct { CGKeyCode k; double until; int on; } Pend;
static Pend pend[8];
static volatile int q_melee = 0, q_gun = 0, q_buster = 0;
static volatile int q_lock = 0;      // 1=按下空格 2=松开空格

static double now_s(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec / 1e6;
}

static void post_key(CGKeyCode c, bool down) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, c, down);
    // 不要写 kCGEventSourceUserData（见文件头第 1 条）
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

static void press_min(CGKeyCode c, double minhold) {
    post_key(c, true);
    for (int i = 0; i < 8; i++) {
        if (!pend[i].on) { pend[i].on = 1; pend[i].k = c; pend[i].until = now_s() + minhold; return; }
    }
    post_key(c, false);
}

static void release_cam(void) {
    if (camL) { post_key(KC_LEFT, false); camL = 0; }
    if (camR) { post_key(KC_RIGHT, false); camR = 0; }
    if (camU) { post_key(KC_UP, false); camU = 0; }
    if (camD) { post_key(KC_DOWN, false); camD = 0; }
    acc_x = acc_y = 0;
}

// ---------- 前台判断 + 窗口矩形（带缓存） ----------
static int is_game_owner(const char *s) {
    return s && (strstr(s, "DevilMayCry") || strstr(s, "DEVIL MAY CRY"));
}

static int g_front = 0;
static double g_front_next = 0;
static CGRect g_win = {{0,0},{0,0}};
static int g_win_valid = 0;

static void refresh_front(void) {
    int hit = 0;
    CGRect win = {{0,0},{0,0}};
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return;
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
        hit = is_game_owner(buf);   // 只看最前面那个普通窗口
        if (hit) {
            CFDictionaryRef br = CFDictionaryGetValue(d, kCGWindowBounds);
            if (br) CGRectMakeWithDictionaryRepresentation(br, &win);
        }
        break;
    }
    CFRelease(list);
    g_win_valid = (win.size.width > 1 && win.size.height > 1);
    if (g_win_valid) g_win = win;
    g_front = hit;
}

static int game_frontmost(void) {
    double n = now_s();
    if (n >= g_front_next) {
        int old = g_front;
        refresh_front();
        if (g_front != old && dbg) fprintf(stderr, "[前台] %s\n", g_front ? "游戏" : "非游戏");
        g_front_next = n + 0.20;   // 200ms 刷新，躲开鼠标事件风暴
    }
    return g_front;
}

// ---------- 鼠标捕获（v4 新增） ----------
static int captured = 0;
static int cursor_hidden = 0;
static int menu_mode = 0;   // ESC 切换：1=菜单（显示光标、不转视角、放行输入）

static void capture_on(void) {
    if (!use_capture || captured) return;
    // 光标钉到游戏窗口正中央
    if (dbg) fprintf(stderr, "[捕获] win_valid=%d rect=(%.0f,%.0f %.0fx%.0f)\n",
                     g_win_valid, g_win.origin.x, g_win.origin.y, g_win.size.width, g_win.size.height);
    if (g_win_valid) {
        CGPoint c = CGPointMake(CGRectGetMidX(g_win), CGRectGetMidY(g_win));
        CGWarpMouseCursorPosition(c);
        CGEventRef e = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, c, kCGMouseButtonLeft);
        if (e) { CGEventPost(kCGHIDEventTap, e); CFRelease(e); }
    }
    // 解耦物理鼠标与光标：位移只转视角，光标不动 → 永不出框
    CGAssociateMouseAndMouseCursorPosition(0);
    if (!cursor_hidden) {
        CGDisplayHideCursor(kCGDirectMainDisplay);
        cursor_hidden = 1;
    }
    captured = 1;
    if (dbg) fprintf(stderr, "[捕获] 光标已钉入游戏窗口并隐藏\n");
}

static void capture_off(void) {
    if (cursor_hidden) {
        CGDisplayShowCursor(kCGDirectMainDisplay);
        cursor_hidden = 0;
    }
    if (!captured) return;
    CGAssociateMouseAndMouseCursorPosition(1);
    captured = 0;
    if (dbg) fprintf(stderr, "[捕获] 已解除，光标已显示\n");
}

// 任何退出路径（Ctrl+C / SIGTERM / pkill）都必须还原鼠标关联，
// 否则光标会一直解耦、看起来像"鼠标坏了"。
static void sig_exit(int sig) {
    capture_off();
    _exit(0);
}

// ---------- 视角：累积 + 衰减 ----------
static void cam_update(double dx, double dy) {
    acc_x += dx;
    // macOS 的 deltaY 向下为正；游戏里要「鼠标上移=视角上移」，所以取反
    acc_y -= dy;
    if (fabs(acc_x) > 60) acc_x = (acc_x > 0 ? 60 : -60);
    if (fabs(acc_y) > 60) acc_y = (acc_y > 0 ? 60 : -60);
    last_move_t = now_s();
}

static void cam_apply(void) {
    if (!use_camera) return;
    int wantL = acc_x <= -sens, wantR = acc_x >= sens;
    int wantU = acc_y <= -sens, wantD = acc_y >= sens;
    if (wantL != camL) { post_key(KC_LEFT, wantL); camL = wantL; }
    if (wantR != camR) { post_key(KC_RIGHT, wantR); camR = wantR; }
    if (wantU != camU) { post_key(KC_UP, wantU); camU = wantU; }
    if (wantD != camD) { post_key(KC_DOWN, wantD); camD = wantD; }
    // 停手 60ms 后开始衰减，衰减到阈值以下方向键自然松开
    if (now_s() - last_move_t > 0.06) {
        acc_x *= 0.60;
        acc_y *= 0.60;
        if (fabs(acc_x) < 0.5) acc_x = 0;
        if (fabs(acc_y) < 0.5) acc_y = 0;
    }
}

static void tick_cb(CFRunLoopTimerRef t, void *info) {
    // 捕获状态跟随前台；菜单模式（ESC）下释放光标
    if (g_front && !menu_mode) capture_on(); else capture_off();

    // 钳制：任何来源的事件（含第三方合成）把光标带出游戏框，就拉回中央
    // —— 这才是「锁定在游戏框内」的字面落实，不只是解耦物理鼠标
    if (captured && g_win_valid) {
        CGEventRef probe = CGEventCreate(NULL);
        if (probe) {
            CGPoint p = CGEventGetLocation(probe);
            CFRelease(probe);
            if (p.x < g_win.origin.x || p.x > CGRectGetMaxX(g_win) ||
                p.y < g_win.origin.y || p.y > CGRectGetMaxY(g_win)) {
                CGPoint c = CGPointMake(CGRectGetMidX(g_win), CGRectGetMidY(g_win));
                CGWarpMouseCursorPosition(c);
                if (dbg) fprintf(stderr, "[钳制] 光标越界 (%.0f,%.0f) → 拉回中央\n", p.x, p.y);
            }
        }
    }

    // 菜单模式：光标可见，但仍钳制在游戏窗口内（不可移出）
    if (menu_mode && g_front && g_win_valid) {
        CGEventRef probe = CGEventCreate(NULL);
        if (probe) {
            CGPoint p = CGEventGetLocation(probe);
            CFRelease(probe);
            CGFloat minX = g_win.origin.x, maxX = CGRectGetMaxX(g_win) - 1;
            CGFloat minY = g_win.origin.y, maxY = CGRectGetMaxY(g_win) - 1;
            if (p.x < minX || p.x > maxX || p.y < minY || p.y > maxY) {
                CGPoint c = CGPointMake(fmin(fmax(p.x, minX), maxX),
                                        fmin(fmax(p.y, minY), maxY));
                CGWarpMouseCursorPosition(c);
                if (dbg) fprintf(stderr, "[菜单] 光标钳制到窗口内 (%.0f,%.0f)\n", c.x, c.y);
            }
        }
    }

    // 所有发送都在拦截回调之外执行
    if (q_melee)  { q_melee = 0;  press_min(melee_key, 0.12); }
    if (q_gun)    { q_gun = 0;    press_min(gun_key, 0.12); }
    if (q_buster) { q_buster = 0; press_min(buster_key, 0.12); }
    int q = q_lock;
    if (q) { q_lock = 0; post_key(KC_SPACE, q == 1); }

    if (g_front) cam_apply();

    double n = now_s();
    for (int i = 0; i < 8; i++) {
        if (pend[i].on && n >= pend[i].until) { pend[i].on = 0; post_key(pend[i].k, false); }
    }
}

static CGEventRef cb(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ctx) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(ctx, true);
        return ev;
    }

    // 自己合成的事件带本进程 PID → 直接放行
    if (CGEventGetIntegerValueField(ev, kCGEventSourceUnixProcessID) == (int64_t)getpid()) {
        return ev;
    }

    if (!game_frontmost()) { release_cam(); lock_held = 0; return ev; }

    // 长按 Cmd 放行（要正常用鼠标操作别的窗口时）
    if (CGEventGetFlags(ev) & kCGEventFlagMaskCommand) {
        release_cam();
        capture_off();
        return ev;
    }

    // ESC 进入菜单模式：显示光标、放行所有输入。
    // 退出不用 ESC（DMC4 的暂停菜单是选 EXIT PAUSE MENU 关的，不是 ESC），
    // 而是检测「游戏操作」：按 WASD / 攻击键 / 鼠标键 = 已经回到游戏，立刻重新捕获并隐藏。
    if (type == kCGEventKeyDown) {
        CGKeyCode c = (CGKeyCode)CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
        if (c == KC_ESC) {
            menu_mode = !menu_mode;
            if (dbg) fprintf(stderr, "[菜单] %s\n", menu_mode ? "进入（显示光标）" : "退出（隐藏光标）");
            return ev;   // ESC 放行给游戏（游戏自己会开/关暂停菜单）
        }
        if (menu_mode) {
            if (c == 13 || c == 0 || c == 1 || c == 2 ||          // W A S D
                c == KC_I || c == KC_J || c == KC_L || c == KC_K ||
                c == KC_SPACE || c == KC_LSHIFT || c == KC_RSHIFT) {
                menu_mode = 0;
                if (dbg) fprintf(stderr, "[菜单] 检测到游戏操作，退出（隐藏光标）\n");
            }
        }
    }
    if (menu_mode) {
        if (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown) {
            menu_mode = 0;   // 点鼠标 = 回游戏
            if (dbg) fprintf(stderr, "[菜单] 鼠标点击，退出（隐藏光标）\n");
        } else {
            release_cam();
            lock_held = 0;
            return ev;   // 菜单里不转视角、不改键、不合成鼠标键
        }
    }

    switch (type) {
    case kCGEventKeyDown: {
        CGKeyCode c = (CGKeyCode)CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
        if (c == KC_SPACE) {
            CGEventSetIntegerValueField(ev, kCGKeyboardEventKeycode, jump_key);  // 空格 = 跳跃 + 确认
        } else if (c == KC_F) {
            q_gun = 1;                                                          // F = 枪械
            return NULL;
        }
        return ev;
    }
    case kCGEventKeyUp: {
        CGKeyCode c = (CGKeyCode)CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
        if (c == KC_SPACE) {
            CGEventSetIntegerValueField(ev, kCGKeyboardEventKeycode, jump_key);
        } else if (c == KC_F) {
            return NULL;
        }
        return ev;
    }
    case kCGEventFlagsChanged: {
        // Shift 是修饰键，只产生 FlagsChanged，没有 KeyDown/KeyUp
        CGKeyCode c = (CGKeyCode)CGEventGetIntegerValueField(ev, kCGKeyboardEventKeycode);
        if (c == KC_LSHIFT || c == KC_RSHIFT) {
            int down = (CGEventGetFlags(ev) & kCGEventFlagMaskShift) ? 1 : 0;
            if (down != lock_held) {
                lock_held = down;
                q_lock = down ? 1 : 2;   // 合成空格 → 游戏里就是「锁定」
                if (dbg) fprintf(stderr, "[锁定] %s\n", down ? "按下" : "松开");
            }
        }
        return ev;
    }
    case kCGEventLeftMouseDown:
        q_melee = 1;
        if (dbg) fprintf(stderr, "[左键] → 近战 keycode=%d\n", melee_key);
        return NULL;
    case kCGEventRightMouseDown:
        q_buster = 1;
        if (dbg) fprintf(stderr, "[右键] → 鬼手 L\n");
        return NULL;
    case kCGEventOtherMouseDown: {
        int64_t btn = CGEventGetIntegerValueField(ev, kCGMouseEventButtonNumber);
        q_gun = 1;
        if (dbg) fprintf(stderr, "[鼠标键%d] → 枪械 keycode=%d\n", (int)btn, gun_key);
        return NULL;
    }
    case kCGEventLeftMouseUp:
    case kCGEventRightMouseUp:
    case kCGEventOtherMouseUp:
        return NULL;
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged: {
        if (!use_camera) return ev;
        double dx = CGEventGetIntegerValueField(ev, kCGMouseEventDeltaX);
        double dy = CGEventGetIntegerValueField(ev, kCGMouseEventDeltaY);
        cam_update(dx, dy);
        return NULL;   // 吞掉移动 → 光标不移动（配合捕获双保险）
    }
    default:
        return ev;
    }
}

int main(int argc, char **argv) {
    int no_tap = 0, only_release = 0, no_signals = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--sens") && i + 1 < argc) sens = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--melee") && i + 1 < argc) {
            melee_key = (argv[++i][0] == 'i' || argv[i][0] == 'I') ? KC_I : KC_J;
        }
        else if (!strcmp(argv[i], "--no-camera")) use_camera = 0;
        else if (!strcmp(argv[i], "--no-capture")) use_capture = 0;
        else if (!strcmp(argv[i], "--debug")) dbg = 1;
        else if (!strcmp(argv[i], "--no-tap")) no_tap = 1;
        else if (!strcmp(argv[i], "--no-signals")) no_signals = 1;
        else if (!strcmp(argv[i], "--release")) only_release = 1;
        else if (!strcmp(argv[i], "--help")) {
            printf("用法: dmc4_input [--melee i|j] [--sens N] [--no-camera] [--no-capture] [--debug]\n");
            printf("       dmc4_input --release   # 仅还原鼠标关联后退出\n");
            return 0;
        }
    }

    // 先还原鼠标关联（覆盖上一次异常退出的残留状态）
    CGAssociateMouseAndMouseCursorPosition(1);
    if (only_release) { printf("鼠标关联已还原\n"); return 0; }

    if (sens < 1) sens = 1;
    gun_key = (melee_key == KC_J) ? KC_I : KC_J;   // 枪械 = 近战键的另一个

    if (!no_signals) {
        signal(SIGINT, sig_exit);
        signal(SIGTERM, sig_exit);
        signal(SIGHUP, sig_exit);
    }

    if (!CGPreflightPostEventAccess() || !CGPreflightListenEventAccess()) {
        fprintf(stderr, "缺少权限：系统设置 → 隐私与安全性 → 辅助功能 / 输入监控\n");
        return 1;
    }

    if (!no_tap) {
        CFMachPortRef port = CGEventTapCreate(kCGSessionEventTap,
            kCGHeadInsertEventTap, kCGEventTapOptionDefault,
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
        if (!port) { fprintf(stderr, "事件拦截创建失败（权限不足？）\n"); return 1; }
        CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
        CGEventTapEnable(port, true);
    }

    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + 0.01, 0.01, 0, 0, tick_cb, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);

    printf("鬼泣4 鼠标重映射已启动（视角死区 %d px）\n", sens);
    printf("  角色: %s（近战 %c / 枪 %c）\n",
           melee_key == KC_I ? "NERO" : "但丁·维吉尔",
           melee_key == KC_I ? 'I' : 'J', gun_key == KC_I ? 'I' : 'J');
    printf("  左键 → 近战        右键 → L 鬼手\n");
    printf("  中键/侧键/F → 枪械   Shift(按住) → 锁定\n");
    printf("  空格 → 跳跃 + 确认   %s\n",
           use_camera ? "鼠标移动 → 转视角" : "视角接管已关闭");
    printf("  鼠标捕获: %s（光标锁在游戏窗口内，长按 Cmd 解除）\n",
           use_capture ? "开启" : "关闭");
    printf("  只在游戏窗口最前时生效；Ctrl+C 退出\n");
    fflush(stdout);

    // 退出前务必还原鼠标关联
    atexit(capture_off);

    CFRunLoopRun();
    return 0;
}
