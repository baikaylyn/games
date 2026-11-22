/*
 * 虐杀原形 (Prototype) macOS 启动器
 *
 * 与塞尔达两个 Mac 原生版同一个思路：一个原生 arm64 的 Cocoa 启动器，把所有可调项翻译成环境变量，
 * 再 exec 内嵌在 App 里的 Wine。游戏本体、Wine、启动器全在 App 内，数据（Wine 前缀、存档、日志、
 * 本设置文件）放在 ~/Library/Application Support/MacNativeGames/PROTOTYPE/，所以整个 App 可以
 * 直接拷到别的 Apple Silicon Mac 上双击运行。
 *
 * 为什么不是"原生移植"：王国之泪能原生跑，是因为 Switch 和 Apple 芯片都是 ARM64，机器码可以原样执行，
 * 项目只需要补加载器 / Horizon OS 服务 / NVN→Metal 三层。虐杀原形是 2009 年的 x86-32 Windows 程序
 * （PE32 / i386 / DirectX 9），指令集和操作系统 API 全都不同，没有"补一层"的可能。它必须经过
 * Rosetta 2 翻译 x86 指令 + Wine 实现 Win32 API + D3D9 转 Metal/OpenGL 才能跑。这个启动器管的
 * 就是最后那层——把这三层里所有能调的旋钮集中到界面上。
 *
 * 几个踩过的坑，直接写进代码里，不要"优化"掉：
 *  1. App 必须装在纯英文路径下。游戏用 ANSI 接口取自己的目录，路径里只要有中文（比如 ~/Games/虐杀原形/）
 *     就会被转成 "????"，引擎初始化直接失败——表现为一个白窗口，然后几十秒后静默退出。给进程设
 *     LANG=zh_CN.UTF-8 也能绕过（ANSI 代码页变 936），但实测那样跑几分钟容易死锁崩溃，不如路径保持英文。
 *  2. 必须限制 CPU 核心数。游戏自带 Restrict Cores.bat（start /affinity F，即 4 核）。不限制时
 *     Wine 里会出现 RtlpWaitForCriticalSection 死锁，然后 "Exception frame is not in stack limits"
 *     崩溃——一般跑一两分钟就挂。
 *  3. 默认不要用 DXVK。DXVK-macOS 1.10.3 配 Wine 11 自带的 MoltenVK 1.4 建不出 Vulkan 设备
 *     （DxvkAdapter: Failed to create device），随后游戏在引擎里空指针崩溃。Wine 自带的 wined3d
 *     （OpenGL）反而能正常出画面。DXVK 作为实验选项保留，换上配套的 MoltenVK 才可能生效。
 *  4. 默认走虚拟桌面（explorer /desktop=WxH）。直接全屏时 Wine 会接管整块屏幕并捕获显示器，
 *     退出/切换 Space 都不方便；虚拟桌面里游戏是普通窗口，尺寸也更可控。
 *  5. 关掉 wined3d 的 Vulkan 探测（WINEDLLOVERRIDES 里加 winevulkan=d）。wined3d 初始化时会建一个
 *     Vulkan 实例，D3D9 走 OpenGL，本来用不到；关掉能少一段 MoltenVK 初始化。切 DXVK 后端时必须放开。
 *     ——更正：曾经把「启动阶段约一半概率崩溃」归因到这里，是错的。实测关了 Vulkan 探测崩溃率并没下降
 *     （11 次样本仍是一半），真正的根因见第 8 条。这条留着只是因为它本身无害、且省一点启动开销。
 *  6. 配置类文件绝对不能写进 App 包里。以前 dxvk.conf 写在 Game/ 下，等于每次点「开始游戏」
 *     都在改 bundle 里的文件——codesign 的资源封印记的是内容哈希，内容一变 ad-hoc 签名就作废
 *     （codesign -v 报 resource modified），之后双击没反应。现在写到数据目录，用
 *     DXVK_CONFIG_FILE 指过去，bundle 只读。
 *  7. DXVK 选项要能自证可用。选 d3d9=n 的前提是 Game/ 里真的躺着一个 DXVK 的 d3d9.dll；
 *     没有的话 wine 找不到原生库，进程起不到一秒就退，日志一个字都不留（本机踩过，
 *     表现为"点了开始游戏什么都没发生"）。现在按文件存在与否自动禁用这一项，启动前再拦一次。
 *  8. 【启动崩溃的真正根因】日志里那种
 *       wine: Unhandled page fault on read access to 00002DC1 at address 7BF21239
 *     不是游戏、不是显卡、也不是 Vulkan：0x7BF20000 是 wow64cpu.dll 的装载基址，偏移 0x1239 和
 *     0x1135 分别是 syscall / unixcall 的 32→64 位入口 thunk。虐杀原形是 PE32，在 Apple Silicon 上
 *     只能跑 Wine 的新式 WoW64（64 位进程里装 32 位 PE），每次系统调用都要在两种 CPU 模式间切换；
 *     Rosetta 2 偶尔不真正切换，于是 CPU 还在 32 位模式下执行 64 位的指令，把指令里的位移字段
 *     （0x2DC1 / 0x2EC5）当成地址去读 —— 读出来的低地址一定不存在，必然 page fault。
 *     反汇编那两个偏移正是 `8b 15 c1 2d 00 00`（mov edx,[rip+0x2dc1]），与崩溃报告逐位对上。
 *     Wine 官方把这类问题判成 NOTOURBUG（Rosetta 的问题，不在 Wine 侧修）。
 *     解决办法是给 wow64cpu.dll 打二进制补丁：两个 32→64 入口改走"能判断当前模式"的 trampoline，
 *     两个 64→32 返回站点改成构造 iretq 帧后用 iretq 返回。补丁工具见 _build/wow64cpu_rosetta_patch.py，
 *     原文件备份在同目录 wow64cpu.dll.orig。实测 12 次启动 0 次崩溃（未打补丁时约一半）。
 *     换 Wine 版本后补丁会消失，下面的 wow64cpuPatched 会把它报进 launcher.log。
 */

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <sys/stat.h>
#import <sys/resource.h>
#import <libproc.h>

/* ------------------------------------------------------------------ 路径 */

static NSString *DataDir(void) {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MacNativeGames"];
    return [base stringByAppendingPathComponent:@"PROTOTYPE"];
}

static NSString *BundlePath(NSString *rel) {
    return [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:rel];
}

static BOOL IsDir(NSString *p) {
    BOOL d = NO;
    return p && [[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&d] && d;
}

static void MakeDir(NSString *p) {
    [[NSFileManager defaultManager] createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:NULL];
}

/* 前缀里还有没有 wine 的进程在跑。
   为什么要问这个：wineserver -k 是异步的，它返回的时候进程往往还没退干净。
   这时候马上再起一个 wine，新会话会被正在消失的旧服务端拖死——启动 1~2 秒就退出，
   看门狗把它当成又一次失败，几秒钟内就能把重试次数烧光。
   按可执行文件路径筛选，只认这个 App 里的进程，不会误伤别的 Wine 程序。 */
static void CollectWinePids(NSMutableArray<NSNumber *> *out) {
    NSString *wineDir = BundlePath(@"Contents/Resources/Wine");
    NSString *gameDir = BundlePath(@"Contents/Resources/Game");
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return;
    int cap = n + 64;
    pid_t *pids = malloc(sizeof(pid_t) * (size_t)cap);
    if (!pids) return;
    int got = proc_listallpids(pids, sizeof(pid_t) * cap);
    if (got > cap) got = cap;
    for (int i = 0; i < got; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        NSString *p = @(path);
        if ([p hasPrefix:wineDir] || [p hasPrefix:gameDir]) [out addObject:@(pids[i])];
    }
    free(pids);
}

static BOOL WineSessionBusy(void) {
    NSMutableArray<NSNumber *> *a = [NSMutableArray array];
    CollectWinePids(a);
    return a.count > 0;
}

/* 游戏主进程到底起来没有。
   为什么要单独判：走虚拟桌面时 wine 会先起 explorer，再由 explorer 去 CreateProcess
   起游戏——这两步之间"explorer 活着"和"游戏活着"完全是两回事。从 Finder 启动时
   见过 explorer 起来了、游戏永远不出现的情况（见 checkForStartupCrash 里的兜底）。 */
static BOOL GameProcessRunning(void) {
    NSString *exePath = BundlePath(@"Contents/Resources/Game/prototypef.exe");
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return NO;
    int cap = n + 64;
    pid_t *pids = malloc(sizeof(pid_t) * (size_t)cap);
    if (!pids) return NO;
    int got = proc_listallpids(pids, sizeof(pid_t) * cap);
    if (got > cap) got = cap;
    BOOL found = NO;
    for (int i = 0; i < got && !found; i++) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        if ([@(path) isEqualToString:exePath]) found = YES;
    }
    free(pids);
    return found;
}

