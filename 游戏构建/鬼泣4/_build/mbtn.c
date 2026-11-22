// mbtn <按钮号> <x> <y> [次数] —— 0=左 1=右 2=中 3=侧键1 4=侧键2
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "用法: mbtn <按钮号> <x> <y> [次数]\n"); return 2; }
    int b = atoi(argv[1]);
    CGPoint p = CGPointMake(atof(argv[2]), atof(argv[3]));
    int times = argc > 4 ? atoi(argv[4]) : 1;
    CGMouseButton mb = (CGMouseButton)(b == 1 ? kCGMouseButtonRight
                                 : b == 2 ? kCGMouseButtonCenter : b);
    CGEventType downT = (b == 0) ? kCGEventLeftMouseDown
                      : (b == 1) ? kCGEventRightMouseDown : kCGEventOtherMouseDown;
    CGEventType upT   = (b == 0) ? kCGEventLeftMouseUp
                      : (b == 1) ? kCGEventRightMouseUp : kCGEventOtherMouseUp;

    CGEventRef mv = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, mv); CFRelease(mv);
    usleep(50000);

    for (int i = 0; i < times; i++) {
        CGEventRef d = CGEventCreateMouseEvent(NULL, downT, p, mb);
        CGEventSetIntegerValueField(d, kCGMouseEventButtonNumber, b);
        CGEventPost(kCGHIDEventTap, d); CFRelease(d);
        usleep(20000);
        CGEventRef u = CGEventCreateMouseEvent(NULL, upT, p, mb);
        CGEventSetIntegerValueField(u, kCGMouseEventButtonNumber, b);
        CGEventPost(kCGHIDEventTap, u); CFRelease(u);
        usleep(20000);
    }
    printf("已发按钮 %d 于 (%.0f,%.0f) x%d\n", b, p.x, p.y, times);
    return 0;
}
