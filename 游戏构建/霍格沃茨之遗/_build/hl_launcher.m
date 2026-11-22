// ============================================================================
// 霍格沃茨之遗 —— 启动设置面板（AppKit）
//
// 这就是 app 的主可执行文件（Contents/MacOS/Sikarugir）。
// 面板里的选项在「启动游戏」时落盘到游戏的 ini，并作为环境变量传给 Wine：
//   Engine.ini            [SystemSettings]  锁帧 / 纹理池 / 精简渲染
//   GameUserSettings.ini  分辨率 / 窗口模式 / VSync / sg.* 画质档
//   环境变量              MTL_HUD_ENABLED / WINEDEBUG / WINE_CPU_TOPOLOGY / D3DM_VENDOR_ID
//
// 设置存 ~/Library/Application Support/MacNativeGames/HOGWARTS/launcher-settings.json
// 带 --play 参数（或 HL_LAUNCHER_AUTO=1）则跳过面板，直接用已存设置启动。
//
// 编译：clang -fobjc-arc -O2 -framework AppKit -o /tmp/Sikarugir hl_launcher.m
// ============================================================================
#import <AppKit/AppKit.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

// ---------------------------------------------------------------- 路径

static char g_app[PATH_MAX], g_sup[PATH_MAX], g_wine[PATH_MAX], g_game[PATH_MAX];
static char g_cfg[PATH_MAX], g_macos[PATH_MAX];

static void dir_of(char *p) {
    char *s = strrchr(p, '/');
    if (s && s != p) *s = '\0';
}

static void resolve_paths(void) {
    char exe[PATH_MAX], resolved[PATH_MAX];
    uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz) != 0) exit(1);
    if (!realpath(exe, resolved)) exit(1);
    strlcpy(g_macos, resolved, sizeof g_macos);
    dir_of(g_macos);                       // .../Contents/MacOS
    strlcpy(g_app, g_macos, sizeof g_app);
    // 从 MacOS 往上找，直到找到 .app（多退一层防呆；不在 bundle 里跑时也不会算出垃圾路径）
    for (int i = 0; i < 4; i++) {
        snprintf(g_sup, sizeof g_sup, "%s/Contents/SharedSupport", g_app);
        if (access(g_sup, F_OK) == 0) break;
        dir_of(g_app);
    }
    snprintf(g_sup, sizeof g_sup, "%s/Contents/SharedSupport", g_app);
    snprintf(g_wine, sizeof g_wine, "%s/wine/bin/wine", g_sup);
    snprintf(g_game, sizeof g_game,
             "%s/prefix/drive_c/Hogwarts Legacy Complete/Phoenix/Binaries/Win64", g_sup);
    snprintf(g_cfg, sizeof g_cfg,
             "%s/prefix/drive_c/users/%s/AppData/Local/Phoenix/Saved/Config/WindowsNoEditor",
             g_sup, getenv("USER") ?: "wilkins-");
}

// ---------------------------------------------------------------- ini 读写

// 游戏自己保存的窗口尺寸：它每次启动都会把窗口恢复成这个值（本机实测 1405x790，
// 与启动器写什么无关）。读出它，才能用同样的尺寸建窗，避免进去后被改一次。
// 读不到（新装 / 首次运行）返回 NO。
static BOOL read_saved_window(int *x, int *y) {
    NSString *gus = [@(g_cfg) stringByAppendingPathComponent:@"GameUserSettings.ini"];
    NSString *text = [NSString stringWithContentsOfFile:gus
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!text) return NO;
    int vx = 0, vy = 0;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([t hasPrefix:@"ResolutionSizeX="]) vx = [[t substringFromIndex:16] intValue];
        else if ([t hasPrefix:@"ResolutionSizeY="]) vy = [[t substringFromIndex:16] intValue];
    }
    if (vx < 800 || vx > 8000 || vy < 600 || vy > 8000) return NO;
    *x = vx;
    *y = vy;
    return YES;
}

// 在指定 section 里设置/删除键；值为 NSNull 表示删掉该键。其余内容原样保留。
// 注意：UE 写 ini 用的是 CRLF，判断段名/键之前必须把行尾 \r 剥掉，
// 否则 `[SystemSettings]\r` 匹配不上，会每次都追加一个新段落（踩过）。
// 在字典里找键，忽略大小写（UE 保存配置时会把键名改成小写，
// 不忽略大小写就会写出 r.SetRes / r.setres 这样的重复行，
// 而引擎读的是第一条 —— 曾经因此让 r.SetRes 失效）。
static NSString *key_match(NSDictionary *d, NSString *key) {
    if (d[key]) return key;
    for (NSString *k in d)
        if ([k caseInsensitiveCompare:key] == NSOrderedSame) return k;
    return nil;
}

