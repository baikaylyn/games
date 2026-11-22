// keypress <键码> [次数] [间隔毫秒] —— 用 CGEvent 投递按键到当前会话
// 键码用 macOS 虚拟键码：36=Return 49=Space 53=Esc 48=Tab 13=W 0=A 1=S 2=D
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "用法: keypress <键码> [次数] [间隔ms]\n"); return 2; }
    CGKeyCode code = (CGKeyCode)atoi(argv[1]);
    int times = argc > 2 ? atoi(argv[2]) : 1;
    int gap = argc > 3 ? atoi(argv[3]) : 300;
    if (times < 1) times = 1;
    if (gap < 20) gap = 20;

    if (!CGPreflightPostEventAccess()) {
        fprintf(stderr, "警告：当前进程没有「辅助功能/输入监控」权限，事件大概率被丢弃\n");
    }
    for (int i = 0; i < times; i++) {
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, code, true);
        CGEventRef up = CGEventCreateKeyboardEvent(NULL, code, false);
        CGEventPost(kCGHIDEventTap, down);
        usleep(20000);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(down); CFRelease(up);
        usleep(gap * 1000);
    }
    printf("已投递 %d 次键码 %d\n", times, code);
    return 0;
}
