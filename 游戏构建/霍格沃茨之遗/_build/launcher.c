// ============================================================================
// 霍格沃茨之遗 —— 原生启动器（Mach-O）
//
// 为什么不用 shell 脚本当主可执行文件：
//   LaunchServices 会把"主可执行文件是脚本"的 app 误记为常驻运行态，
//   之后 open -a / 双击只会去"激活"它，不再真正启动，报
//   "Application ... was already running and so the additional environment
//    variables could not be set"。换成真正的 Mach-O 就不会有这个问题。
//
// 职责：拼好 D3DMetal + Wine 的运行环境 → execv wine → 等它退出。
// 顺便挂两个辅助进程：caffeinate（防 App Nap/降频）、auto_dismiss.py（点掉驱动警告）。
//
// 编译：
//   clang -O2 -Wall -o /tmp/Sikarugir launcher.c
//   codesign --force --sign - /tmp/Sikarugir
//   cp /tmp/Sikarugir "<APP>/Contents/MacOS/Sikarugir"
// ============================================================================

#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static char g_exe[PATH_MAX];
static char g_app[PATH_MAX];
static char g_macos[PATH_MAX];
static char g_sup[PATH_MAX];
static char g_wine[PATH_MAX];
static char g_game[PATH_MAX];
static char g_trace[PATH_MAX];

static void dir_of(char *p) {
    char *s = strrchr(p, '/');
    if (s && s != p) *s = '\0';
}

static void trace(const char *fmt, ...) {
    FILE *f = fopen(g_trace, "a");
    if (!f) return;
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);
    fprintf(f, "%s  ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static void setenv_if_absent(const char *k, const char *v) {
    if (getenv(k) == NULL) setenv(k, v, 1);
}