static void ForceKillWine(void) {
    NSMutableArray<NSNumber *> *a = [NSMutableArray array];
    CollectWinePids(a);
    for (NSNumber *pid in a) kill(pid.intValue, SIGKILL);
}

/* 整个会话累计吃掉了多少 CPU 秒。用来分辨「真的在干活」和「卡死了」：
   启动阶段（解包、编译着色器、读 8 GB 的 rcf）CPU 是持续烧的，一秒钟零点几秒；
   卡死时主线程在等一个永远不来的事件，整个会话的 CPU 时间几乎不涨。
   这条判据比"多少秒没画面"可靠得多——后者会把正在正常游玩的局误杀。 */
static double WineCpuSeconds(void) {
    NSMutableArray<NSNumber *> *a = [NSMutableArray array];
    CollectWinePids(a);
    double total = 0;
    struct rusage_info_v4 ri;
    for (NSNumber *pid in a) {
        if (proc_pid_rusage(pid.intValue, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0)
            total += (double)(ri.ri_user_time + ri.ri_system_time) / 1e9;
    }
    return total;
}

/* ------------------------------------------------------------------ 启动器 */

@interface Launcher : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *win;
@property (nonatomic, strong) NSMutableDictionary *saved;

@property (nonatomic, strong) NSPopUpButton *backendPop, *resPop, *coresPop, *logPop, *modePop, *fpsPop;
@property (nonatomic, strong) NSButton *highPrioCheck, *fpsLogCheck;
@property (nonatomic, strong) NSTextField *status;
@property (nonatomic, strong) NSButton *playBtn;
@property (nonatomic) BOOL running;
@property (nonatomic, strong) NSTimer *watch;
@property (nonatomic) int attempt;
@property (nonatomic) unsigned long long logStart;
@property (nonatomic) BOOL retrying;
@property (nonatomic) NSDate *launchTime;        /* 本次启动的时刻 */
@property (nonatomic) NSDate *lastGrow;          /* 日志最后一次变长的时刻 */
@property (nonatomic) unsigned long long lastSize;
@property (nonatomic) BOOL forceVerbose;         /* 重试时把日志调详细，用来错开时序 */
@property (nonatomic, strong) NSData *runMarker; /* 本次启动写进日志的分隔行，用来定位"本次"的日志起点 */
@property (nonatomic) BOOL launching;            /* 防止重试链里同时起两个 wine */
/* 这一局是不是走虚拟桌面起的。虚拟桌面从 Finder 启动会拉不起游戏（见 checkForStartupCrash）。 */
@property (nonatomic) BOOL usedDesktop;
/* 已经确认这台机器"从 Finder 启动时虚拟桌面拉不起游戏"，之后一律直连启动。
   存进设置，免得每次开游戏都白等 8 秒去试一遍。 */
@property (nonatomic) BOOL forceDirect;
@property (nonatomic, strong) NSTimer *centerTimer;
@property (nonatomic) NSInteger centerTries;
@property (nonatomic) BOOL centerLogged;
@property (nonatomic, strong) NSTask *task;      /* 当前这一次启动的 wine 进程 */
@property (nonatomic) BOOL retryPending;         /* 已经排好一次重试，别重复排 */
@property (nonatomic) BOOL preflight;            /* 正在清理残留会话，期间不接第二次点击 */
@property (nonatomic) double cpuMark;            /* 上一次采样的 CPU 累计秒 */
@property (nonatomic) NSTimeInterval cpuMarkAt;  /* 上一次采样时的 elapsed */
@property (nonatomic) BOOL watchdogFired;        /* 本次启动已经由看门狗判死，别再让退出回调重复计数 */
@end

@implementation Launcher

/* ---------------------------------------------------------- 设置读写 */

- (NSString *)settingsPath { return [DataDir() stringByAppendingPathComponent:@"launcher-settings.json"]; }
- (NSString *)prefixPath   { return [DataDir() stringByAppendingPathComponent:@"prefix"]; }
- (NSString *)logPath      { return [DataDir() stringByAppendingPathComponent:@"logs/prototype.log"]; }
- (NSString *)dxvkConfPath { return [DataDir() stringByAppendingPathComponent:@"dxvk.conf"]; }

/* DXVK 这条路实测走不通（Metal 没有几何着色器，MoltenVK 报不出 geometryShader，
   D3D9 的 DXVK 实现必然建不出设备）。但只要有人往 Game/ 里放一份 d3d9.dll，
   这一项就有意义了，所以判据不是"写死不可用"，而是"原生库在不在"。 */
- (BOOL)dxvkAvailable {
    return [[NSFileManager defaultManager] fileExistsAtPath:
            BundlePath(@"Contents/Resources/Game/d3d9.dll")];
}

- (BOOL)useDXVK {
    return self.backendPop.indexOfSelectedItem == 1 && [self dxvkAvailable];
}

- (void)loadSettings {
    self.saved = [NSMutableDictionary dictionary];
    NSData *d = [NSData dataWithContentsOfFile:self.settingsPath];
    if (d) {
        id o = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
        if ([o isKindOfClass:NSDictionary.class]) self.saved = [o mutableCopy];
    }
}

- (void)saveSettings {
    NSDictionary *d = @{
        @"backend":   self.backendPop.titleOfSelectedItem ?: @"wined3d",
        @"mode":      @(self.modePop.indexOfSelectedItem),
        @"res":       self.resPop.titleOfSelectedItem ?: @"1280x720",
        @"fps":       @(self.fpsPop.indexOfSelectedItem),
        @"cores":     @(self.coresPop.indexOfSelectedItem),
        @"log":       @(self.logPop.indexOfSelectedItem),
        @"highprio":  @(self.highPrioCheck.state == NSControlStateValueOn),
        @"fpslog":    @(self.fpsLogCheck.state == NSControlStateValueOn),
        @"forcedirect": @(self.forceDirect),
    };
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:NULL];
    MakeDir(DataDir());
    [j writeToFile:self.settingsPath atomically:YES];
}

- (NSString *)savedString:(NSString *)k def:(NSString *)v {
    id o = self.saved[k];
    return [o isKindOfClass:NSString.class] ? o : v;
}
- (NSInteger)savedInt:(NSString *)k def:(NSInteger)v {
    id o = self.saved[k];
    return [o isKindOfClass:NSNumber.class] ? [o integerValue] : v;
}
- (BOOL)savedBool:(NSString *)k def:(BOOL)v {
    id o = self.saved[k];
    return [o isKindOfClass:NSNumber.class] ? [o boolValue] : v;
}

/* ---------------------------------------------------------- 界面搭建 */

- (NSButton *)check:(NSString *)title frame:(NSRect)f on:(BOOL)on {
    NSButton *b = [[NSButton alloc] initWithFrame:f];
    b.buttonType = NSButtonTypeSwitch;
    b.title = title;
    b.font = [NSFont systemFontOfSize:12];
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    return b;
}

- (NSTextField *)label:(NSString *)t frame:(NSRect)f {
    NSTextField *l = [[NSTextField alloc] initWithFrame:f];
    l.stringValue = t;
    l.bezeled = NO;
    l.drawsBackground = NO;
    l.editable = NO;
    l.selectable = NO;
    l.font = [NSFont systemFontOfSize:12];
    return l;
}

- (NSPopUpButton *)pop:(NSRect)f items:(NSArray<NSString *> *)items sel:(NSInteger)sel {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:f pullsDown:NO];
    [p addItemsWithTitles:items];
    if (sel >= 0 && sel < (NSInteger)items.count) [p selectItemAtIndex:sel];
    p.font = [NSFont systemFontOfSize:12];
    return p;
}

