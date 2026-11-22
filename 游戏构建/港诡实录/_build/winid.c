// 列出屏幕上所有窗口：owner / 标题 / 窗口号 / 位置 / 尺寸
// 用法：./winid [关键字]
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *needle = argc > 1 ? argv[1] : NULL;
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return 1;
    CFIndex n = CFArrayGetCount(list);
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
        CFStringRef owner = CFDictionaryGetValue(w, kCGWindowOwnerName);
        CFStringRef name  = CFDictionaryGetValue(w, kCGWindowName);
        CFNumberRef num   = CFDictionaryGetValue(w, kCGWindowNumber);
        CFDictionaryRef bounds = CFDictionaryGetValue(w, kCGWindowBounds);
        char own[256] = {0}, ttl[256] = {0};
        if (owner) CFStringGetCString(owner, own, sizeof own, kCFStringEncodingUTF8);
        if (name)  CFStringGetCString(name,  ttl, sizeof ttl, kCFStringEncodingUTF8);
        int wid = 0;
        if (num) CFNumberGetValue(num, kCFNumberIntType, &wid);
        double x = 0, y = 0, wd = 0, ht = 0;
        if (bounds) {
            CGRect r; CGRectMakeWithDictionaryRepresentation(bounds, &r);
            x = r.origin.x; y = r.origin.y; wd = r.size.width; ht = r.size.height;
        }
        if (needle && !strstr(own, needle) && !strstr(ttl, needle)) continue;
        printf("%-10d %-22.22s %-30.30s %4.0fx%-4.0f @ %.0f,%.0f\n", wid, own, ttl, wd, ht, x, y);
    }
    CFRelease(list);
    return 0;
}
