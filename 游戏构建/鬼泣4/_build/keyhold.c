// keyhold <键码> <毫秒> —— 按住某键指定时长（用于持续移动/蓄力）
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: keyhold <键码> <毫秒>\n"); return 2; }
    CGKeyCode code = (CGKeyCode)atoi(argv[1]);
    int ms = atoi(argv[2]);
    if (ms < 50) ms = 50;
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, code, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(NULL, code, false);
    CGEventPost(kCGHIDEventTap, down);
    usleep(ms * 1000);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down); CFRelease(up);
    printf("已按住键码 %d 达 %d ms\n", code, ms);
    return 0;
}