static NSString *ini_update(NSString *text, NSString *section,
                            NSDictionary<NSString *, id> *kv) {
    NSMutableArray<NSString *> *lines =
        [[text componentsSeparatedByString:@"\n"] mutableCopy];
    NSMutableDictionary<NSString *, id> *pending = [kv mutableCopy];
    NSInteger sectionStart = -1, sectionEnd = (NSInteger)lines.count;

    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        NSString *t = [lines[i] stringByTrimmingCharactersInSet:
                                  NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([t hasPrefix:@"["] && [t hasSuffix:@"]"]) {
            if (sectionStart >= 0) { sectionEnd = i; break; }
            if ([[t substringWithRange:NSMakeRange(1, t.length - 2)]
                    isEqualToString:section])
                sectionStart = i;
        }
    }

    BOOL crlf = [text rangeOfString:@"\r\n"].location != NSNotFound;
    NSString *eol = crlf ? @"\r" : @"";

    if (sectionStart < 0) {   // 没有这个 section：追加
        NSMutableString *add = [NSMutableString stringWithFormat:@"\n[%@]%@\n", section, eol];
        for (NSString *k in kv) {
            if (kv[k] == nil || kv[k] == [NSNull null]) continue;
            [add appendFormat:@"%@=%@%@\n", k, kv[k], eol];
        }
        return [text stringByAppendingString:add];
    }

    // 替换已有键；同一个键出现多次时只留第一处，其余删掉
    for (NSInteger i = sectionStart + 1; i < sectionEnd; i++) {
        NSString *raw = lines[i];
        NSString *t = [raw stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange eq = [t rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [t substringToIndex:eq.location];
        NSString *mk = key_match(pending, key);
        if (!mk) {
            // 同一个键的重复行：前面已经处理过了，这里删掉
            if (key_match(kv, key)) { [lines removeObjectAtIndex:i]; i--; sectionEnd--; }
            continue;
        }
        id v = pending[mk];
        if (v == [NSNull null]) {
            [lines removeObjectAtIndex:i];
            i--; sectionEnd--;
        } else {
            lines[i] = [NSString stringWithFormat:@"%@=%@%@", mk, v, eol];
            [pending removeObjectForKey:mk];
        }
    }
    // 剩下的键插到 section 末尾
    NSMutableArray<NSString *> *add = [NSMutableArray array];
    for (NSString *k in kv) {
        if (pending[k] == nil || pending[k] == [NSNull null]) continue;
        [add addObject:[NSString stringWithFormat:@"%@=%@%@", k, kv[k], eol]];
    }
    if (add.count) {
        NSInteger at = sectionEnd;
        while (at > sectionStart + 1 &&
               [[lines[at - 1] stringByTrimmingCharactersInSet:
                     NSCharacterSet.whitespaceAndNewlineCharacterSet] length] == 0)
            at--;
        [lines insertObjects:add
                   atIndexes:[NSIndexSet indexSetWithIndexesInRange:
                                  NSMakeRange(at, add.count)]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static BOOL ini_write(NSString *path, NSString *section,
                      NSDictionary<NSString *, id> *kv) {
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!text) text = @"";
    NSString *out = ini_update(text, section, kv);
    return [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---------------------------------------------------------------- 工具

static BOOL make_dir(NSString *path) {
    return [NSFileManager.defaultManager createDirectoryAtPath:path
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil];
}

static pid_t spawn_tool(NSString *path, NSArray<NSString *> *args) {
    pid_t p = fork();
    if (p != 0) return p;
    int fd = open("/dev/null", O_WRONLY);
    if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
    char **argv = calloc(args.count + 2, sizeof(char *));
    argv[0] = (char *)path.UTF8String;
    for (NSUInteger i = 0; i < args.count; i++)
        argv[i + 1] = (char *)args[i].UTF8String;
    execv(argv[0], argv);
    _exit(127);
}

// ---------------------------------------------------------------- 面板

@interface HL : NSObject <NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSPopUpButton *resPopup;
@property (nonatomic, strong) NSPopUpButton *modePopup;
@property (nonatomic, strong) NSPopUpButton *presetPopup;
@property (nonatomic, strong) NSPopUpButton *fpsPopup;
@property (nonatomic, strong) NSPopUpButton *cpuPopup;
@property (nonatomic, strong) NSPopUpButton *memPopup;
@property (nonatomic, strong) NSButton *vsyncCheck;
@property (nonatomic, strong) NSButton *leanCheck;
@property (nonatomic, strong) NSButton *hudCheck;
@property (nonatomic, strong) NSButton *logCheck;
@property (nonatomic, strong) NSButton *amdCheck;
@property (nonatomic, strong) NSButton *mouseCheck;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, copy) NSString *data;
@property (nonatomic, copy) NSString *settingsPath;
@property (nonatomic, copy) NSDictionary *saved;
@property (nonatomic) BOOL autoMode;
@end

@implementation HL

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame size:(CGFloat)size
                  bold:(BOOL)bold color:(NSColor *)color {
    NSTextField *t = [NSTextField labelWithString:text];
    t.frame = frame;
    t.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    t.textColor = color ?: NSColor.labelColor;
    return t;
}

- (NSButton *)check:(NSString *)title frame:(NSRect)frame on:(BOOL)on {
    NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil];
    b.frame = frame;
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    b.font = [NSFont systemFontOfSize:12];
    return b;
}

- (NSButton *)button:(NSString *)title frame:(NSRect)frame action:(SEL)action key:(NSString *)key {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.frame = frame;
    b.bezelStyle = NSBezelStyleRounded;
    if (key) b.keyEquivalent = key;
    return b;
}

- (NSBox *)separator:(CGFloat)y {
    NSBox *s = [NSBox new];
    s.boxType = NSBoxSeparator;
    s.frame = NSMakeRect(20, y, 620, 1);
    return s;
}

- (void)loadSettings {
    NSData *d = [NSData dataWithContentsOfFile:self.settingsPath];
    self.saved = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : @{};
    if (![self.saved isKindOfClass:NSDictionary.class]) self.saved = @{};
}

- (NSInteger)idx:(NSString *)key table:(NSArray *)table def:(NSInteger)def {
    NSUInteger i = [table indexOfObject:self.saved[key] ?: @""];
    return i == NSNotFound ? def : (NSInteger)i;
}

- (BOOL)flag:(NSString *)key def:(BOOL)def {
    id v = self.saved[key];
    return v ? [v boolValue] : def;
}

- (void)buildWindow {
    NSRect content = NSMakeRect(0, 0, 660, 700);
    self.window = [[NSWindow alloc] initWithContentRect:content
                                             styleMask:NSWindowStyleMaskTitled |
                                                       NSWindowStyleMaskClosable |
                                                       NSWindowStyleMaskMiniaturizable
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.title = @"霍格沃茨之遗 Mac — 启动设置";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    [self.window center];
    NSView *v = [[NSView alloc] initWithFrame:content];
    self.window.contentView = v;

    [v addSubview:[self label:@"霍格沃茨之遗 Mac" frame:NSMakeRect(20, 658, 620, 30)
                        size:23 bold:YES color:nil]];
    [v addSubview:[self label:@"D3DMetal + Wine · 启动前调参，避免进游戏再改"
                        frame:NSMakeRect(20, 634, 620, 20) size:12 bold:NO
                        color:NSColor.secondaryLabelColor]];

    // —— 画面 ——
    [v addSubview:[self separator:620]];
    [v addSubview:[self label:@"画面" frame:NSMakeRect(20, 592, 620, 20) size:13 bold:YES color:nil]];

    [v addSubview:[self label:@"分辨率" frame:NSMakeRect(20, 560, 60, 20) size:12 bold:NO color:nil]];
    self.resPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(84, 556, 150, 26) pullsDown:NO];
    [self.resPopup addItemsWithTitles:@[@"1280x720", @"1440x810", @"1600x900", @"1920x1080"]];
    [self.resPopup selectItemAtIndex:[self idx:@"res" table:@[@"1280x720", @"1440x810",
                                                             @"1600x900", @"1920x1080"] def:0]];
    self.resPopup.target = self; self.resPopup.action = @selector(refresh:);
    [v addSubview:self.resPopup];

    [v addSubview:[self label:@"窗口" frame:NSMakeRect(252, 560, 40, 20) size:12 bold:NO color:nil]];
    self.modePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(294, 556, 150, 26) pullsDown:NO];
    [self.modePopup addItemsWithTitles:@[@"窗口", @"无边框全屏", @"独占全屏"]];
    [self.modePopup selectItemAtIndex:[self idx:@"mode" table:@[@"window", @"borderless", @"fullscreen"] def:0]];
    self.modePopup.target = self; self.modePopup.action = @selector(refresh:);
    [v addSubview:self.modePopup];

    [v addSubview:[self label:@"画质" frame:NSMakeRect(462, 560, 40, 20) size:12 bold:NO color:nil]];
    self.presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(504, 556, 136, 26) pullsDown:NO];
    [self.presetPopup addItemsWithTitles:@[@"最低", @"中", @"高"]];
    [self.presetPopup selectItemAtIndex:[self idx:@"preset" table:@[@"minimal", @"low", @"medium"] def:0]];
    self.presetPopup.target = self;
    self.presetPopup.action = @selector(refresh:);
    [v addSubview:self.presetPopup];

    [v addSubview:[self label:@"GPU 只用到 12/16.7 ms，瓶颈在 CPU 侧，所以画质再低也不会更快；"
                        "1080p 和 720p 帧数基本一样，建议直接开 1080p。"
                        frame:NSMakeRect(20, 532, 620, 18) size:11 bold:NO
                        color:NSColor.secondaryLabelColor]];

    // —— 帧率 ——
    [v addSubview:[self separator:518]];
    [v addSubview:[self label:@"帧率" frame:NSMakeRect(20, 490, 620, 20) size:13 bold:YES color:nil]];
    [v addSubview:[self label:@"锁帧" frame:NSMakeRect(20, 458, 60, 20) size:12 bold:NO color:nil]];
    self.fpsPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(84, 454, 150, 26) pullsDown:NO];
    [self.fpsPopup addItemsWithTitles:@[@"不锁", @"30", @"40", @"45", @"50", @"60"]];
    [self.fpsPopup selectItemAtIndex:[self idx:@"fps" table:@[@"0", @"30", @"40", @"45", @"50", @"60"] def:5]];
    self.fpsPopup.target = self; self.fpsPopup.action = @selector(refresh:);
    [v addSubview:self.fpsPopup];
    self.vsyncCheck = [self check:@"VSync（60Hz 屏 + 帧数上不到 60 时会 60/30 跳变，建议关）"
                            frame:NSMakeRect(252, 456, 388, 22) on:[self flag:@"vsync" def:NO]];
    [v addSubview:self.vsyncCheck];

    // —— 内存 / 渲染 ——
    [v addSubview:[self separator:440]];
    [v addSubview:[self label:@"内存与渲染" frame:NSMakeRect(20, 412, 620, 20) size:13 bold:YES color:nil]];
    [v addSubview:[self label:@"内存模式" frame:NSMakeRect(20, 380, 70, 20) size:12 bold:NO color:nil]];
    self.memPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(94, 376, 210, 26) pullsDown:NO];
    [self.memPopup addItemsWithTitles:@[@"标准（画质优先）",
                                        @"省内存（推荐）",
                                        @"极限省内存（画面糊）"]];
    [self.memPopup selectItemAtIndex:[self idx:@"mem" table:@[@"std", @"save", @"max"] def:1]];
    self.memPopup.target = self; self.memPopup.action = @selector(refresh:);
    [v addSubview:self.memPopup];
    [v addSubview:[self label:@"压的是 Metal 显存（实测 2.5 GB）：纹理池 + 内部分辨率 + 阴影贴图"
                        frame:NSMakeRect(314, 381, 330, 18) size:11 bold:NO
                        color:NSColor.secondaryLabelColor]];

    self.leanCheck = [self check:@"精简渲染（关 SSR / 体积雾 / 景深 / 动态模糊 / 各向异性，省渲染目标内存）"
                           frame:NSMakeRect(20, 348, 620, 22) on:[self flag:@"lean" def:YES]];
    [v addSubview:self.leanCheck];

    // —— 启动选项 ——
    [v addSubview:[self separator:330]];
    [v addSubview:[self label:@"启动选项" frame:NSMakeRect(20, 302, 620, 20) size:13 bold:YES color:nil]];
    self.hudCheck = [self check:@"显示 Metal 性能 HUD（右上角看 FPS/GPU/内存）"
                          frame:NSMakeRect(20, 274, 380, 22) on:[self flag:@"hud" def:NO]];
    [v addSubview:self.hudCheck];
    self.logCheck = [self check:@"输出 Wine 日志（排查用，会掉帧）"
                          frame:NSMakeRect(20, 248, 380, 22) on:[self flag:@"log" def:NO]];
    [v addSubview:self.logCheck];
    self.amdCheck = [self check:@"屏蔽驱动警告（伪装 AMD）"
                          frame:NSMakeRect(20, 222, 250, 22) on:[self flag:@"amd" def:YES]];
    [v addSubview:self.amdCheck];
    self.mouseCheck = [self check:@"鼠标锁定（游戏内按 0 切换）"
                           frame:NSMakeRect(280, 222, 340, 22) on:[self flag:@"mouse" def:YES]];
    [v addSubview:self.mouseCheck];

    [v addSubview:[self label:@"CPU" frame:NSMakeRect(20, 194, 40, 20) size:12 bold:NO color:nil]];
    self.cpuPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(62, 190, 200, 26) pullsDown:NO];
    [self.cpuPopup addItemsWithTitles:@[@"4 个性能核（稳）", @"全部 10 核（可能崩）"]];
    [self.cpuPopup selectItemAtIndex:[self idx:@"cpu" table:@[@"4", @"10"] def:0]];
    [v addSubview:self.cpuPopup];
    [v addSubview:[self label:@"去掉核数限制实测会崩 EXCEPTION_ACCESS_VIOLATION，别乱改"
                        frame:NSMakeRect(270, 194, 370, 18) size:11 bold:NO
                        color:NSColor.secondaryLabelColor]];

    // —— 底部 ——
    [v addSubview:[self separator:172]];
    self.statusField = [self label:@"就绪" frame:NSMakeRect(20, 142, 620, 18) size:11 bold:NO
                            color:NSColor.secondaryLabelColor];
    [v addSubview:self.statusField];

    [v addSubview:[self button:@"启动游戏" frame:NSMakeRect(20, 96, 200, 34)
                        action:@selector(startGame:) key:@"\r"]];
    [v addSubview:[self button:@"恢复默认" frame:NSMakeRect(232, 96, 120, 34)
                        action:@selector(resetDefaults:) key:nil]];
    [v addSubview:[self button:@"退出" frame:NSMakeRect(364, 96, 90, 34)
                        action:@selector(quit:) key:nil]];

    [v addSubview:[self label:@"游戏盘是 USB 5Gb/s 外置固态（实测顺序读 403 MB/s）。"
                        "首次启动会弹一次「访问可移除宗卷」授权，点允许即可。"
                        frame:NSMakeRect(20, 56, 620, 32) size:11 bold:NO
                        color:NSColor.secondaryLabelColor]];

    [self updateStatus];
}

