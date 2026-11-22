// curpos —— 打印当前系统光标位置（x y）
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>

int main(void) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    printf("%.0f %.0f\n", p.x, p.y);
    return 0;
}