// 只 fork 不等待，用于辅助进程
static pid_t spawn(char *const argv[], const char *outpath) {
    pid_t p = fork();
    if (p != 0) return p;
    if (outpath) {
        int fd = open(outpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
    } else {
        int fd = open("/dev/null", O_WRONLY);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
    }
    execv(argv[0], argv);
    _exit(127);
}

// 用「通知」而不是「alert」：alert 是模态的，万一卡住用户根本关不掉。
static void notify(const char *title, const char *body) {
    char script[1024];
    snprintf(script, sizeof script,
             "display notification \"%s\" with title \"%s\"", body, title);
    char *argv[] = {"/usr/bin/osascript", "-e", script, NULL};
    spawn(argv, NULL);
}

int main(int argc, char **argv) {
    uint32_t sz = sizeof g_exe;
    if (_NSGetExecutablePath(g_exe, &sz) != 0) return 1;
    char resolved[PATH_MAX];
    if (realpath(g_exe, resolved) == NULL) return 1;
    strlcpy(g_exe, resolved, sizeof g_exe);

    strlcpy(g_macos, g_exe, sizeof g_macos);
    dir_of(g_macos);                 // .../Contents/MacOS
    strlcpy(g_app, g_macos, sizeof g_app);
    dir_of(g_app);                   // .../Contents
    dir_of(g_app);                   // ....app

    snprintf(g_sup, sizeof g_sup, "%s/Contents/SharedSupport", g_app);
    snprintf(g_wine, sizeof g_wine, "%s/wine/bin/wine", g_sup);
    snprintf(g_game, sizeof g_game,
             "%s/prefix/drive_c/Hogwarts Legacy Complete/Phoenix/Binaries/Win64",
             g_sup);

    const char *home = getenv("HOME");
    if (!home) home = "/tmp";
    snprintf(g_trace, sizeof g_trace, "%s/Library/Logs/HogwartsLegacy-launcher.log",
             home);

    struct stat st;
    if (stat(g_wine, &st) != 0) {
        notify("霍格沃茨之遗", "找不到内嵌 Wine，请确认固态盘已插好");
        trace("错误：找不到 wine：%s", g_wine);
        return 1;
    }

    trace("启动器开始：APP=%s", g_app);

    // —— 防重复启动 ——
    // 用 flock 锁文件：进程无论怎么退出（包括被强杀）锁都会自动释放，
    // 不会像 pgrep 那样因为残留进程误判，也不会弹模态框卡住用户。
    {
        char lockp[PATH_MAX];
        snprintf(lockp, sizeof lockp, "%s/Library/Caches/HogwartsLegacy.lock", home);
        int lfd = open(lockp, O_WRONLY | O_CREAT, 0644);
        if (lfd >= 0) {
            if (flock(lfd, LOCK_EX | LOCK_NB) != 0) {
                notify("霍格沃茨之遗", "游戏已经在运行了");
                trace("已在运行，退出");
                return 0;
            }
            // 故意不关闭 lfd：锁要跟着进程活到结束
        }
    }

    // —— D3DMetal 接线 ——
    char r[PATH_MAX], ext[PATH_MAX], p[PATH_MAX];
    snprintf(r, sizeof r, "%s/Contents/Frameworks/renderer/d3dmetal", g_app);
    snprintf(ext, sizeof ext, "%s/external", r);

    char tmp[PATH_MAX * 3];
    snprintf(p, sizeof p, "%s/prefix", g_sup);
    setenv("WINEPREFIX", p, 1);

    setenv("CX_D3DMETALPATH", r, 1);
    snprintf(p, sizeof p, "%s/libd3dshared.dylib", ext);
    setenv("CX_APPLEGPT_LIBD3DSHARED_PATH", p, 1);
    setenv("CX_APPLEGPTK_LIBD3DSHARED_PATH", p, 1);

    // 必须包含 Contents/Frameworks：libfreetype / libgnutls / libMoltenVK 都在这里。
    // 少了它 Wine 找不到字体 → 窗口客户区塌成 0（只剩标题栏的"小横条"），
    // 游戏会永远卡在一个点不动的对话框上。
    snprintf(tmp, sizeof tmp, "%s:%s/Contents/Frameworks", ext, g_app);
    setenv("DYLD_FRAMEWORK_PATH", tmp, 1);

    snprintf(tmp, sizeof tmp, "%s:%s/Contents/Frameworks:%s/wine/lib", ext, g_app, g_sup);
    setenv("DYLD_FALLBACK_LIBRARY_PATH", tmp, 1);

    snprintf(p, sizeof p, "%s/wine", r);
    setenv("WINEDLLPATH_PREPEND", p, 1);

    // —— 渲染后端 ——
    setenv("D3DMETAL", "1", 1);
    setenv("D3DM_ENABLE_METALFX", "1", 1);
    // 注意：不要加 D3DM_BOUNDS_CHECK=0 / D3DM_ALLOW_HOOKING=0。
    // 实测会在「准备着色器」阶段触发 EXCEPTION_ACCESS_VIOLATION 崩溃。

    // —— 同步原语 ——
    setenv("WINEESYNC", "1", 1);
    setenv("WINEMSYNC", "1", 1);

    // —— CPU 拓扑 ——
    // 去掉这一行实测会崩（D3DMetal 内部依赖稳定的核数上报）。
    // 4:0,1,2,3 = 报 4 个逻辑核，落在 4 个性能核上。
    setenv_if_absent("WINE_CPU_TOPOLOGY", "4:0,1,2,3");

    // —— 日志 ——
    int want_log = getenv("HL_LOG") && strcmp(getenv("HL_LOG"), "1") == 0;
    if (getenv("WINEDEBUG") == NULL)
        setenv("WINEDEBUG", want_log ? "err+all" : "-all", 1);
    // 默认全关：游戏每帧都会刷 RtlGetDeviceFamilyInfoEnum 之类的 fixme，
    // 格式化+写盘是实打实的开销。

    if (getenv("HL_HUD") && strcmp(getenv("HL_HUD"), "1") == 0)
        setenv("MTL_HUD_ENABLED", "1", 1);

    if (chdir(g_game) != 0) {
        trace("错误：无法进入游戏目录 %s (%s)", g_game, strerror(errno));
        return 1;
    }

    // —— 拼 wine 参数：wine HogwartsLegacy.exe <透传参数> ——
    char **wargv = calloc((size_t)argc + 2, sizeof(char *));
    int n = 0;
    wargv[n++] = g_wine;
    wargv[n++] = "HogwartsLegacy.exe";
    for (int i = 1; i < argc; i++) wargv[n++] = argv[i];
    wargv[n] = NULL;

    char logout[PATH_MAX];
    snprintf(logout, sizeof logout, "%s/Library/Logs/HogwartsLegacy.log", home);

    pid_t wine = fork();
    if (wine < 0) { trace("fork 失败"); return 1; }
    if (wine == 0) {
        int fd = want_log ? open(logout, O_WRONLY | O_CREAT | O_TRUNC, 0644)
                          : open("/dev/null", O_WRONLY);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        execv(g_wine, wargv);
        _exit(127);
    }

    trace("wine 已拉起：pid=%d  拓扑=%s  WINEDEBUG=%s", wine,
          getenv("WINE_CPU_TOPOLOGY"), getenv("WINEDEBUG"));

    // —— 防 App Nap / 降频 ——
    // macOS 会把"用户没在交互"的进程降 QoS、赶到能效核上；全屏游戏正是这种状态。
    char pbuf[32];
    snprintf(pbuf, sizeof pbuf, "%d", wine);
    char *cargv[] = {"/usr/bin/caffeinate", "-dims", "-w", pbuf, NULL};
    pid_t caff = spawn(cargv, NULL);

    // —— 兜底：点掉「显卡驱动警告」对话框 ——
    // 它是 Wine 内部 Win32 窗口，辅助功能点击会被 TCC 拒绝，
    // 所以用 CGEventPostToPid 直接投递回车键（纯 ctypes，系统 python3 就能跑）。
    char ad[PATH_MAX];
    snprintf(ad, sizeof ad, "%s/auto_dismiss.py", g_macos);
    if (access(ad, R_OK) == 0) {
        const char *pys[] = {"/usr/bin/python3", "/opt/homebrew/bin/python3", NULL};
        for (int i = 0; pys[i]; i++) {
            if (access(pys[i], X_OK) == 0) {
                char *aargv[] = {(char *)pys[i], ad, pbuf, NULL};
                spawn(aargv, NULL);
                break;
            }
        }
    }

    int status = 0;
    while (waitpid(wine, &status, 0) < 0 && errno == EINTR) {}
    int rc = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    trace("wine 退出：code=%d", rc);

    if (caff > 0) kill(caff, SIGTERM);
    return 0;
}