- (void)refresh:(id)sender {
    (void)sender;
    [self updateStatus];
}

- (void)updateStatus {
    NSString *res = self.resPopup.titleOfSelectedItem;
    NSString *mode = self.modePopup.titleOfSelectedItem;
    NSString *fps = [self.fpsPopup.titleOfSelectedItem isEqualToString:@"不锁"]
                        ? @"不限帧" : [NSString stringWithFormat:@"锁 %@", self.fpsPopup.titleOfSelectedItem];
    self.statusField.stringValue =
        [NSString stringWithFormat:@"当前：%@ · %@ · %@ · %@ · 画质%@",
                                   res, mode, fps, self.memPopup.titleOfSelectedItem,
                                   self.presetPopup.titleOfSelectedItem];
    // 游戏会把自己的窗口恢复成固定尺寸，建窗就按这个尺寸来（这样不会跳）。
    // 面板里选的分辨率因此不决定窗口大小，这里把它如实显示出来，免得看着困惑。
    int sx = 0, sy = 0;
    if (read_saved_window(&sx, &sy)) {
        NSString *lock = [NSString stringWithFormat:@"%dx%d", sx, sy];
        if (![lock isEqualToString:res])
            self.statusField.stringValue =
                [self.statusField.stringValue stringByAppendingFormat:
                     @" · 窗口锁定 %@（游戏自身尺寸）", lock];
    }
}