- (void)buildUI {
    self.win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 480)
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    self.win.title = @"虐杀原形 (Prototype)";
    self.win.releasedWhenClosed = NO;
    NSView *v = self.win.contentView;

    NSTextField *title = [self label:@"虐杀原形  PROTOTYPE" frame:NSMakeRect(20, 435, 300, 24)];
    title.font = [NSFont boldSystemFontOfSize:17];
    [v addSubview:title];

    NSTextField *sub = [self label:@"Wine + Rosetta 2 · DirectX 9 → OpenGL/Vulkan" frame:NSMakeRect(20, 413, 420, 18)];
    sub.font = [NSFont systemFontOfSize:11];
    sub.textColor = [NSColor secondaryLabelColor];
    [v addSubview:sub];

    /* 渲染后端 */
    [v addSubview:[self label:@"渲染后端" frame:NSMakeRect(20, 378, 90, 18)]];
    self.backendPop = [self pop:NSMakeRect(115, 374, 240, 26)
                          items:@[@"wined3d（OpenGL，稳定）", @"DXVK（Vulkan，实验）"]
                            sel:0];
    /* Game/ 里没有 DXVK 的 d3d9.dll 时，选 DXVK 等于让 wine 去找一个不存在的原生库，
       进程秒退且日志空白。把这一项直接灰掉，别让人踩进去。 */
    if (![self dxvkAvailable]) {
        [[self.backendPop itemAtIndex:1] setEnabled:NO];
        self.backendPop.toolTip = @"DXVK 需要 Game 目录里有 d3d9.dll；本机没有，"
                                  @"且 Metal 缺几何着色器这条路本来走不通，固定用 wined3d。";
    }
    [v addSubview:self.backendPop];

    /* 显示模式 */
    [v addSubview:[self label:@"显示模式" frame:NSMakeRect(20, 344, 90, 18)]];
    self.modePop = [self pop:NSMakeRect(115, 340, 240, 26)
                       items:@[@"窗口（居中显示，推荐）", @"独占全屏"]
                         sel:0];
    [v addSubview:self.modePop];

    /* 分辨率 */
    [v addSubview:[self label:@"分辨率" frame:NSMakeRect(20, 310, 90, 18)]];
    self.resPop = [self pop:NSMakeRect(115, 306, 240, 26)
                      items:@[@"1024x768", @"1280x720", @"1366x768", @"1600x900", @"1920x1080", @"2560x1440"]
                        sel:1];
    [v addSubview:self.resPop];

    /* CPU 核心 */
    [v addSubview:[self label:@"CPU 核心" frame:NSMakeRect(20, 276, 90, 18)]];
    self.coresPop = [self pop:NSMakeRect(115, 272, 240, 26)
                        items:@[@"2 核", @"4 核（游戏自带脚本的值）", @"6 核", @"8 核", @"全部核心"]
                          sel:1];
    [v addSubview:self.coresPop];

    /* 帧率上限 */
    [v addSubview:[self label:@"帧率上限" frame:NSMakeRect(20, 242, 90, 18)]];
    self.fpsPop = [self pop:NSMakeRect(115, 238, 240, 26)
                      items:@[@"60 帧（推荐，凉快）", @"90 帧", @"120 帧", @"不限"]
                        sel:0];
    [v addSubview:self.fpsPop];

    NSTextField *fpsHint = [self label:@"60 帧需要游戏内 OPTIONS → VIDEO 打开 Vertical Sync（设一次即存进存档）"
                                 frame:NSMakeRect(115, 220, 385, 16)];
    fpsHint.font = [NSFont systemFontOfSize:10];
    fpsHint.textColor = [NSColor tertiaryLabelColor];
    [v addSubview:fpsHint];

    /* 日志 */
    [v addSubview:[self label:@"日志" frame:NSMakeRect(20, 192, 90, 18)]];
    self.logPop = [self pop:NSMakeRect(115, 188, 240, 26)
                      items:@[@"正常（推荐）", @"详细（排查用，很慢）"]
                        sel:0];
    [v addSubview:self.logPop];

    /* 复选框 */
    self.highPrioCheck = [self check:@"提高进程优先级（减少掉帧）" frame:NSMakeRect(20, 158, 300, 22) on:YES];
    [v addSubview:self.highPrioCheck];

    self.fpsLogCheck = [self check:@"把帧率写进日志（重启游戏后看日志）" frame:NSMakeRect(20, 132, 320, 22) on:NO];
    [v addSubview:self.fpsLogCheck];

    /* 分隔线 */
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(20, 120, 480, 1)];
    line.boxType = NSBoxSeparator;
    [v addSubview:line];

    /* 按钮 */
    self.playBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, 76, 118, 34)];
    self.playBtn.title = @"开始游戏";
    self.playBtn.bezelStyle = NSBezelStyleRounded;
    self.playBtn.keyEquivalent = @"\r";
    self.playBtn.font = [NSFont boldSystemFontOfSize:13];
    self.playBtn.target = self;
    self.playBtn.action = @selector(play:);
    [v addSubview:self.playBtn];

    /* 游戏卡住时唯一靠谱的收场方式：不管界面有没有响应，直接把 wine 进程全杀掉。
       有它就不必再靠"多少秒没动静就猜你卡死了"这种会误杀的启发式。 */
    NSButton *stop = [[NSButton alloc] initWithFrame:NSMakeRect(136, 80, 72, 26)];
    stop.title = @"结束游戏";
    stop.bezelStyle = NSBezelStyleRounded;
    stop.font = [NSFont systemFontOfSize:11];
    stop.target = self;
    stop.action = @selector(stopGame:);
    [v addSubview:stop];

    NSButton *openData = [[NSButton alloc] initWithFrame:NSMakeRect(212, 80, 74, 26)];
    openData.title = @"存档目录";
    openData.bezelStyle = NSBezelStyleRounded;
    openData.font = [NSFont systemFontOfSize:11];
    openData.target = self;
    openData.action = @selector(openSaves:);
    [v addSubview:openData];

    NSButton *backup = [[NSButton alloc] initWithFrame:NSMakeRect(290, 80, 74, 26)];
    backup.title = @"备份存档";
    backup.bezelStyle = NSBezelStyleRounded;
    backup.font = [NSFont systemFontOfSize:11];
    backup.target = self;
    backup.action = @selector(backupSaves:);
    [v addSubview:backup];

    NSButton *openLog = [[NSButton alloc] initWithFrame:NSMakeRect(368, 80, 44, 26)];
    openLog.title = @"日志";
    openLog.bezelStyle = NSBezelStyleRounded;
    openLog.font = [NSFont systemFontOfSize:11];
    openLog.target = self;
    openLog.action = @selector(openLog:);
    [v addSubview:openLog];

    NSButton *reset = [[NSButton alloc] initWithFrame:NSMakeRect(416, 80, 84, 26)];
    reset.title = @"重置环境";
    reset.bezelStyle = NSBezelStyleRounded;
    reset.font = [NSFont systemFontOfSize:11];
    reset.target = self;
    reset.action = @selector(resetPrefix:);
    [v addSubview:reset];

    self.status = [self label:@"就绪" frame:NSMakeRect(20, 20, 480, 40)];
    self.status.font = [NSFont systemFontOfSize:11];
    self.status.textColor = [NSColor secondaryLabelColor];
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    self.status.maximumNumberOfLines = 3;
    [v addSubview:self.status];

    /* 应用保存的设置。存了 DXVK 但这台机器不可用时，必须自动落回 wined3d：
       否则下次双击 → 点开始游戏 → 进程秒退，看上去就是"启动器坏了"。 */
    NSString *be = [self savedString:@"backend" def:@"wined3d（OpenGL，稳定）"];
    [self.backendPop selectItemWithTitle:be];
    if (self.backendPop.indexOfSelectedItem < 0) [self.backendPop selectItemAtIndex:0];
    if (self.backendPop.indexOfSelectedItem == 1 && ![self dxvkAvailable]) {
        [self.backendPop selectItemAtIndex:0];
        self.status.stringValue = @"已保存的渲染后端是 DXVK，但本机缺少 d3d9.dll，已自动切回 wined3d。";
    }

    NSInteger mode = [self savedInt:@"mode" def:0];
    if (mode >= 0 && mode < self.modePop.numberOfItems) [self.modePop selectItemAtIndex:mode];

    /* 老版本用 `wine explorer /desktop=...` 走虚拟桌面，从 Finder 启动时拉不起游戏，
       于是记了个 forcedirect 的标记。现在窗口化改成走 Wine 注册表，启动命令和直连一样，
       这个标记已经没有意义了，读进来只用于提示，不再影响启动方式。 */
    self.forceDirect = [self savedBool:@"forcedirect" def:NO];
    if (self.forceDirect) {
        self.forceDirect = NO;
        self.status.stringValue = @"窗口模式已改成 Wine 注册表虚拟桌面（双击也能起来），旧的直连标记已清除。";
    }

    NSString *res = [self savedString:@"res" def:@"1280x720"];
    [self.resPop selectItemWithTitle:res];
    if (self.resPop.indexOfSelectedItem < 0) [self.resPop selectItemAtIndex:1];

    NSInteger cores = [self savedInt:@"cores" def:1];
    if (cores >= 0 && cores < self.coresPop.numberOfItems) [self.coresPop selectItemAtIndex:cores];

    NSInteger fps = [self savedInt:@"fps" def:0];
    if (fps >= 0 && fps < self.fpsPop.numberOfItems) [self.fpsPop selectItemAtIndex:fps];

    NSInteger log = [self savedInt:@"log" def:0];
    if (log >= 0 && log < self.logPop.numberOfItems) [self.logPop selectItemAtIndex:log];

    self.highPrioCheck.state = [self savedBool:@"highprio" def:YES] ? NSControlStateValueOn : NSControlStateValueOff;
    self.fpsLogCheck.state  = [self savedBool:@"fpslog" def:NO] ? NSControlStateValueOn : NSControlStateValueOff;

    [self.win center];
    [self.win makeKeyAndOrderFront:nil];
}

