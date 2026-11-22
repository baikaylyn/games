// mousemove <dx> <dy> [步数] —— 相对移动鼠标（保持光标位置不变，模拟真实相对位移）
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: mousemove <dx> <dy> [步数]\n"); return 2; }
    int dx = atoi(argv[1]), dy = atoi(argv[2]);
    int steps = argc > 3 ? atoi(argv[3]) : 1;
    if (steps < 1) steps = 1;
    CGEventRef probe = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(probe);
    CFRelease(probe);
    for (int i = 0; i < steps; i++) {
        // 位置保持不变，只写 delta → 不会瞬移光标，是真正的相对移动
        CGEventRef e = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(e, kCGMouseEventDeltaX, dx);
        CGEventSetIntegerValueField(e, kCGMouseEventDeltaY, dy);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
        usleep(16000);
    }
    printf("已相对移动 (%d,%d) x%d（光标应保持在 %.0f,%.0f）\n", dx, dy, steps, p.x, p.y);
    return 0;
}