- (void)resetDefaults:(id)sender {
    (void)sender;
    [self.resPopup selectItemAtIndex:0];
    [self.modePopup selectItemAtIndex:0];
    [self.presetPopup selectItemAtIndex:0];
    [self.fpsPopup selectItemAtIndex:5];
    [self.cpuPopup selectItemAtIndex:0];
    [self.memPopup selectItemAtIndex:1];
    self.vsyncCheck.state = NSControlStateValueOff;
    self.leanCheck.state = NSControlStateValueOn;
    self.hudCheck.state = NSControlStateValueOff;
    self.logCheck.state = NSControlStateValueOff;
    self.amdCheck.state = NSControlStateValueOn;
    self.mouseCheck.state = NSControlStateValueOn;
    [self updateStatus];
    self.statusField.stringValue = @"已恢复默认";
}

- (BOOL)saveSettings {
    NSDictionary *d = @{
        @"res": self.resPopup.titleOfSelectedItem,
        @"mode": @[@"window", @"borderless", @"fullscreen"][MAX(0, self.modePopup.indexOfSelectedItem)],
        @"preset": @[@"minimal", @"low", @"medium"][MAX(0, self.presetPopup.indexOfSelectedItem)],
        @"fps": @[@"0", @"30", @"40", @"45", @"50", @"60"][MAX(0, self.fpsPopup.indexOfSelectedItem)],
        @"cpu": @[@"4", @"10"][MAX(0, self.cpuPopup.indexOfSelectedItem)],
        @"mem": @[@"std", @"save", @"max"][MAX(0, MIN(2, self.memPopup.indexOfSelectedItem))],
        @"vsync": @(self.vsyncCheck.state == NSControlStateValueOn),
        @"lean": @(self.leanCheck.state == NSControlStateValueOn),
        @"hud": @(self.hudCheck.state == NSControlStateValueOn),
        @"log": @(self.logCheck.state == NSControlStateValueOn),
        @"amd": @(self.amdCheck.state == NSControlStateValueOn),
        @"mouse": @(self.mouseCheck.state == NSControlStateValueOn),
    };
    make_dir(self.data);
    NSData *json = [NSJSONSerialization dataWithJSONObject:d
                                                  options:NSJSONWritingPrettyPrinted
                                                    error:nil];
    return json && [json writeToFile:self.settingsPath atomically:YES];
}