/* ---------------------------------------------------------- 运行环境 */

- (NSUInteger)coreCountFromIndex:(NSInteger)i {
    switch (i) {
        case 0: return 2;
        case 1: return 4;
        case 2: return 6;
        case 3: return 8;
        default: return (NSUInteger)[[NSProcessInfo processInfo] activeProcessorCount];
    }
}

- (NSDictionary *)environment {
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];

    env[@"WINEPREFIX"] = self.prefixPath;

    /* 不要覆盖 LANG/LC_ALL。App 装在纯英文路径下，游戏取自己的目录不会碰到中文；
       反过来强行设成 zh_CN.UTF-8 会让 Wine 切到代码页 936，实测更容易在几分钟后
       出现 RtlpWaitForCriticalSection 死锁然后崩溃。路径保持英文是更省事的解法。

       但"不覆盖"不等于"可以没有"：从 Finder / open -a 启动时，LaunchServices 给的环境里
       根本没有 LANG，Wine 退回 C locale，实测游戏会卡在 MoltenVK 建完 VkInstance 之后、
       引擎一行都没加载的状态（21 秒只烧 0.03 CPU 秒），看门狗只能判定"静默卡死"并重试，
       而重试永远不会成功。同一个二进制从终端启动（LANG=en_US.UTF-8）就正常。
       所以这里只在缺失时补一个 UTF-8 英文 locale，不去覆盖用户已有的设置。 */
    if (!env[@"LANG"] || [env[@"LANG"] length] == 0) env[@"LANG"] = @"en_US.UTF-8";

    /* TMPDIR 固定到 /tmp。从 Finder 启动时 launchd 给的是每应用的私有临时目录
       （…/T/com.apple.launchd.xxxx），而从终端启动时是用户级的 …/T/。
       实测前者会让 wine 会话起来后卡在黑窗口——统一成 /tmp 之后两边行为一致。 */
    env[@"TMPDIR"] = @"/tmp";

    /* 日志级别。
       不用 WINEDEBUG=-all：它会连带把崩溃信息也吞掉，看门狗就失去了判断依据（这条是硬理由）。
       另外早先观察到 -all 之后启动更容易卡在 800x450 空窗口，但那大概率只是同一个 Rosetta 问题
       的巧合（见文件头第 8 条），没有单独验证过，不作为结论。
       err+all 只输出错误，噪音和开销都接近零，是安全的下限。 */
    NSInteger log = self.logPop.indexOfSelectedItem;
    NSMutableString *dbg = [NSMutableString stringWithString:((log == 1) || self.forceVerbose) ? @"err+all,fixme+all" : @"err+all"];
    if (self.fpsLogCheck.state == NSControlStateValueOn) [dbg appendString:@",fps"];
    env[@"WINEDEBUG"] = dbg;

    /* CPU 核心限制（见文件头第 2 条）。WINE_CPU_TOPOLOGY=数量:0,1,2... */
    NSUInteger n = [self coreCountFromIndex:self.coresPop.indexOfSelectedItem];
    NSUInteger total = (NSUInteger)[[NSProcessInfo processInfo] activeProcessorCount];
    if (n >= total) {
        [env removeObjectForKey:@"WINE_CPU_TOPOLOGY"];
    } else {
        NSMutableString *ids = [NSMutableString string];
        for (NSUInteger i = 0; i < n; i++) [ids appendFormat:@"%s%lu", i ? "," : "", (unsigned long)i];
        env[@"WINE_CPU_TOPOLOGY"] = [NSString stringWithFormat:@"%lu:%@", (unsigned long)n, ids];
    }

    /* 渲染后端（见文件头第 3、5、7 条）。 */
    if ([self useDXVK]) {
        env[@"WINEDLLOVERRIDES"] = @"d3d9=n";
        env[@"DXVK_LOG_LEVEL"] = @"info";
    } else {
        /* winevulkan=d 是整套配置里最关键的一个稳定性开关。wined3d 初始化时会顺手建一个
           Vulkan 实例（日志里那一大段 [mvk-info]），而这个 MoltenVK 初始化在 Rosetta 下会
           概率性地把进程带崩——表现为启动阶段卡在 800x450 的黑窗口。
           关掉它之后实测 8 次启动 8 次成功（开着是 4 次里挂 2 次）。
           D3D9 走的是 OpenGL，本来就用不到 Vulkan；只有切到 DXVK 后端时不能关。 */
        env[@"WINEDLLOVERRIDES"] = @"d3d9=b;winevulkan=d";
    }

    /* 渲染后端相关的配置文件。注意落在数据目录，不落 Game/（见文件头第 6 条：
       往 bundle 里写文件会让 ad-hoc 签名作废）。
       wined3d 后端不读这个文件，它只是留给切 DXVK 时用，顺便记录当前选择。 */
    env[@"DXVK_CONFIG_FILE"] = self.dxvkConfPath;

    return env;
}

- (NSString *)wineBinary {
    /* Wine 放在 Resources 而不是 Frameworks：codesign 会把 Frameworks 当嵌套代码要求逐个签名，
       而 Wine 树里有几百个未签名的 dylib，签不过来。放 Resources 就当普通数据，只签 App 本体。 */
    return BundlePath(@"Contents/Resources/Wine/bin/wine");
}

/* wow64cpu.dll 有没有打 Rosetta 模式切换补丁（见文件头第 8 条）。
   判据是补丁写在 .text 尾部代码洞里的固定 6 字节：31 c9 41 89 c9 e3
   （xor ecx,ecx / 32 位下 decode 成 inc ecx,mov ecx,ecx / jecxz）。
   只看文件字节，不跑任何东西——换 Wine 版本后这里会变回 NO，启动日志里就会留痕。 */
- (BOOL)wow64cpuPatched {
    NSString *p = BundlePath(@"Contents/Resources/Wine/lib/wine/x86_64-windows/wow64cpu.dll");
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:p];
    if (!fh) return NO;
    BOOL patched = NO;
    @try {
        [fh seekToFileOffset:0x1DA0];
        NSData *d = [fh readDataOfLength:6];
        const unsigned char sig[6] = {0x31, 0xC9, 0x41, 0x89, 0xC9, 0xE3};
        patched = (d.length == 6 && memcmp(d.bytes, sig, 6) == 0);
    } @catch (NSException *e) {
        patched = NO;
    } @finally {
        [fh closeFile];
    }
    return patched;
}

- (void)appendStatus:(NSString *)s {
    self.status.stringValue = s;
}

/* 启动器自己的日志。为什么单独一份：Wine 那份（prototype.log）只记 Windows 侧的输出，
   而"为什么这次没起来"是启动器的判断（第几次尝试、命中了哪个特征、是不是被判静默卡死），
   这些东西在界面上只闪一下，事后没法复盘。有了它，排查不用靠盯着面板看。 */
- (void)launcherLog:(NSString *)fmt, ... {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *dir = [DataDir() stringByAppendingPathComponent:@"logs"];
    MakeDir(dir);
    NSString *p = [dir stringByAppendingPathComponent:@"launcher.log"];

    /* 超过 1 MB 就滚一次，免得无限长。 */
    NSDictionary *a0 = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:NULL];
    if (a0 && [a0[NSFileSize] unsignedLongLongValue] > 1ULL * 1024 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:[p stringByAppendingString:@".old"] error:NULL];
        [[NSFileManager defaultManager] moveItemAtPath:p toPath:[p stringByAppendingString:@".old"] error:NULL];
    }

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"%@  %@\n", [df stringFromDate:[NSDate date]], msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:p];
    }
    [fh seekToEndOfFile];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

/* ---------------------------------------------------------- 动作 */

