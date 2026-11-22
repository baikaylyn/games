#include <Carbon/Carbon.h>
#include <stdio.h>
#include <string.h>

static void list_sources(void)
{
    CFArrayRef a = TISCreateInputSourceList(NULL, true);
    CFIndex n = CFArrayGetCount(a);
    for (CFIndex i = 0; i < n; i++) {
        TISInputSourceRef s = (TISInputSourceRef)CFArrayGetValueAtIndex(a, i);
        CFStringRef id = TISGetInputSourceProperty(s, kTISPropertyInputSourceID);
        CFBooleanRef sel = TISGetInputSourceProperty(s, kTISPropertyInputSourceIsSelected);
        char buf[512] = {0};
        if (id) CFStringGetCString(id, buf, sizeof(buf), kCFStringEncodingUTF8);
        printf("%s%s\n", buf, (sel && CFBooleanGetValue(sel)) ? "   [当前]" : "");
    }
    CFRelease(a);
}

int main(int argc, char **argv)
{
    if (argc < 2) { list_sources(); return 0; }

    CFArrayRef a = TISCreateInputSourceList(NULL, true);
    CFIndex n = CFArrayGetCount(a);
    for (CFIndex i = 0; i < n; i++) {
        TISInputSourceRef s = (TISInputSourceRef)CFArrayGetValueAtIndex(a, i);
        CFStringRef id = TISGetInputSourceProperty(s, kTISPropertyInputSourceID);
        char buf[512] = {0};
        if (id) CFStringGetCString(id, buf, sizeof(buf), kCFStringEncodingUTF8);
        if (buf[0] && strstr(buf, argv[1])) {
            OSStatus st = TISSelectInputSource(s);
            printf("selected %s (status %d)\n", buf, (int)st);
            CFRelease(a);
            return 0;
        }
    }
    printf("not found: %s\n", argv[1]);
    CFRelease(a);
    return 1;
}