// 把面板选项写进游戏的 ini
- (void)applyIni {
    NSString *engine = [@(g_cfg) stringByAppendingPathComponent:@"Engine.ini"];
    NSString *gus = [@(g_cfg) stringByAppendingPathComponent:@"GameUserSettings.ini"];

    NSString *fps = @[@"0", @"30", @"40", @"45", @"50", @"60"]
                         [MAX(0, self.fpsPopup.indexOfSelectedItem)];
    // 内存模式：压 Metal 显存那一块（实测 2.5 GB，占整个 footprint 的 30%）
    NSInteger memMode = MAX(0, MIN(2, self.memPopup.indexOfSelectedItem));
    NSInteger pool = memMode == 0 ? 1024 : (memMode == 1 ? 768 : 512);
    NSInteger tempMem = memMode == 0 ? 32 : (memMode == 1 ? 24 : 16);
    NSInteger shadowRes = memMode == 0 ? 1024 : 512;
    NSInteger resQuality = memMode == 0 ? 100 : (memMode == 1 ? 85 : 70);

    NSMutableDictionary *sys = [@{
        @"t.MaxFPS": fps,
        @"r.Streaming.PoolSize": @(pool),
        @"r.Streaming.MaxTempMemoryAllowed": @(tempMem),
        @"r.Streaming.LimitPoolSizeToVRAM": @1,
        @"r.Streaming.DefragDynamicBounds": @1,
        @"r.Shadow.MaxCSMResolution": @(shadowRes),
        @"r.GPUCrashDebugging": @0,
    } mutableCopy];
    if (self.leanCheck.state == NSControlStateValueOn) {
        [sys addEntriesFromDictionary:@{
            @"r.SSR.Quality": @0,
            @"r.SSR.HalfResSceneColor": @1,
            @"r.VolumetricFog": @0,
            @"r.AmbientOcclusionLevels": @0,
            @"r.DepthOfFieldQuality": @0,
            @"r.MotionBlurQuality": @0,
            @"r.LensFlareQuality": @0,
            @"r.SceneColorFringeQuality": @0,
            @"r.MaxAnisotropy": @1,
        }];
    } else {
        for (NSString *k in @[@"r.SSR.Quality", @"r.SSR.HalfResSceneColor",
                              @"r.VolumetricFog", @"r.AmbientOcclusionLevels",
                              @"r.DepthOfFieldQuality", @"r.MotionBlurQuality",
                              @"r.LensFlareQuality", @"r.SceneColorFringeQuality",
                              @"r.MaxAnisotropy"])
            sys[k] = [NSNull null];
    }
    // 分辨率 / 窗口模式（先算出来，下面写 Engine.ini 时要用）
    NSArray *wh = [self.resPopup.titleOfSelectedItem componentsSeparatedByString:@"x"];
    NSString *resX = wh.firstObject ?: @"1280";
    NSString *resY = wh.count > 1 ? wh[1] : @"720";
    NSInteger modeIdx = MAX(0, self.modePopup.indexOfSelectedItem);
    // UE: 0=独占全屏 1=无边框全屏 2=窗口
    NSInteger fullscreen = modeIdx == 0 ? 2 : (modeIdx == 1 ? 1 : 0);

    // 窗口尺寸锁定：这个游戏的引擎会把窗口恢复成它自己上次保存的尺寸（本机实测恒为
    // 1405x790，与面板里选什么无关 —— 已用 1280/1440/1600 三种值验证），所以建窗尺寸
    // 必须取"游戏上次真正落定的尺寸"，否则一进游戏就会被改一次，看起来像窗口突然放大。
    // 取不到（新装）时退回面板选择。
    NSString *lockX = resX, *lockY = resY;
    int sx = 0, sy = 0;
    if (read_saved_window(&sx, &sy)) {
        lockX = [NSString stringWithFormat:@"%d", sx];
        lockY = [NSString stringWithFormat:@"%d", sy];
    }
    // r.SetRes 让游戏**建窗的那一刻**就是这个尺寸。w=窗口，f=全屏。
    sys[@"r.SetRes"] = [NSString stringWithFormat:@"%@x%@%@", lockX, lockY,
                        fullscreen == 2 ? @"w" : @"f"];

    ini_write(engine, @"SystemSettings", sys);

    NSDictionary *phoenix = @{
        @"ResolutionSizeX": lockX,
        @"ResolutionSizeY": lockY,
        @"LastUserConfirmedResolutionSizeX": lockX,
        @"LastUserConfirmedResolutionSizeY": lockY,
        @"DesiredScreenWidth": lockX,
        @"DesiredScreenHeight": lockY,
        @"LastUserConfirmedDesiredScreenWidth": lockX,
        @"LastUserConfirmedDesiredScreenHeight": lockY,
        @"FullscreenMode": @(fullscreen),
        @"LastConfirmedFullscreenMode": @(fullscreen),
        @"bUseVSync": self.vsyncCheck.state == NSControlStateValueOn ? @YES : @NO,
        @"bUseDynamicResolution": @NO,
    };
    ini_write(gus, @"/Script/Phoenix.PhoenixGameSettings", phoenix);

    // 画质档
    NSInteger p = MAX(0, self.presetPopup.indexOfSelectedItem);
    NSInteger lo = p == 0 ? 0 : (p == 1 ? 1 : 2);
    NSDictionary *sg = @{
        @"sg.ResolutionQuality": @(resQuality),
        @"sg.ViewDistanceQuality": @(lo),
        @"sg.AntiAliasingQuality": @(p == 0 ? 1 : lo),
        @"sg.ShadowQuality": @(lo),
        @"sg.PostProcessQuality": @(lo),
        @"sg.TextureQuality": @(lo),
        @"sg.EffectsQuality": @(lo),
        @"sg.FoliageQuality": @(lo),
        @"sg.ShadingQuality": @(lo),
        @"sg.VolumetricsQuality": @(p == 0 ? 0 : lo),
        @"sg.SkyQuality": @(lo),
        @"sg.PopulationQuality": @(lo),
        @"sg.RaytracingQuality": @0,
        @"sg.RaytracingReflectionsQuality": @0,
        @"sg.RaytracingShadowsQuality": @0,
    };
    ini_write(gus, @"ScalabilityGroups", sg);
    ini_write(gus, @"/Script/Phoenix.PhoenixGameSettings", @{@"GPUConfigPreset": @(p)});
}

