// ============================================================================
// hl_mouse —— 鼠标锁定辅助进程
//
// 行为：
//   · 启动后等游戏窗口出现，**自动把鼠标锁在游戏窗口内**（默认就是"正常游玩"状态）
//   · 按 0：脱离 → 鼠标变回普通系统光标，可以移出窗口、去桌面点别的 App
//   · 再按 0：锁回去
//   · 游戏退出 / 收到 SIGTERM、SIGHUP 时一定先解锁再退，绝不会把鼠标锁死
//
// 锁定的实现照抄塞尔达的 frontend.m：
//   CGWarpMouseCursorPosition(窗口中心) → CGAssociateMouseAndMouseCursorPosition(false) → 隐藏光标
// 光标被"从鼠标上摘下来"，所以怎么动都停在原地；但系统照常派发带 delta 的移动事件，
// Wine 转发给游戏，镜头照样能转。
//
// 为什么不做"按前台 App 自动解锁"：实测 NSWorkspace 的前台判断在 Wine 窗口上会抖，
// 导致锁/解锁每秒来回切。改成纯按键驱动后行为确定，也正好符合"按 0 切换"的预期。
// 代价是游戏运行期间 0 这个键会被系统吃掉（和塞尔达一样）；不想要就在启动器里关掉这个功能。
//
// 用法：hl_mouse <游戏进程 pid>
// 调试：kill -USR1 <pid> 等价按一次 0
//
// 编译：clang -fobjc-arc -O2 -framework AppKit -framework Carbon -o hl_mouse hl_mouse.m
// ============================================================================
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define HOTKEY_SIG 'HLMS'
#define HOTKEY_ID 1
/* 切换键：0（kVK_ANSI_0 = 29）。
   不能用 7 —— 游戏里 7 绑的是 AM_Loadout3（切第 3 套法术），
   Input.ini 里 Key=Zero 出现 0 次，说明 0 没被占用。 */
#define KEY_TOGGLE 29

static pid_t g_game = 0;
static int g_locked = 0;                 /* 当前是否锁定 */
static int g_wantLock = 1;               /* 玩家的意图：默认锁在游戏框内 */
static CGRect g_rect;                    /* 最近一次游戏窗口矩形 */
static BOOL g_rect_valid = NO;
static EventHotKeyRef g_hot = NULL;
static NSString *g_log = nil;
static volatile sig_atomic_t g_toggle_req = 0;

static void logline(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@  %@\n",
                      [NSDateFormatter localizedStringFromDate:NSDate.date
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle],
                      msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_log];
    if (!fh) {
        [line writeToFile:g_log atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
    @finally { [fh closeFile]; }
}

/* 游戏窗口的屏幕矩形（该进程面积最大的 layer 0 窗口）；窗口还没出来时返回 NO */
static BOOL game_window_rect(CGRect *out) {
    CFArrayRef arr = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
    if (!arr) return NO;
    BOOL found = NO;
    CGFloat best = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
        NSDictionary *w = (__bridge NSDictionary *)CFArrayGetValueAtIndex(arr, i);
        if ([w[(id)kCGWindowOwnerPID] intValue] != g_game) continue;
        /* 不再限定 layer 0：全屏窗口在 Wine 下是 layer 26 */
        CGRect r = CGRectZero;
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r);
        CGFloat area = r.size.width * r.size.height;
        if (area > best) { best = area; *out = r; found = YES; }
    }
    CFRelease(arr);
    return found;
}

static BOOL do_lock(void) {
    if (g_locked) return YES;
    CGRect r;
    if (!game_window_rect(&r)) return NO;      /* 窗口还没出来，下个 tick 再试 */
    g_rect = r;
    g_rect_valid = YES;
    /* 只在光标已经贴边/出窗时才拉回最近的边界；不要每次都跳到中心 */
    CGRect sr = CGRectIntersection(r, CGDisplayBounds(CGMainDisplayID()));
    CGEventRef e0 = CGEventCreate(NULL);
    if (e0) {
        if (!CGRectIsEmpty(sr)) {
            CGPoint p = CGEventGetLocation(e0);
            CGFloat m = 8.0;
            CGFloat minX = sr.origin.x + m, maxX = CGRectGetMaxX(sr) - m;
            CGFloat minY = sr.origin.y + m, maxY = CGRectGetMaxY(sr) - m;
            if (p.x < minX || p.x > maxX || p.y < minY || p.y > maxY) {
                CGWarpMouseCursorPosition(CGPointMake(fmin(fmax(p.x, minX), maxX),
                                                      fmin(fmax(p.y, minY), maxY)));
            }
        }
        CFRelease(e0);
    }
    CGAssociateMouseAndMouseCursorPosition(false);
    /* 用 CG 级 API 而不是 [NSCursor hide]：helper 是后台进程（Prohibited 策略），
       NSCursor 的隐藏计数在非活跃进程里不一定生效。 */
    CGDisplayHideCursor(kCGDirectMainDisplay);
    g_locked = 1;
    logline(@"鼠标锁定在游戏窗口内（按 0 脱离）");
    return YES;
}