- (void)play:(id)sender {
    if (self.running || self.preflight) return;

    if (![[NSFileManager defaultManager] fileExistsAtPath:[self wineBinary]]) {
        self.status.stringValue = @"找不到内嵌的 Wine，App 可能被拆开了。";
        return;
    }

    /* 选着 DXVK 但本机没有 d3d9.dll：直接拦下来，别让它变成"点了没反应"。 */
    if (self.backendPop.indexOfSelectedItem == 1 && ![self dxvkAvailable]) {
        [self.backendPop selectItemAtIndex:0];
        self.status.stringValue = @"本机没有 DXVK 的 d3d9.dll，已改用 wined3d。";
    }

    [self saveSettings];
    MakeDir(DataDir());
    MakeDir([DataDir() stringByAppendingPathComponent:@"logs"]);

    [self launcherLog:@"开始：后端=%@ 分辨率=%@ 核心=%@ 帧率=%@ 日志=%@",
        self.backendPop.titleOfSelectedItem, self.resPop.titleOfSelectedItem,
        self.coresPop.titleOfSelectedItem, self.fpsPop.titleOfSelectedItem,
        self.logPop.titleOfSelectedItem];
    [self launcherLog:@"wow64cpu 补丁：%@", [self wow64cpuPatched]
        ? @"已打（Rosetta 模式切换，启动不再概率性崩溃）"
        : @"未打（启动阶段约一半概率在 wow64cpu 崩溃，跑 _build/wow64cpu_rosetta_patch.py）"];
    [self launcherLog:@"MoltenVK：%@", [self moltenVKDisabled]
        ? @"已禁用（wined3d 不会再去建 Vulkan 实例，启动崩溃基本消失）"
        : @"未禁用（wined3d 会建 Vulkan 实例，Rosetta 下概率性 c0000005 退出；把 Wine/lib/libMoltenVK.dylib 改名成 .disabled 即可）"];

    self.playBtn.enabled = NO;
    self.attempt = 0;
    self.forceVerbose = NO;
    self.retryPending = NO;

    /* 启动前先看看有没有上一次残留的 Wine 会话。
       这是出现频率最高的一种"双击没反应"：上一局被强杀过，services.exe / winedevice.exe
       还占着 prefix，新会话就卡在 wineboot --init 上，窗口永远不出来。
       这些进程的命令行里只有 C:\\windows\\system32\\...，没有 App 路径，
       所以按命令行的 pkill 抓不到——必须按可执行文件路径枚举（CollectWinePids 干的事）。 */
    if (WineSessionBusy()) {
        self.preflight = YES;
        self.status.stringValue = @"发现有没退干净的 Wine 进程，正在清理…";
        [self launcherLog:@"发现残留 Wine 会话，先清理再启动"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self killAndWait];
            [self launcherLog:@"残留会话已清理"];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.preflight = NO;
                [self beginPlay];
            });
        });
        return;
    }

    [self beginPlay];
}

/* 清掉会话并等它真的退干净。最多约 10 秒，之后无条件 SIGKILL。 */
- (void)killAndWait {
    if (!WineSessionBusy()) return;

    NSTask *kill = [NSTask new];
    kill.launchPath = [[self wineBinary] stringByDeletingLastPathComponent];
    kill.launchPath = [kill.launchPath stringByAppendingPathComponent:@"wineserver"];
    kill.arguments = @[@"-k"];
    kill.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    kill.standardError = kill.standardOutput;
    @try { [kill launch]; [kill waitUntilExit]; } @catch (NSException *e) { (void)e; }

    for (int i = 0; i < 20; i++) {          /* 20 × 0.3s ≈ 6 秒 */
        if (!WineSessionBusy()) return;
        [NSThread sleepForTimeInterval:0.3];
    }
    ForceKillWine();
    for (int i = 0; i < 10; i++) {          /* 再等 3 秒 */
        if (!WineSessionBusy()) break;
        [NSThread sleepForTimeInterval:0.3];
    }
    /* 进程没了不等于 prefix 就绪：wineserver 还要把注册表落盘、释放 prefix 上的锁。
       实测强杀后 3 秒内起新会话会得到「启动 3 秒就退出（代码 5）」——那是 ERROR_ACCESS_DENIED。
       统一留 2 秒静默期，比让看门狗白烧一次重试划算。 */
    [NSThread sleepForTimeInterval:2.0];
}

- (void)beginPlay {
    self.running = YES;

    if (!IsDir(self.prefixPath)) {
        /* 首次运行：先 wineboot 建前缀。注意 wine 只接受一个程序参数，不能把 wineboot 和游戏
           拼在同一条命令行里（那样 wine 会把后面全部当成 wineboot 的参数，游戏永远不启动）。 */
        self.status.stringValue = @"首次运行：正在初始化 Wine 环境，约需 1 分钟…";
        NSTask *boot = [NSTask new];
        boot.launchPath = self.wineBinary;
        boot.arguments = @[@"wineboot", @"-u"];
        boot.environment = [self environment];
        boot.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        boot.standardError = boot.standardOutput;
        boot.terminationHandler = ^(NSTask *t) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self launchGame]; });
        };
        @try { [boot launch]; } @catch (NSException *e) {
            self.running = NO;
            self.playBtn.enabled = YES;
            self.status.stringValue = [NSString stringWithFormat:@"初始化失败：%@", e.reason];
        }
        return;
    }

    [self launchGame];
}