- (void)startGame:(id)sender {
    (void)sender;
    if (access(g_wine, X_OK) != 0) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"找不到内嵌 Wine";
        a.informativeText = @"固态盘插好了吗？路径：/Volumes/SSD/Game/HogwartsLegacy";
        [a runModal];
        return;
    }
    if (!self.autoMode && ![self saveSettings])
        self.statusField.stringValue = @"警告：设置存不下来，本次仍按面板选项启动。";
    [self applyIni];

    // —— 环境变量 ——
    setenv("WINEPREFIX", [[@(g_sup) stringByAppendingPathComponent:@"prefix"] UTF8String], 1);
    NSString *R = [@(g_app) stringByAppendingPathComponent:@"Contents/Frameworks/renderer/d3dmetal"];
    NSString *EXT = [R stringByAppendingPathComponent:@"external"];
    setenv("CX_D3DMETALPATH", R.UTF8String, 1);
    NSString *shared = [EXT stringByAppendingPathComponent:@"libd3dshared.dylib"];
    setenv("CX_APPLEGPT_LIBD3DSHARED_PATH", shared.UTF8String, 1);
    setenv("CX_APPLEGPTK_LIBD3DSHARED_PATH", shared.UTF8String, 1);
    setenv("DYLD_FRAMEWORK_PATH",
           [NSString stringWithFormat:@"%@:%@/Contents/Frameworks", EXT, @(g_app)].UTF8String, 1);
    setenv("DYLD_FALLBACK_LIBRARY_PATH",
           [NSString stringWithFormat:@"%@:%@/Contents/Frameworks:%@/wine/lib",
                                      EXT, @(g_app), @(g_sup)].UTF8String, 1);
    setenv("WINEDLLPATH_PREPEND", [R stringByAppendingPathComponent:@"wine"].UTF8String, 1);
    setenv("D3DMETAL", "1", 1);
    setenv("D3DM_ENABLE_METALFX", "1", 1);
    setenv("WINEESYNC", "1", 1);
    setenv("WINEMSYNC", "1", 1);
    setenv("WINE_CPU_TOPOLOGY",
           self.cpuPopup.indexOfSelectedItem == 1 ? "10:0,1,2,3,4,5,6,7,8,9" : "4:0,1,2,3", 1);
    setenv("WINEDEBUG", self.logCheck.state == NSControlStateValueOn ? "err+all" : "-all", 1);
    if (self.hudCheck.state == NSControlStateValueOn) setenv("MTL_HUD_ENABLED", "1", 1);
    if (self.amdCheck.state == NSControlStateValueOn) setenv("D3DM_VENDOR_ID", "0x1002", 1);

    if (chdir(g_game) != 0) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"进不去游戏目录";
        a.informativeText = @(g_game);
        [a runModal];
        return;
    }

    NSString *home = NSHomeDirectory();
    NSString *logPath = [home stringByAppendingPathComponent:@"Library/Logs/HogwartsLegacy.log"];
    make_dir([home stringByAppendingPathComponent:@"Library/Logs"]);

    pid_t wine = fork();
    if (wine == 0) {
        int fd = open(self.logCheck.state == NSControlStateValueOn ? logPath.UTF8String
                                                                   : "/dev/null",
                      O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); close(fd); }
        char *argv[] = {g_wine, "HogwartsLegacy.exe", NULL};
        execv(g_wine, argv);
        _exit(127);
    }
    if (wine < 0) return;

    // 防 App Nap / 降频
    spawn_tool(@"/usr/bin/caffeinate",
               @[@"-dims", @"-w", [NSString stringWithFormat:@"%d", wine]]);
    // 兜底点掉对话框
    NSString *ad = [@(g_macos) stringByAppendingPathComponent:@"auto_dismiss.py"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:ad])
        spawn_tool(@"/usr/bin/python3", @[ad, [NSString stringWithFormat:@"%d", wine]]);

    // 鼠标锁定辅助进程：游戏内按 7 在「鼠标控制游戏」和「鼠标脱离」之间切换。
    // 只在游戏窗口位于最前时才注册 7 这个热键，切走焦点自动解锁，不会把鼠标锁死。
    if (self.mouseCheck.state == NSControlStateValueOn) {
        NSString *hm = [@(g_macos) stringByAppendingPathComponent:@"hl_mouse"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:hm])
            spawn_tool(hm, @[[NSString stringWithFormat:@"%d", wine]]);
    }

    self.statusField.stringValue = @"游戏启动中…（首次会先准备着色器，可能要几分钟）";
    [self.window orderOut:nil];

    // 面板已经没用了：把窗口和控件全放掉，进程只留一个 waitpid 等游戏退出。
    // 实测面板常驻 21 MB，放掉之后掉到 10 MB 左右 —— 游戏跑起来后它不该再占内存。
    self.window.contentView = nil;
    self.window = nil;
    self.resPopup = nil;
    self.modePopup = nil;
    self.presetPopup = nil;
    self.fpsPopup = nil;
    self.cpuPopup = nil;
    self.memPopup = nil;
    self.vsyncCheck = nil;
    self.leanCheck = nil;
    self.hudCheck = nil;
    self.logCheck = nil;
    self.amdCheck = nil;
    self.mouseCheck = nil;
    self.statusField = nil;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    int status = 0;
    while (waitpid(wine, &status, 0) < 0 && errno == EINTR) {}
    [NSApp terminate:nil];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

