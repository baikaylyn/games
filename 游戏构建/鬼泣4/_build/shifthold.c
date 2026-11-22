// shifthold <毫秒> [l|r] —— 模拟真实修饰键按下（产生 FlagsChanged，而非 KeyDown）
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void shift(int down, CGKeyCode kc) {
    CGEventRef e = CGEventCreateKeyboardEvent(NULL, kc, down);
    CGEventSetType(e, kCGEventFlagsChanged);
    CGEventSetFlags(e, down ? kCGEventFlagMaskShift : 0);
    CGEventPost(kCGHIDEventTap, e);
    CFRelease(e);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法: shifthold <毫秒> [l|r]\n"); return 2; }
    int ms = atoi(argv[1]);
    CGKeyCode kc = (argc > 2 && (argv[2][0] == 'r' || argv[2][0] == 'R')) ? 60 : 56;
    shift(1, kc);
    printf("Shift 按下 (keycode %d)，保持 %d ms\n", kc, ms);
    fflush(stdout);
    usleep(ms * 1000);
    shift(0, kc);
    printf("Shift 松开\n");
    return 0;
}