static void do_unlock(void) {
    if (!g_locked) return;
    CGAssociateMouseAndMouseCursorPosition(true);
    CGDisplayShowCursor(kCGDirectMainDisplay);
    g_locked = 0;
    logline(@"鼠标已脱离，可以用桌面（按 0 锁回）");
}

static OSStatus on_hotkey(EventHandlerCallRef ref, EventRef ev, void *ctx) {
    (void)ref; (void)ctx;
    EventHotKeyID hid;
    if (GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof hid, NULL, &hid) != noErr)
        return noErr;
    if (hid.signature == HOTKEY_SIG && hid.id == HOTKEY_ID) g_toggle_req = 1;
    return noErr;
}

static BOOL hotkey_install(void) {
    if (g_hot) return YES;
    EventHotKeyID hid = {HOTKEY_SIG, HOTKEY_ID};
    OSStatus err = RegisterEventHotKey(KEY_TOGGLE, 0, hid, GetApplicationEventTarget(), 0, &g_hot);
    if (err != noErr) { g_hot = NULL; logline(@"注册热键 0 失败：%d", (int)err); return NO; }
    return YES;
}

static void on_term(int sig) {
    (void)sig;
    do_unlock();
    _exit(0);
}

static void on_usr1(int sig) { (void)sig; g_toggle_req = 1; }

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "用法: hl_mouse <游戏进程 pid>\n");
            return 2;
        }
        g_game = (pid_t)atoi(argv[1]);

        NSString *logs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:logs
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        g_log = [logs stringByAppendingPathComponent:@"HogwartsLegacy-mouse.log"];

        if (g_game <= 0 || kill(g_game, 0) != 0) {
            logline(@"目标进程 %d 不存在，退出", g_game);
            return 1;
        }

        signal(SIGTERM, on_term);
        signal(SIGINT, on_term);
        signal(SIGHUP, on_term);
        signal(SIGUSR1, on_usr1);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

        EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        InstallApplicationEventHandler(&on_hotkey, 1, &spec, NULL, NULL);

        /* 热键注册不上就绝不自动锁定 —— 否则玩家没有手段解锁 */
        BOOL hot = hotkey_install();
        if (!hot) {
            g_wantLock = 0;
            logline(@"热键不可用，本次不自动锁定鼠标（仍可 kill -USR1 手动切换）");
        }
        logline(@"启动：监视 pid=%d，热键 0 %@，默认%@", g_game,
                hot ? @"已注册" : @"不可用", hot ? @"锁定" : @"不锁");

        [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) {
            (void)t;
            if (kill(g_game, 0) != 0) {
                do_unlock();
                logline(@"游戏进程已退出，收工");
                [NSApp terminate:nil];
                return;
            }
            if (g_toggle_req) {
                g_toggle_req = 0;
                g_wantLock = !g_wantLock;
                if (g_wantLock) {
                    if (!do_lock()) g_wantLock = 0;   /* 窗口还没出来，先不锁 */
                } else {
                    do_unlock();
                }
            }
            /* 默认状态：窗口一出现就锁上 */
            if (g_wantLock && !g_locked) do_lock();
            /* 窗口可能移动/改大小，锁定时刷新矩形 */
            if (g_locked) {
                CGRect r;
                if (game_window_rect(&r)) { g_rect = r; g_rect_valid = YES; }
            }
        }];

        /* 125Hz 边界钳制：Wine/游戏有时会重新关联光标，物理鼠标能把光标推到
           屏幕边缘 → 触发 macOS 菜单栏 / Dock。留 8px 边距，越界立刻拉回中心。 */
        [NSTimer scheduledTimerWithTimeInterval:0.008 repeats:YES block:^(NSTimer *t) {
            (void)t;
            if (!g_locked || !g_rect_valid) return;
            CGRect sr = CGRectIntersection(g_rect, CGDisplayBounds(CGMainDisplayID()));
            if (CGRectIsEmpty(sr)) return;
            CGEventRef e = CGEventCreate(NULL);
            if (!e) return;
            CGPoint p = CGEventGetLocation(e);
            CFRelease(e);
            CGFloat m = 8.0;
            CGFloat minX = sr.origin.x + m, maxX = CGRectGetMaxX(sr) - m;
            CGFloat minY = sr.origin.y + m, maxY = CGRectGetMaxY(sr) - m;
            if (p.x < minX || p.x > maxX || p.y < minY || p.y > maxY) {
                /* 钳到最近的边界，不甩回中心（甩回中心会“一划就弹”） */
                CGPoint c = CGPointMake(fmin(fmax(p.x, minX), maxX),
                                        fmin(fmax(p.y, minY), maxY));
                CGWarpMouseCursorPosition(c);
            }
        }];

        [NSApp run];
        do_unlock();
        return 0;
    }
}
