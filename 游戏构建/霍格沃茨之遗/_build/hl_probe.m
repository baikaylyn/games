// hl_probe —— 连续采样 wine 游戏窗口的尺寸，用于确认"窗口是否还会跳变"
// 只读 CGWindowList，不注入、不修改任何进程。
// 编译：clang -fobjc-arc -O2 -framework AppKit -o /tmp/hl_probe hl_probe.m
// 用法：/tmp/hl_probe 秒数
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int secs = argc > 1 ? atoi(argv[1]) : 120;
        double t0 = now(), lastPrint = -1;
        while (now() - t0 < secs) {
            @autoreleasepool {
                CFArrayRef arr = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,
                                                            kCGNullWindowID);
                if (arr) {
                    for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
                        NSDictionary *w = (__bridge NSDictionary *)CFArrayGetValueAtIndex(arr, i);
                        NSString *owner = w[(id)kCGWindowOwnerName] ?: @"?";
                        if ([owner rangeOfString:@"wine" options:NSCaseInsensitiveSearch].location
                                == NSNotFound &&
                            [owner rangeOfString:@"Hogwarts" options:NSCaseInsensitiveSearch].location
                                == NSNotFound &&
                            [owner rangeOfString:@"Sikarugir" options:NSCaseInsensitiveSearch].location
                                == NSNotFound)
                            continue;
                        CGRect r = CGRectZero;
                        CGRectMakeWithDictionaryRepresentation(
                            (__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r);
                        r = CGRectStandardize(r);
                        if (r.size.width * r.size.height < 2000) continue;
                        // 相同尺寸不重复打印，只打变化的，日志才干净
                        double key = r.size.width * 10000 + r.size.height;
                        if (key == lastPrint) break;
                        lastPrint = key;
                        printf("%6.1fs  %.0fx%.0f  @(%.0f,%.0f)  %s\n",
                               now() - t0, r.size.width, r.size.height,
                               r.origin.x, r.origin.y, owner.UTF8String);
                        fflush(stdout);
                    }
                    CFRelease(arr);
                }
            }
            usleep(400000);   // 0.4 秒
        }
    }
    return 0;
}