- (void)launchGame {
    /* 重试有两条触发路径（看门狗发现崩溃、进程提前退出），如果 wineserver -k 慢了半拍，
       两边会同时走到这里，起两个 wine 会话互相打架。加个闸。 */
    if (self.launching) return;
    self.launching = YES;

    NSString *gameDir = BundlePath(@"Contents/Resources/Game");
    NSString *exe = [gameDir stringByAppendingPathComponent:@"prototypef.exe"];

    /* 帧率上限：wined3d 自己没有限帧开关，只能靠游戏的 Vertical Sync（D3DPRESENT_INTERVAL_ONE
       → 等垂直同步 → 锁到显示器刷新率 60）。DXVK 后端有 d3d9.maxFrameRate，写进 dxvk.conf 即可，
       与游戏内设置无关。两种情况都把配置写下来，切换后端时不用手动改。 */
    NSInteger fpsIdx = self.fpsPop.indexOfSelectedItem;
    NSInteger fps = (fpsIdx == 0) ? 60 : (fpsIdx == 1) ? 90 : (fpsIdx == 2) ? 120 : 0;
    NSString *conf = [NSString stringWithFormat:
        @"# 由启动器生成：帧率上限 %@\n"
        @"# wined3d 后端忽略此文件，请把游戏内 OPTIONS → VIDEO 的 Vertical Sync 打开。\n"
        @"d3d9.maxFrameRate = %ld\n"
        @"d3d9.presentInterval = %d\n",
        fps ? [NSString stringWithFormat:@"%ld 帧", (long)fps] : @"不限",
        (long)fps, fps ? 1 : 0];
    [conf writeToFile:self.dxvkConfPath
           atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    /* 先把「窗口 / 全屏」写进 Wine 注册表，再按同一条命令启动。
       窗口化 = 注册表虚拟桌面，全屏 = 删掉那个值，两种都是 `wine prototypef.exe`。 */
    [self syncWindowMode];

    NSMutableArray<NSString *> *args = [NSMutableArray array];
    self.usedDesktop = NO;
    [args addObject:exe];

    self.status.stringValue = @"正在启动游戏…";
    [self launcherLog:@"第 %d 次尝试启动（%@，%lu 核）", self.attempt + 1,
        self.resPop.titleOfSelectedItem,
        (unsigned long)[self coreCountFromIndex:self.coresPop.indexOfSelectedItem]];

    /* 把实际执行的命令行和几个决定性环境变量落到日志里。
       没有这一行，出问题时只能猜"启动器到底传了什么"（踩过：命令行看着一样，环境里
       多一个变量就足以让 wine 在加载游戏之前退出，日志里只留 171 行 explorer 初始化）。 */
    NSDictionary *envForLog = [self environment];
    [self launcherLog:@"  命令：%@ %@", self.wineBinary, [args componentsJoinedByString:@" "]];
    [self launcherLog:@"  环境：DEBUG=%@ TOPO=%@ OVERRIDE=%@ LANG=%@ TMPDIR=%@ DXVK_CONF=%@",
        envForLog[@"WINEDEBUG"], envForLog[@"WINE_CPU_TOPOLOGY"] ?: @"(未设)",
        envForLog[@"WINEDLLOVERRIDES"], envForLog[@"LANG"] ?: @"(空)",
        envForLog[@"TMPDIR"] ?: @"(空)", envForLog[@"DXVK_CONFIG_FILE"] ?: @"(空)"];

    NSTask *t = [NSTask new];
    t.launchPath = self.wineBinary;
    t.arguments = args;
    t.currentDirectoryURL = [NSURL fileURLWithPath:gameDir];
    t.environment = [self environment];

    /* 日志用追加方式写，每次启动前面加一行分隔。
       以前是每次 truncate，结果一崩溃，上一次（可能成功）的记录就被覆盖了，排查时什么也留不下。 */
    NSString *log = self.logPath;
    if (![[NSFileManager defaultManager] fileExistsAtPath:log])
        [[NSFileManager defaultManager] createFileAtPath:log contents:nil attributes:nil];
    /* 超过 3 MB 就滚动一次，免得日志无限长。 */
    NSDictionary *a0 = [[NSFileManager defaultManager] attributesOfItemAtPath:log error:NULL];
    if (a0 && [a0[NSFileSize] unsignedLongLongValue] > 3ULL * 1024 * 1024) {
        NSString *old = [log stringByAppendingString:@".old"];
        [[NSFileManager defaultManager] removeItemAtPath:old error:NULL];
        [[NSFileManager defaultManager] moveItemAtPath:log toPath:old error:NULL];
        [[NSFileManager defaultManager] createFileAtPath:log contents:nil attributes:nil];
    }

    NSFileHandle *logFH = [NSFileHandle fileHandleForWritingAtPath:log];
    [logFH seekToEndOfFile];
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *head = [NSString stringWithFormat:@"\n===== 第 %d 次启动  %@ =====\n",
                      self.attempt + 1, [df stringFromDate:[NSDate date]]];
    NSData *headData = [head dataUsingEncoding:NSUTF8StringEncoding];
    /* 记住这行分隔符的字节内容。看门狗靠它在日志里定位"本次启动"的起点，
       比记文件偏移量可靠——偏移量一旦算错，就会去扫上一次的崩溃信息然后误判。 */
    self.runMarker = headData;
    [logFH writeData:headData];
    self.logStart = [logFH offsetInFile];
    self.lastSize = self.logStart;
    self.lastGrow = [NSDate date];
    self.launchTime = self.lastGrow;

    t.standardOutput = logFH;
    t.standardError = logFH;
    /* stdin 必须顺手接到 /dev/null。不接的话子进程会继承启动器的 stdin，而从 Finder 双击启动的
       应用根本没有可用的 stdin（fd 0 是无效的），wine 的控制台初始化会在读它的时候停住——
       表现就是游戏窗口出来了但一直是黑的、只 present 过一帧，跟"卡死"一模一样。 */
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];

    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            /* 旧会话（已经被 wineserver -k 清掉的那次）的退出通知，直接丢掉。 */
            if (task != self.task) return;
            if (self.retrying) return;      /* 自动重试时不要把状态改回"已退出" */
            /* 看门狗已经判过这次死了（它会自己重试）。这里再走一遍会二次累加尝试次数，
               5 次预算就变成 2 次半——实测踩过：第 3 次失败后直接跳到了第 5 次。 */
            if (self.watchdogFired) return;
            /* 45 秒内就退出＝没启动起来（有一种崩溃是直接退出，日志里只留一句 trace/break）。
               这种情况也自动重来，别把"再点一次"的活儿丢给用户。 */
            if (-[self.launchTime timeIntervalSinceNow] < 45 && self.attempt < 4 && self.running) {
                self.attempt++;
                self.retrying = YES;
                self.forceVerbose = (self.attempt % 2 == 1);
                [self launcherLog:@"启动后 %.1f 秒就退出（代码 %d，信号 %d）→ 自动重试 %d",
                    -[self.launchTime timeIntervalSinceNow], task.terminationStatus,
                    task.terminationReason == NSTaskTerminationReasonUncaughtSignal ? 1 : 0,
                    self.attempt + 1];
                self.status.stringValue = [NSString stringWithFormat:
                    @"游戏刚启动就退出了（代码 %d），正在自动重试（第 %d 次）…",
                    task.terminationStatus, self.attempt + 1];
                [self relaunchWhenClean];
                return;
            }
            [self.watch invalidate]; self.watch = nil;
            self.running = NO;
            self.playBtn.enabled = YES;
            [self launcherLog:@"游戏进程退出（代码 %d）", task.terminationStatus];
            self.status.stringValue = [NSString stringWithFormat:@"游戏已退出（代码 %d）。", task.terminationStatus];
            /* 收个尾：游戏进程没了，但 winedevice / services 这类服务进程有时会赖着，
               它们占着 prefix，就是下一次"双击没反应"的根。放到后台清，不挡界面。 */
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [self killAndWait];
            });
        });
    };

    @try {
        [t launch];
    } @catch (NSException *e) {
        self.launching = NO;
        self.running = NO;
        self.playBtn.enabled = YES;
        self.status.stringValue = [NSString stringWithFormat:@"启动失败：%@", e.reason];
        return;
    }
    self.task = t;
    self.launching = NO;

    if (self.highPrioCheck.state == NSControlStateValueOn) {
        /* 把 Wine 整个进程组提到 user-interactive QoS，减少被后台任务抢占导致的掉帧。 */
        NSTask *prio = [NSTask new];
        prio.launchPath = @"/usr/bin/taskpolicy";
        prio.arguments = @[@"-c", @"user-interactive", @"-p", @(t.processIdentifier).stringValue];
        prio.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        prio.standardError = prio.standardOutput;
        @try { [prio launch]; } @catch (NSException *e) { (void)e; }
    }

    /* 启动阶段是概率性崩溃的，大约一半的启动会卡在一个 800x450 的空窗口里，既不退出也不出画面。
       三种表现其实是同一个底层故障（异常派发失败）：
         wine: Unhandled page fault on read access to 00002DC1 at address 7BF21239 (thread 010c)
         err:virtual:virtual_setup_exception nested exception on signal stack ...
         err:seh:NtRaiseException Exception frame is not in stack limits => unable to dispatch exception
       已经跑起来的局不受影响，所以这里挂一个看门狗：每 1.5 秒扫一眼新增日志，命中就清掉会话重来。 */
    self.retrying = NO;
    self.watchdogFired = NO;
    self.cpuMark = WineCpuSeconds();
    self.cpuMarkAt = 0;
    /* 窗口化模式下把窗口摆到屏幕正中（虚拟桌面窗口默认贴左上角）。 */
    [self startCentering];

    [self startWatch];
}

/* 判定"这次启动失败了"的特征串。三种崩溃形态都要覆盖，缺一个就会漏掉一整类卡死。 */
static NSArray<NSString *> *CrashSignatures(void) {
    return @[@"page fault",
             @"starting debugger",
             @"nested exception",
             @"not in stack limits",
             @"invalid frame",
             @"Unhandled exception"];
}

- (void)startWatch {
    [self.watch invalidate];
    self.watch = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *tm) {
        if (getenv("PROTOTYPE_DEBUG")) fprintf(stderr, "[watch] tick\n");
        [self checkForStartupCrash];
    }];
}

- (void)checkForStartupCrash {
    if (!self.running) { [self.watch invalidate]; self.watch = nil; return; }

    NSTimeInterval elapsed = -[self.launchTime timeIntervalSinceNow];

    /* 90 秒还没出事，就认为这次真的跑起来了，撤掉看门狗（否则玩到一半正常崩溃也会被自动重启）。 */
    if (elapsed > 90) { [self.watch invalidate]; self.watch = nil; return; }

    NSData *all = [NSData dataWithContentsOfFile:self.logPath];
    NSString *reason = nil;

    /* 虚拟桌面（explorer /desktop=）的兜底：explorer 起来了不代表游戏起来了。
       实测从 Finder / open -a 启动时，explorer 会一直在自己的事件循环里空转，
       游戏进程永远不出现（日志只剩 171 行 explorer 初始化，20 秒烧 0.03 CPU 秒），
       而同一个命令从终端启动就正常。与其让用户干等 5 次重试都失败，
       这里 8 秒没见到游戏进程就直接改成独占全屏（不带 explorer）重来一次。 */
    if (self.usedDesktop && !self.forceDirect && elapsed >= 20 && !GameProcessRunning()) {
        reason = @"虚拟桌面没能拉起游戏进程";
    }

    /* 在日志里找到本次启动的分隔行，只扫它之后的内容。
       找不到分隔行就当作"本次还没有任何日志"，宁可让超时兜底，也不要去扫上一次的记录误判。 */
    NSUInteger start = all.length;
    if (self.runMarker.length && all.length >= self.runMarker.length) {
        NSRange mr = [all rangeOfData:self.runMarker options:0
                                range:NSMakeRange(0, all.length)];
        if (mr.location != NSNotFound) start = mr.location + mr.length;
    }

    if (all.length > start) {
        if (all.length != self.lastSize) {
            self.lastSize = all.length;
            self.lastGrow = [NSDate date];
        }
        NSData *tail = [all subdataWithRange:NSMakeRange(start, all.length - start)];
        NSString *s = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
        for (NSString *sig in CrashSignatures()) {
            if ([s containsString:sig]) { reason = sig; break; }
        }
    }

    /* 这里曾经有一条"45 秒还没画面、日志也不动了就判定卡死"的兜底，已经删掉：
       游戏跑起来之后日志本来就不再输出，这条规则会把正在正常游玩的局当成卡死杀掉重启
       （实测确实发生过，玩到一半突然重开）。

       现在的替代判据是 CPU：不猜画面，只看这个会话这 20 秒里到底有没有在烧 CPU。
       正常的启动/读盘/编译着色器一路都在烧；卡死时主线程在等一个永远不来的事件，
       整个会话 20 秒吃掉不到 0.3 CPU 秒。这条路只会误伤"开着一动不动"的局，
       而那种局本来也救不回来。 */
    if (!reason) {
        double now = WineCpuSeconds();
        if (self.cpuMarkAt == 0) {
            self.cpuMark = now;
            self.cpuMarkAt = elapsed;
        } else if (elapsed - self.cpuMarkAt >= 20) {
            double used = now - self.cpuMark;
            double span = elapsed - self.cpuMarkAt;
            self.cpuMark = now;
            self.cpuMarkAt = elapsed;
            [self launcherLog:@"CPU 判据：%.1f 秒内用掉 %.2f CPU 秒", span, used];
            if (used < 0.2) {
                if (getenv("PROTOTYPE_DEBUG"))
                    fprintf(stderr, "[watch] 静默卡死：20 秒只用掉 %.2f CPU 秒\n", used);
                reason = @"启动静默卡死（20 秒内几乎没烧 CPU）";
            }
        }
    }

    if (!reason) return;

    [self.watch invalidate];
    self.watch = nil;
    self.watchdogFired = YES;

    if (self.attempt >= 4) {
        self.running = NO;
        self.playBtn.enabled = YES;
        [self launcherLog:@"放弃：连续 5 次都没起来（最后一次：%@）", reason];
        self.status.stringValue = [NSString stringWithFormat:
            @"连续 5 次都没能正常启动（最后一次：%@）。\n"
            @"可以点「重置 Wine 环境」再试，或把日志级别改成「详细」后手动启动一次。", reason];
        return;
    }

    self.attempt++;
    self.retrying = YES;
    [self launcherLog:@"判定启动失败：%@（准备第 %d 次重试）", reason, self.attempt + 1];
    if ([reason isEqualToString:@"虚拟桌面没能拉起游戏进程"]) {
        /* 这台机器上虚拟桌面这条路在 Finder 启动时走不通，记下来，之后直接绕开。 */
        self.forceDirect = YES;
        [self saveSettings];
        [self launcherLog:@"改成直连启动（不起 explorer），后续都按这个来"];
    }
    /* 每次重试换一次日志详细程度，等于把启动时序错开，避免每次都撞在同一处。 */
    self.forceVerbose = (self.attempt % 2 == 1);
    self.status.stringValue = [NSString stringWithFormat:
        @"启动失败（%@），正在自动重试（第 %d 次）…", reason, self.attempt + 1];

    /* 崩溃后 winedbg 会挂在那个空窗口上，先把整个 wine 会话清掉再重来。 */
    [self relaunchWhenClean];
}

