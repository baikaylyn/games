// click <x> <y> [次数] —— 全局投递一次左键单击（先把指针移过去）
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void post(CGEventType t, CGPoint p) {
    CGEventRef e = CGEventCreateMouseEvent(NULL, t, p, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: click <x> <y> [次数]\n"); return 2; }
    CGPoint p = CGPointMake(atof(argv[1]), atof(argv[2]));
    int times = argc > 3 ? atoi(argv[3]) : 1;
    printf("post 权限: %s\n", CGPreflightPostEventAccess() ? "有" : "无");
    for (int i = 0; i < times; i++) {
        post(kCGEventMouseMoved, p);   usleep(120000);
        post(kCGEventLeftMouseDown, p); usleep(80000);
        post(kCGEventLeftMouseUp, p);   usleep(300000);
    }
    printf("已在 (%.0f,%.0f) 点击 %d 次\n", p.x, p.y, times);
    return 0;
}
