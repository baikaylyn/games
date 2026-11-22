#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
int main(void){
    printf("辅助功能(发事件)  = %s\n", CGPreflightPostEventAccess() ? "已授权" : "未授权");
    printf("输入监控(收事件)  = %s\n", CGPreflightListenEventAccess() ? "已授权" : "未授权");
    return 0;
}