/* 清掉旧会话，等它真的退干净（最多约 13 秒）再重启。
   这里刻意不依赖 wineserver -k 的退出回调：实测它有时会卡住不返回（崩溃现场的 winedbg
   不肯退出），回调不触发就永远不重试——表现就是"卡在黑窗口里再也不动"。改成自己轮询，
   5 秒还不干净就直接 SIGKILL。 */
- (void)relaunchWhenClean {
    if (self.retryPending) return;
    self.retryPending = YES;

    NSTask *kill = [NSTask new];
    kill.launchPath = [[self.wineBinary stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"wineserver"];
    kill.arguments = @[@"-k"];
    kill.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    kill.standardError = kill.standardOutput;
    @try { [kill launch]; } @catch (NSException *e) { (void)e; }

    __block NSInteger tries = 0;
    NSTimer *poll = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:YES block:^(NSTimer *tm) {
        tries++;
        if (tries == 8) ForceKillWine();          /* 约 5 秒还没退干净：强杀 */
        if (WineSessionBusy() && tries <= 22) return;
        [tm invalidate];
        self.retrying = NO;
        self.retryPending = NO;
        [self launchGame];
    }];
    (void)poll;
}

/* 窗口化 / 全屏靠 Wine 自己的「虚拟桌面」注册表开关切换，不用 `wine explorer /desktop=`。

   为什么换掉 explorer 命令行：从 LaunchServices（双击 / open -a）启动时，explorer 能起来，
   但游戏进程永远不出现——日志只剩一百多行 explorer 初始化，20 秒只烧 0.03 CPU 秒，
   看门狗只能判死重试，重试也永远不成功（同一份命令从终端跑就正常）。
   换成注册表之后，启动命令和「直连」完全一样（wine prototypef.exe），由 wine 自己按
   HKCU\Software\Wine\Explorer 的配置建虚拟桌面窗口——实测双击路径也能正常出画面。

   窗口化时窗口默认贴在屏幕左上角（0,25），居中交给 startCentering（辅助功能 API）。 */
- (void)syncWindowMode {
    BOOL windowed = (self.modePop.indexOfSelectedItem == 0);
    NSString *res = self.resPop.titleOfSelectedItem;

    NSArray<NSArray<NSString *> *> *cmds;
    if (windowed) {
        cmds = @[@[@"reg", @"add", @"HKCU\\Software\\Wine\\Explorer", @"/v", @"Desktop",
                   @"/t", @"REG_SZ", @"/d", @"Prototype", @"/f"],
                 @[@"reg", @"add", @"HKCU\\Software\\Wine\\Explorer\\Desktops", @"/v", @"Prototype",
                   @"/t", @"REG_SZ", @"/d", res, @"/f"]];
    } else {
        cmds = @[@[@"reg", @"delete", @"HKCU\\Software\\Wine\\Explorer", @"/v", @"Desktop", @"/f"]];
    }

    for (NSArray<NSString *> *c in cmds) {
        NSTask *t = [NSTask new];
        t.launchPath = self.wineBinary;
        t.arguments = c;
        t.environment = [self environment];
        t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        t.standardError = t.standardOutput;
        @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { (void)e; }
    }
    [self launcherLog:@"显示模式：%@（%@）", windowed ? @"窗口" : @"独占全屏",
        windowed ? res : @"跟随游戏内设置"];
}

/* MoltenVK 有没有被禁掉（把 libMoltenVK.dylib 改名成 .disabled）。
   为什么要禁：wined3d 初始化时会顺手建一个 Vulkan 实例，即使 WINEDLLOVERRIDES 里写了
   winevulkan=d 也挡不住——那段探测是 unix 侧直接 dlopen MoltenVK 的，绕过了 DLL 覆盖。
   而这个 MoltenVK 初始化在 Rosetta 下会概率性把进程带崩，表现是启动几秒后
   `err:seh:send_debug_event Exception c0000005 in system thread` 然后退出。
   实测：开着 4 次启动里挂 1~2 次；禁掉之后连续 4 次全成功（每次都能出帧）。
   D3D9 走的是 OpenGL，本来就用不到 Vulkan，所以禁掉没有任何副作用。 */
- (BOOL)moltenVKDisabled {
    NSString *p = BundlePath(@"Contents/Resources/Wine/lib/libMoltenVK.dylib");
    return ![[NSFileManager defaultManager] fileExistsAtPath:p];
}

/* 把游戏窗口摆到屏幕正中。
   窗口化模式下 Wine 的虚拟桌面窗口默认贴在屏幕左上角（0,25），看着很别扭。
   这个窗口不属于启动器进程，只能用 macOS 的辅助功能 API 改它的位置，
   所以启动器需要「辅助功能」授权——允许一次就够，因为签名要求已经固定成 identifier
   （见 build_prototype.py 里的 --requirements），重建启动器不会再让它失效。 */
- (BOOL)centerGameWindowOnce {
    NSMutableArray<NSNumber *> *winePids = [NSMutableArray array];
    CollectWinePids(winePids);
    if (winePids.count == 0) return NO;

    CGRect screen = CGDisplayBounds(CGMainDisplayID());
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return NO;

    BOOL moved = NO;
    for (CFIndex i = 0; i < CFArrayGetCount(list) && !moved; i++) {
        CFDictionaryRef d = CFArrayGetValueAtIndex(list, i);
        int pid = 0;
        CFNumberRef pr = CFDictionaryGetValue(d, kCGWindowOwnerPID);
        if (pr) CFNumberGetValue(pr, kCFNumberIntType, &pid);

        BOOL ours = NO;
        for (NSNumber *n in winePids) if (n.intValue == pid) { ours = YES; break; }
        if (!ours) continue;

        CGRect r = CGRectZero;
        CFDictionaryRef br = CFDictionaryGetValue(d, kCGWindowBounds);
        if (!br) continue;
        CGRectMakeWithDictionaryRepresentation(br, &r);
        if (r.size.width < 320 || r.size.height < 240) continue;   /* 跳过输入法候选框之类 */

        CGFloat x = screen.origin.x + (screen.size.width  - r.size.width)  / 2.0;
        CGFloat y = screen.origin.y + (screen.size.height - r.size.height) / 2.0;
        if (fabs(r.origin.x - x) < 2 && fabs(r.origin.y - y) < 2) { moved = YES; break; }

        AXUIElementRef app = AXUIElementCreateApplication(pid);
        CFArrayRef wins = NULL;
        if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
            for (CFIndex j = 0; j < CFArrayGetCount(wins); j++) {
                AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, j);
                CGPoint p = CGPointMake(x, y);
                AXValueRef pv = AXValueCreate(kAXValueCGPointType, &p);
                if (AXUIElementSetAttributeValue(w, kAXPositionAttribute, pv) == kAXErrorSuccess) moved = YES;
                CFRelease(pv);
                if (moved) break;
            }
            CFRelease(wins);
        }
        CFRelease(app);
    }
    CFRelease(list);
    return moved;
}

