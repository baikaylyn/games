// lclick —— 快速左键单击（down+up 后立即返回，便于在动作动画中途截图）
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: lclick <x> <y> [次数]\n"); return 2; }
    CGPoint p = CGPointMake(atof(argv[1]), atof(argv[2]));
    int times = argc > 3 ? atoi(argv[3]) : 1;
    CGEventRef mv = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, mv); CFRelease(mv);
    usleep(50000);
    for (int i = 0; i < times; i++) {
        CGEventRef d = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, p, kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, d); CFRelease(d);
        usleep(20000);
        CGEventRef u = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, p, kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, u); CFRelease(u);
        usleep(20000);
    }
    return 0;
}
