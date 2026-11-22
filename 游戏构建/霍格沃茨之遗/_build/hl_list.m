// hl_list —— 列出当前屏幕上的大窗口：所属进程、PID、尺寸、位置
// 编译：clang -fobjc-arc -O2 -framework AppKit -o /tmp/hl_list hl_list.m
#import <AppKit/AppKit.h>
#include <stdio.h>

int main(void) {
    @autoreleasepool {
        CFArrayRef arr = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
        if (!arr) return 1;
        printf("%-8s %-10s %-26s %s\n", "PID", "尺寸", "所属进程", "位置");
        for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
            NSDictionary *w = (__bridge NSDictionary *)CFArrayGetValueAtIndex(arr, i);
            CGRect r = CGRectZero;
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r);
            r = CGRectStandardize(r);
            if (r.size.width * r.size.height < 2000) continue;   // 忽略极小窗口
            printf("%-8d %-10.0fx%-0.0f %-26s (%.0f,%.0f)\n",
                   [w[(id)kCGWindowOwnerPID] intValue],
                   r.size.width, r.size.height,
                   [(NSString *)w[(id)kCGWindowOwnerName] UTF8String] ?: "?",
                   r.origin.x, r.origin.y);
        }
        CFRelease(arr);
    }
    return 0;
}
