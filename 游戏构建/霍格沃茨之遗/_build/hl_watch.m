// hl_watch —— 只读探针：记录游戏窗口尺寸/位置随时间的变化
//
// 用法：hl_watch <wine pid> [持续秒数]
// 输出：~/Library/Logs/HogwartsLegacy-window.log
//
// 只用 CGWindowListCopyWindowInfo 读窗口矩形，不注入、不改窗口、不需要辅助功能授权。
// 窗口矩形变化时打一行，另外每 5 秒打一行心跳（方便确认进程活着）。
//
// 编译：clang -fobjc-arc -O2 -framework AppKit -o /tmp/hl_watch hl_watch.m

#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static FILE *g_out;

static void wlog(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char ts[32];
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(ts, sizeof ts, "%H:%M:%S", &tmv);
    fprintf(g_out, "%s  ", ts);
    vfprintf(g_out, fmt, ap);
    fputc('\n', g_out);
    fflush(g_out);
    va_end(ap);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "用法: hl_watch <pid> [秒]\n"); return 2; }
        pid_t target = atoi(argv[1]);
        int limit = argc > 2 ? atoi(argv[2]) : 0;   // 0 = 一直跑到游戏退出

        NSString *logPath = [NSHomeDirectory() stringByAppendingPathComponent:
                             @"Library/Logs/HogwartsLegacy-window.log"];
        g_out = fopen(logPath.UTF8String, "a");
        if (!g_out) { fprintf(stderr, "打不开日志\n"); return 1; }

        wlog("=== 开始监视 pid=%d ===", target);

        CGRect last = CGRectZero;
        int sameCount = 0;
        int tick = 0;
        int seen = 0;
        time_t t0 = time(NULL);

        while (1) {
            if (kill(target, 0) != 0) { wlog("游戏进程已退出，收工"); break; }
            if (limit && (int)(time(NULL) - t0) > limit) { wlog("到时间，收工"); break; }

            CFArrayRef arr = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,
                                                        kCGNullWindowID);
            CGRect best = CGRectZero;
            CGFloat bestArea = 0;
            NSString *bestName = nil;
            int count = 0;
            if (arr) {
                for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
                    NSDictionary *w = (__bridge NSDictionary *)CFArrayGetValueAtIndex(arr, i);
                    if ([w[(id)kCGWindowOwnerPID] intValue] != target) continue;
                    CGRect r = CGRectZero;
                    CGRectMakeWithDictionaryRepresentation(
                        (__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r);
                    CGRect trimmed = CGRectStandardize(r);
                    count++;
                    CGFloat a = trimmed.size.width * trimmed.size.height;
                    if (a > bestArea) { bestArea = a; best = trimmed; bestName = w[(id)kCGWindowName]; }
                }
                CFRelease(arr);
            }

            if (bestArea > 0) {
                if (!seen) { seen = 1; wlog("窗口出现：%.0fx%.0f @(%.0f,%.0f)  [进程共 %d 个窗口]",
                                            best.size.width, best.size.height,
                                            best.origin.x, best.origin.y, count); }
                else if (!CGSizeEqualToSize(best.size, last.size) ||
                         !CGPointEqualToPoint(best.origin, last.origin)) {
                    wlog("尺寸/位置变化：%.0fx%.0f @(%.0f,%.0f)  (上一帧 %.0fx%.0f @(%.0f,%.0f))",
                         best.size.width, best.size.height, best.origin.x, best.origin.y,
                         last.size.width, last.size.height, last.origin.x, last.origin.y);
                }
                last = best;
                sameCount++;
            }

            tick++;
            if (tick % 17 == 0 && seen)
                wlog("心跳：当前 %.0fx%.0f @(%.0f,%.0f)，已稳定 %d 次采样",
                     last.size.width, last.size.height, last.origin.x, last.origin.y, sameCount);
            else if (tick % 17 == 0 && !seen)
                wlog("心跳：还没看到窗口");

            usleep(300 * 1000);
        }
        fclose(g_out);
    }
    return 0;
}