/* 启动后盯 30 秒：窗口一出现就居中，顺便兜住游戏自己改窗口尺寸的情况。
   没有辅助功能权限就只记一行日志，不影响玩。 */
- (void)startCentering {
    [self.centerTimer invalidate];
    self.centerTimer = nil;
    self.centerTries = 0;
    self.centerLogged = NO;

    if (!AXIsProcessTrusted()) {
        /* 主动弹一次系统授权框（只会弹一次，之后靠用户去系统设置里勾）。
           授权之后必须退出启动器重开——TCC 的判定会被运行中的实例缓存住。 */
        NSDictionary *opt = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opt);
        [self launcherLog:@"窗口居中：还没有辅助功能权限，已弹出授权请求。"
                          @"允许后请退出启动器（Cmd+Q）重开一次，窗口才会自动居中。"];
        return;
    }

    self.centerTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        self.centerTries++;
        if ([self centerGameWindowOnce] && !self.centerLogged) {
            self.centerLogged = YES;
            [self launcherLog:@"窗口已居中"];
        }
        if (self.centerTries >= 30) { [tm invalidate]; self.centerTimer = nil; }
    }];
}

/* 「结束游戏」：不跟界面状态讲道理，直接把整个 wine 会话杀掉。
   游戏卡死时窗口往往连关闭按钮都不响应，这是唯一能从外面收场的手段。 */
- (void)stopGame:(id)sender {
    [self.watch invalidate]; self.watch = nil;
    self.retrying = NO;
    self.retryPending = NO;
    self.running = NO;
    self.task = nil;                 /* 清掉引用，之后旧进程的退出通知会被忽略，不会再触发重试 */

    NSTask *kill = [NSTask new];
    kill.launchPath = [[self.wineBinary stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"wineserver"];
    kill.arguments = @[@"-k"];
    kill.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    kill.standardError = kill.standardOutput;
    @try { [kill launch]; } @catch (NSException *e) { (void)e; }
    ForceKillWine();

    [self launcherLog:@"手动结束游戏"];
    self.playBtn.enabled = YES;
    self.status.stringValue = @"已结束游戏进程。";
}

- (void)openSaves:(id)sender {
    /* 存档在 Wine 的“我的文档”里，也就是 ~/Documents/Prototype。 */
    NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Prototype"];
    MakeDir(p);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:p]];
}

- (void)openLog:(id)sender {
    MakeDir([DataDir() stringByAppendingPathComponent:@"logs"]);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:self.logPath]];
}

/* 存档是这个 App 里唯一不可再生的东西（16 KB 一个槽，拷一份几乎不花钱）。
   重建环境、重置 prefix、换机器之前都该点一下。 */
- (void)backupSaves:(id)sender {
    NSString *src = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Prototype"];
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:src error:NULL];
    if (items.count == 0) {
        self.status.stringValue = @"存档目录是空的，没什么可备份。";
        return;
    }
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *dst = [DataDir() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"saves-backup/%@", [df stringFromDate:[NSDate date]]]];
    MakeDir(dst);

    int n = 0;
    for (NSString *it in items) {
        if (![it.pathExtension isEqualToString:@"bin"]) continue;   /* profile.bin + slot-*.bin */
        if ([[NSFileManager defaultManager] copyItemAtPath:[src stringByAppendingPathComponent:it]
                                                    toPath:[dst stringByAppendingPathComponent:it]
                                                     error:NULL]) n++;
    }
    self.status.stringValue = [NSString stringWithFormat:@"已备份 %d 个存档文件到 %@", n, dst];
    [self launcherLog:@"备份存档 %d 个 → %@", n, dst];
}

- (void)resetPrefix:(id)sender {
    NSAlert *a = [NSAlert new];
    a.messageText = @"重置 Wine 环境？";
    a.informativeText = @"会删除 ~/Library/Application Support/MacNativeGames/PROTOTYPE/prefix。\n"
                        @"存档在 ~/Documents/Prototype，不受影响。下次启动会重新初始化（约 1 分钟）。";
    [a addButtonWithTitle:@"取消"];
    [a addButtonWithTitle:@"重置"];
    if ([a runModal] != NSAlertSecondButtonReturn) return;

    /* 先收尸再删目录：会话还活着的时候删 prefix，wineserver 会边删边写，
       留下一堆半截文件，下次 wineboot 反而更慢更容易失败。 */
    [self killAndWait];
    self.running = NO;
    self.task = nil;
    self.playBtn.enabled = YES;

    [[NSFileManager defaultManager] removeItemAtPath:self.prefixPath error:NULL];
    [self launcherLog:@"重置 Wine 环境"];
    /* 顺手把"强制直连"也清掉：重置环境是用户明确要求回到初始状态的动作，
       清掉之后下一局会重新试一次虚拟桌面（万一换了系统版本就好了）。 */
    if (self.forceDirect) {
        self.forceDirect = NO;
        [self saveSettings];
        [self launcherLog:@"已清掉强制直连，下次重新尝试虚拟桌面"];
    }
    self.status.stringValue = @"Wine 环境已重置，下次启动会重新初始化。";
}

/* 游戏还在跑的时候关窗口 = 留下一个没人管的 Wine 会话，而启动器是唯一的收场工具。
   所以退出前必须问一句。 */
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (!self.running) return NSTerminateNow;

    NSAlert *a = [NSAlert new];
    a.messageText = @"游戏还在运行";
    a.informativeText = @"直接退出会在后台留下 Wine 进程，下次启动会被它挡住（表现是双击没反应）。";
    [a addButtonWithTitle:@"取消"];
    [a addButtonWithTitle:@"结束游戏并退出"];
    if ([a runModal] != NSAlertSecondButtonReturn) return NSTerminateCancel;

    [self stopGame:nil];
    return NSTerminateNow;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    /* 单实例保护：两个启动器会抢同一个 Wine prefix，两个都跑不起来（而且都占着同一份日志）。
       另外 LaunchServices 常把"已经在跑"的实例当成要激活——表现就是双击没反应。
       这里直接把新实例退掉，并把已有那个提到前台。 */
    pid_t me = [NSProcessInfo processInfo].processIdentifier;
    for (NSRunningApplication *a in
         [NSRunningApplication runningApplicationsWithBundleIdentifier:@"org.macnativegames.prototype"]) {
        if (a.processIdentifier != me) {
            [a activateWithOptions:NSApplicationActivateIgnoringOtherApps];
            [NSApp terminate:nil];
            return;
        }
    }

    [self loadSettings];
    [self buildUI];

    /* 带 --play 启动时直接进游戏，方便做自动化验证，也方便在终端里一条命令开玩：
       open -a Prototype.app --args --play

       但实测 macOS 15 上 `open --args` 并不总能把参数送到进程里（面板出来了、就是不开始，
       因为 arguments 里根本没有 --play）。所以另开一条不依赖 argv 的路：
       存在 ~/Library/Application Support/MacNativeGames/PROTOTYPE/autoplay 这个文件就自动开一局，
       然后把它删掉。脚本里用 `touch autoplay && open -a Prototype.app` 就一定能进游戏。 */
    BOOL autoPlay = [[NSProcessInfo processInfo].arguments containsObject:@"--play"];
    NSString *flag = [DataDir() stringByAppendingPathComponent:@"autoplay"];
    if (!autoPlay && [[NSFileManager defaultManager] fileExistsAtPath:flag]) {
        [[NSFileManager defaultManager] removeItemAtPath:flag error:NULL];
        autoPlay = YES;
    }
    if (autoPlay)
        /* 2.5 秒而不是 0.4 秒：从 Finder / open -a 启动时，进程刚起来那会儿窗口服务还没就绪，
           这时候放 wine 起来，explorer 能起但永远拉不起游戏（日志里只剩 171 行 explorer 初始化，
           CPU 判据 0.03 秒，看门狗怎么重试都好不了）。等几百毫秒之后就好了。 */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [NSApp activateIgnoringOtherApps:YES];
            [self play:nil];
        });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)s { return YES; }

@end

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        Launcher *d = [Launcher new];
        NSApp.delegate = d;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp run];
        (void)d;
    }
    return 0;
}