@end

// ---------------------------------------------------------------- main

int main(int argc, char **argv) {
    @autoreleasepool {
        resolve_paths();

        // 预触发「访问可移除宗卷」授权。
        // 不预触发的话，第一次是在点「启动游戏」时才弹，用户很容易错过，
        // 然后就表现为"点了没反应"。这里在开面板前先读一个字节，弹窗先出来。
        {
            FILE *f = fopen(g_wine, "rb");
            if (f) { char b; if (fread(&b, 1, 1, f) != 1) {} fclose(f); }
        }

        // 防重复启动：flock 随进程消亡自动释放。
        // O_CLOEXEC 很关键 —— 不加的话 fork 出来的子进程（auto_dismiss / caffeinate /
        // hl_mouse）会继承这个 fd，启动器退出后锁还被它们占着，
        // 下次启动就会被误判成"游戏已经在运行了"而直接退出。
        NSString *lockp = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Library/Caches/HogwartsLegacy.lock"];
        int lfd = open(lockp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_CLOEXEC, 0644);
        if (lfd >= 0 && flock(lfd, LOCK_EX | LOCK_NB) != 0) {
            spawn_tool(@"/usr/bin/osascript",
                       @[@"-e", @"display notification \"游戏已经在运行了\" with title \"霍格沃茨之遗\""]);
            return 0;
        }

        NSString *data = [NSHomeDirectory() stringByAppendingPathComponent:
                             @"Library/Application Support/MacNativeGames/HOGWARTS"];
        make_dir(data);

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        HL *l = [HL new];
        l.data = data;
        l.settingsPath = [data stringByAppendingPathComponent:@"launcher-settings.json"];
        [l loadSettings];

        BOOL autoStart = NO;
        for (int i = 1; i < argc; i++)
            if (!strcmp(argv[i], "--play")) autoStart = YES;
        if (getenv("HL_LAUNCHER_AUTO") && *getenv("HL_LAUNCHER_AUTO")) autoStart = YES;
        [l buildWindow];

        NSMenu *menu = [NSMenu new];
        NSMenuItem *item = [NSMenuItem new];
        [menu addItem:item];
        NSMenu *sub = [NSMenu new];
        [sub addItemWithTitle:@"退出" action:@selector(terminate:) keyEquivalent:@"q"];
        item.submenu = sub;
        NSApp.mainMenu = menu;

        if (autoStart) {
            l.autoMode = YES;
            [l startGame:nil];
            return 0;
        }
        [NSApp activateIgnoringOtherApps:YES];
        [l.window makeKeyAndOrderFront:nil];
        [NSApp run];
        return 0;
    }
}
