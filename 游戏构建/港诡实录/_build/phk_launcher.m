// ============================================================================
// 港诡实录 Paranormal HK —— 启动设置面板（AppKit，无 nib）
//
// 这就是 app 的新主可执行文件（Contents/MacOS/Kegworks）。
// 原厂的 Kegworks 3.1.8 启动器在 macOS 15 上必然失败：
//     ERROR: The operation couldn't be completed. (KegworksSdk.FileUtilsError error 1.)
// 现象是双击后窗口闪一下就没了、日志一个字不写。这个程序替掉它，只干四件事：
//     1) 按面板选项写 UE4 的两个 ini（画质档 / 分辨率 / 帧率上限 / 内存压力档）
//     2) 清掉上一局没退干净的 wine 进程
//     3) 按 D3DMetal 需要的那套环境变量起 wine，用虚拟桌面包住游戏
//     4) 90 秒内没看到游戏窗口就自己重来一次（本机实测启动有概率性失败）
//
// 设置存 ~/Library/Application Support/MacNativeGames/PARANORMAL/settings.json
// 日志   ~/Library/Application Support/MacNativeGames/PARANORMAL/logs/launcher.log
// 带 --play 参数或存在 autoplay 标记文件时跳过面板直接启动。
//
// 编译：clang -fobjc-arc -O2 -framework AppKit -o /tmp/Kegworks phk_launcher.m
// ============================================================================
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

// ---------------------------------------------------------------- 路径

static char g_app[PATH_MAX];      // .../Paranormal HK.app
static char g_sup[PATH_MAX];      // .../Contents/SharedSupport
static char g_wine[PATH_MAX];     // .../wine/bin/wine
static char g_wineserver[PATH_MAX];
static char g_game[PATH_MAX];     // .../A018/PuzzleGame/Binaries/Win64
static char g_exe[PATH_MAX];      // .../PuzzleGame-Win64-Shipping.exe
static char g_d3dm[PATH_MAX];     // .../Frameworks/renderer/d3dmetal
static char g_cfg[PATH_MAX];      // .../Saved/Config/WindowsNoEditor

static void dir_of(char *p) {
    char *s = strrchr(p, '/');
    if (s && s != p) *s = '\0';
}

static NSString *S(const char *p) { return [NSString stringWithUTF8String:p]; }

static void MakeDir(NSString *d) {
    [[NSFileManager defaultManager] createDirectoryAtPath:d
        withIntermediateDirectories:YES attributes:nil error:NULL];
}

static NSString *DataDir(void) {
    NSString *base = [@"~/Library/Application Support/MacNativeGames/PARANORMAL"
        stringByExpandingTildeInPath];
    MakeDir(base);
    return base;
}

static void resolve_paths(void) {
    char exe[PATH_MAX], resolved[PATH_MAX];
    uint32_t sz = sizeof exe;
    if (_NSGetExecutablePath(exe, &sz) != 0) exit(1);
    if (!realpath(exe, resolved)) exit(1);
    strlcpy(g_app, resolved, sizeof g_app);
    dir_of(g_app);                            // .../Contents/MacOS
    dir_of(g_app);                            // .../Contents
    dir_of(g_app);                            // .../xxx.app
    snprintf(g_sup, sizeof g_sup, "%s/Contents/SharedSupport", g_app);
    snprintf(g_wine, sizeof g_wine, "%s/wine/bin/wine", g_sup);
    snprintf(g_wineserver, sizeof g_wineserver, "%s/wine/bin/wineserver", g_sup);
    snprintf(g_d3dm, sizeof g_d3dm, "%s/Contents/Frameworks/renderer/d3dmetal", g_app);
    snprintf(g_game, sizeof g_game,
             "%s/prefix/drive_c/Program Files (x86)/A018/PuzzleGame/Binaries/Win64", g_sup);
    snprintf(g_exe, sizeof g_exe, "%s/PuzzleGame-Win64-Shipping.exe", g_game);
    /* prefix 里的用户名是打包者定的 "Kegworks"，不跟着 macOS 用户名走 */
    snprintf(g_cfg, sizeof g_cfg,
             "%s/prefix/drive_c/users/Kegworks/AppData/Local/PuzzleGame/Saved/Config/WindowsNoEditor",
             g_sup);
}

// ---------------------------------------------------------------- 日志

static void LauncherLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *dir = [DataDir() stringByAppendingPathComponent:@"logs"];
    MakeDir(dir);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
        [[NSDateFormatter new] stringFromDate:[NSDate date]].description, msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:
        [dir stringByAppendingPathComponent:@"launcher.log"]];
    if (!fh) {
        [line writeToFile:[dir stringByAppendingPathComponent:@"launcher.log"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ---------------------------------------------------------------- ini 写入
// UE 的 ini 是 CRLF + 可能带 BOM。写回时统一成 UTF-8 BOM + CRLF，
// 判断段名之前剥掉 \r，否则 [Section]\r 匹配不上会反复追加新段（踩过）。
static void IniWrite(NSString *path, NSString *section,
                     NSArray<NSArray<NSString *> *> *kv) {
    NSString *old = [NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:NULL];
    if (!old) old = @"";
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    BOOL skip = NO;
    for (NSString *raw in [old componentsSeparatedByString:@"\n"]) {
        NSString *ln = [raw stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        ln = [ln stringByReplacingOccurrencesOfString:@"\r" withString:@""];
        if ([ln hasPrefix:@"["] && [ln hasSuffix:@"]"]) {
            skip = [ln isEqualToString:section];
            if (skip) continue;
        }
        if (skip) continue;
        [out addObject:ln];
    }
    while (out.count && [out.lastObject length] == 0) [out removeLastObject];
    [out addObject:@""];
    [out addObject:section];
    for (NSArray<NSString *> *p in kv) {
        if ([p[1] isEqualToString:@""]) continue;
        [out addObject:[NSString stringWithFormat:@"%@=%@", p[0], p[1]]];
    }
    NSString *text = [[out componentsJoinedByString:@"\r\n"]
        stringByAppendingString:@"\r\n"];
    NSData *body = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *d = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
    [d appendData:body];
    [d writeToFile:path atomically:YES];
}

// ---------------------------------------------------------------- 进程/窗口探测

// 是否存在标题/属主里带 "PuzzleGame" 的窗口。比匹配进程名可靠：
// wine 下每个 Windows 进程都是同一个加载器，命令行不好区分。
static BOOL GameWindowVisible(void) {
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    BOOL found = NO;
    if (list) {
        CFIndex n = CFArrayGetCount(list);
        for (CFIndex i = 0; i < n && !found; i++) {
            CFDictionaryRef w = CFArrayGetValueAtIndex(list, i);
            CFStringRef owner = CFDictionaryGetValue(w, kCGWindowOwnerName);
            CFStringRef name  = CFDictionaryGetValue(w, kCGWindowName);
            char o[256] = {0}, t[256] = {0};
            if (owner) CFStringGetCString(owner, o, sizeof o, kCFStringEncodingUTF8);
            if (name)  CFStringGetCString(name,  t, sizeof t, kCFStringEncodingUTF8);
            if (strstr(o, "PuzzleGame") || strstr(t, "PuzzleGame")) found = YES;
        }
        CFRelease(list);
    }
    return found;
}

#pragma mark - App

@interface App : NSObject <NSApplicationDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) NSPopUpButton *qualityPop, *resPop, *fpsPop, *memPop;
@property (nonatomic) NSButton *hudCheck, *logCheck, *playBtn, *stopBtn;
@property (nonatomic) NSTextField *status;
@property (nonatomic) NSTask *task;
@property (nonatomic) NSTimer *watch;
@property (nonatomic) BOOL running;
@property (nonatomic) int attempt;
@property (nonatomic) NSTimeInterval startedAt;
@end

@implementation App

- (NSString *)settingsPath { return [DataDir() stringByAppendingPathComponent:@"settings.json"]; }

// ---------------------------------------------------------------- 面板

- (NSTextField *)label:(NSString *)t frame:(NSRect)f {
    NSTextField *l = [[NSTextField alloc] initWithFrame:f];
    l.stringValue = t; l.bezeled = NO; l.drawsBackground = NO; l.editable = NO;
    l.selectable = NO; l.font = [NSFont systemFontOfSize:12];
    [self.window.contentView addSubview:l];
    return l;
}

- (NSPopUpButton *)pop:(NSRect)f items:(NSArray<NSString *> *)items {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:f pullsDown:NO];
    [p addItemsWithTitles:items];
    [self.window.contentView addSubview:p];
    return p;
}

- (NSButton *)check:(NSRect)f title:(NSString *)t on:(BOOL)on {
    NSButton *b = [[NSButton alloc] initWithFrame:f];
    [b setButtonType:NSButtonTypeSwitch];
    b.title = t; b.font = [NSFont systemFontOfSize:12];
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    [self.window.contentView addSubview:b];
    return b;
}

- (void)buildUI {
    self.window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 430, 372)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"港诡实录 · Paranormal HK";
    [self.window center];
    NSView *v = self.window.contentView;

    NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 330, 390, 24)];
    title.stringValue = @"港诡实录 Paranormal HK · 启动设置";
    title.bezeled = NO; title.drawsBackground = NO; title.editable = NO;
    title.font = [NSFont boldSystemFontOfSize:15];
    [v addSubview:title];

    [self label:@"画面档" frame:NSMakeRect(20, 292, 80, 18)];
    self.qualityPop = [self pop:NSMakeRect(110, 288, 290, 26)
        items:@[@"流畅（阴影/后处理全关，帧率最高）",
                @"均衡（保留基础后处理）",
                @"清晰（接近原版默认）"]];

    [self label:@"分辨率" frame:NSMakeRect(20, 258, 80, 18)];
    self.resPop = [self pop:NSMakeRect(110, 254, 180, 26)
        items:@[@"1280 × 720", @"1600 × 900", @"1920 × 1080", @"1024 × 576"]];

    [self label:@"帧率上限" frame:NSMakeRect(20, 224, 80, 18)];
    self.fpsPop = [self pop:NSMakeRect(110, 220, 120, 26) items:@[@"60", @"30", @"不限制"]];

    [self label:@"内存压力" frame:NSMakeRect(20, 190, 80, 18)];
    self.memPop = [self pop:NSMakeRect(110, 186, 180, 26)
        items:@[@"省内存（默认）", @"极省（画面更糊）", @"标准"]];

    self.hudCheck = [self check:NSMakeRect(20, 158, 150, 20) title:@"显示 Metal HUD" on:NO];
    self.logCheck = [self check:NSMakeRect(180, 158, 150, 20) title:@"输出 Wine 日志" on:NO];

    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(20, 148, 390, 1)];
    line.boxType = NSBoxSeparator;
    [v addSubview:line];

    self.playBtn = [[NSButton alloc] initWithFrame:NSMakeRect(20, 106, 130, 32)];
    self.playBtn.title = @"开始游戏";
    self.playBtn.bezelStyle = NSBezelStyleRounded;
    self.playBtn.font = [NSFont systemFontOfSize:13];
    self.playBtn.target = self; self.playBtn.action = @selector(play:);
    [v addSubview:self.playBtn];

    self.stopBtn = [[NSButton alloc] initWithFrame:NSMakeRect(158, 106, 110, 32)];
    self.stopBtn.title = @"结束游戏";
    self.stopBtn.bezelStyle = NSBezelStyleRounded;
    self.stopBtn.font = [NSFont systemFontOfSize:12];
    self.stopBtn.target = self; self.stopBtn.action = @selector(stop:);
    self.stopBtn.enabled = NO;
    [v addSubview:self.stopBtn];

    NSButton *openData = [[NSButton alloc] initWithFrame:NSMakeRect(280, 110, 60, 26)];
    openData.title = @"设置";
    openData.bezelStyle = NSBezelStyleRounded;
    openData.font = [NSFont systemFontOfSize:11];
    openData.target = self; openData.action = @selector(openData:);
    [v addSubview:openData];

    NSButton *openLog = [[NSButton alloc] initWithFrame:NSMakeRect(346, 110, 64, 26)];
    openLog.title = @"日志";
    openLog.bezelStyle = NSBezelStyleRounded;
    openLog.font = [NSFont systemFontOfSize:11];
    openLog.target = self; openLog.action = @selector(openLog:);
    [v addSubview:openLog];

    self.status = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 24, 390, 66)];
    self.status.stringValue = @"点「开始游戏」。首次会弹「访问可移除宗卷」，点允许。";
    self.status.bezeled = NO; self.status.drawsBackground = NO;
    self.status.editable = NO; self.status.selectable = NO;
    self.status.font = [NSFont systemFontOfSize:11];
    self.status.textColor = [NSColor secondaryLabelColor];
    self.status.lineBreakMode = NSLineBreakByWordWrapping;
    [v addSubview:self.status];

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

// ---------------------------------------------------------------- 设置读写

- (NSInteger)idx:(NSPopUpButton *)p def:(NSInteger)d {
    return p.indexOfSelectedItem >= 0 ? p.indexOfSelectedItem : d;
}

- (void)saveSettings {
    NSDictionary *d = @{
        @"quality": @([self idx:self.qualityPop def:0]),
        @"res":     @([self idx:self.resPop def:0]),
        @"fps":     @([self idx:self.fpsPop def:0]),
        @"mem":     @([self idx:self.memPop def:0]),
        @"hud":     @(self.hudCheck.state == NSControlStateValueOn),
        @"log":     @(self.logCheck.state == NSControlStateValueOn),
    };
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:NSJSONWritingPrettyPrinted error:NULL];
    [j writeToFile:[self settingsPath] atomically:YES];
}

- (void)loadSettings {
    NSData *j = [NSData dataWithContentsOfFile:[self settingsPath]];
    if (!j) return;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:j options:0 error:NULL];
    if (![d isKindOfClass:[NSDictionary class]]) return;
    NSInteger q = [d[@"quality"] integerValue], r = [d[@"res"] integerValue];
    NSInteger f = [d[@"fps"] integerValue], m = [d[@"mem"] integerValue];
    if (q < self.qualityPop.numberOfItems) [self.qualityPop selectItemAtIndex:q];
    if (r < self.resPop.numberOfItems) [self.resPop selectItemAtIndex:r];
    if (f < self.fpsPop.numberOfItems) [self.fpsPop selectItemAtIndex:f];
    if (m < self.memPop.numberOfItems) [self.memPop selectItemAtIndex:m];
    self.hudCheck.state = [d[@"hud"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.logCheck.state = [d[@"log"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
}

// ---------------------------------------------------------------- 写配置

- (NSString *)resolution {
    switch ([self idx:self.resPop def:0]) {
        case 1: return @"1600x900";
        case 2: return @"1920x1080";
        case 3: return @"1024x576";
        default: return @"1280x720";
    }
}

- (void)applyConfig {
    NSInteger q = [self idx:self.qualityPop def:0];                 // 0 流畅 1 均衡 2 清晰
    NSInteger mem = [self idx:self.memPop def:0];                  // 0 省内存 1 极省 2 标准
    NSInteger fpsIdx = [self idx:self.fpsPop def:0];
    /* 实测这个游戏不认 Engine.ini 里的 t.MaxFPS（写了照样跑到 96 fps），
       所以 60 帧靠 VSync 锁（显示器 60Hz）；30 帧两样都上。 */
    NSString *fps = fpsIdx == 1 ? @"30" : @"0";
    NSString *vsync = fpsIdx == 2 ? @"False" : @"True";

    NSString *qStr = q == 0 ? @"0" : (q == 1 ? @"1" : @"2");
    NSString *gus = [NSString stringWithFormat:
        @"[/Script/Engine.GameUserSettings]\n"
        @"ResolutionSizeX=%@\nResolutionSizeY=%@\n"
        @"LastUserConfirmedResolutionSizeX=%@\nLastUserConfirmedResolutionSizeY=%@\n"
        @"FullscreenMode=2\nLastConfirmedFullscreenMode=2\n"
        @"bUseVSync=%@\nbUseDynamicResolution=False\n"
        @"[ScalabilityGroups]\n"
        @"sg.ResolutionQuality=100.000000\n"
        @"sg.ViewDistanceQuality=%@\nsg.AntiAliasingQuality=%@\n"
        @"sg.ShadowQuality=%@\nsg.PostProcessQuality=%@\n"
        @"sg.TextureQuality=%@\nsg.EffectsQuality=%@\nsg.FoliageQuality=%@\n"
        @"[Internationalization]\nLanguage=zh-Hant-CN\n",
        [self resolution].length ? [[self resolution] componentsSeparatedByString:@"x"][0] : @"1280",
        [[self resolution] componentsSeparatedByString:@"x"][1],
        [[self resolution] componentsSeparatedByString:@"x"][0],
        [[self resolution] componentsSeparatedByString:@"x"][1],
        vsync,
        qStr, qStr, qStr, qStr, qStr, qStr, qStr];

    NSString *path = [S(g_cfg) stringByAppendingPathComponent:@"GameUserSettings.ini"];
    NSMutableData *d = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
    [d appendData:[[gus stringByReplacingOccurrencesOfString:@"\n" withString:@"\r\n"]
        dataUsingEncoding:NSUTF8StringEncoding]];
    [d writeToFile:path atomically:YES];

    // 画面/内存相关的 r.* 走 Engine.ini 的 [SystemSettings]
    NSMutableArray *kv = [NSMutableArray array];
    void (^add)(NSString *, NSString *) = ^(NSString *k, NSString *v) {
        [kv addObject:@[k, v]];
    };
    add(@"t.MaxFPS", fps);
    add(@"r.VSync", fpsIdx == 2 ? @"0" : @"1");
    add(@"r.OneFrameThreadLag", @"0");
    if (q == 0) {
        add(@"r.ShadowQuality", @"0");
        add(@"r.Shadow.MaxCSMResolution", @"512");
        add(@"r.SSR.Quality", @"0");
        add(@"r.VolumetricFog", @"0");
        add(@"r.AmbientOcclusionLevels", @"0");
        add(@"r.DepthOfFieldQuality", @"0");
        add(@"r.MotionBlurQuality", @"0");
        add(@"r.BloomQuality", @"0");
        add(@"r.LensFlareQuality", @"0");
        add(@"r.SceneColorFringeQuality", @"0");
        add(@"r.MaxAnisotropy", @"1");
        add(@"r.Tonemapper.Sharpen", @"0");
    } else if (q == 1) {
        add(@"r.Shadow.MaxCSMResolution", @"1024");
        add(@"r.VolumetricFog", @"0");
        add(@"r.MotionBlurQuality", @"0");
        add(@"r.MaxAnisotropy", @"2");
    }

    // 内存压力档：纹理流池 + mip 偏置 + 渲染分辨率百分比
    if (mem == 0) {                       // 省内存
        add(@"r.Streaming.PoolSize", @"256");
        add(@"r.Streaming.LimitPoolSizeToVRAM", @"1");
        add(@"r.Streaming.UseFixedPoolSize", @"1");
        add(@"r.Streaming.MaxTempMemoryAllowed", @"16");
        add(@"r.MipMapLODBias", @"0");
        add(@"r.ScreenPercentage", @"100");
    } else if (mem == 1) {                // 极省
        add(@"r.Streaming.PoolSize", @"128");
        add(@"r.Streaming.LimitPoolSizeToVRAM", @"1");
        add(@"r.Streaming.UseFixedPoolSize", @"1");
        add(@"r.Streaming.MaxTempMemoryAllowed", @"8");
        add(@"r.MipMapLODBias", @"1");
        add(@"r.ScreenPercentage", @"85");
    } else {                              // 标准
        add(@"r.Streaming.PoolSize", @"1000");
        add(@"r.MipMapLODBias", @"0");
        add(@"r.ScreenPercentage", @"100");
    }

    IniWrite([S(g_cfg) stringByAppendingPathComponent:@"Engine.ini"],
             @"[SystemSettings]", kv);
    LauncherLog(@"写配置：画面档=%ld 分辨率=%@ 帧率=%@ 内存档=%ld",
                (long)q, [self resolution], fps, (long)mem);
}

// ---------------------------------------------------------------- 环境

- (NSDictionary *)environment {
    NSMutableDictionary *env = [[[NSProcessInfo processInfo] environment] mutableCopy];
    env[@"WINEPREFIX"] = [S(g_sup) stringByAppendingPathComponent:@"prefix"];
    env[@"WINEDLLPATH"] = [S(g_sup) stringByAppendingPathComponent:@"wine/lib/wine"];
    env[@"WINEDLLPATH_PREPEND"] = [S(g_d3dm) stringByAppendingPathComponent:@"wine"];
    env[@"CX_APPLEGPT_LIBD3DSHARED_PATH"] =
        [S(g_d3dm) stringByAppendingPathComponent:@"external/libd3dshared.dylib"];
    env[@"CX_APPLEGPTK_LIBD3DSHARED_PATH"] = env[@"CX_APPLEGPT_LIBD3DSHARED_PATH"];
    /* 少了 Contents/Frameworks，libinotify / libfreetype 都找不到（wineserver 起不来、
       窗口客户区塌成 0）。这是霍格沃茨那份文档里的 1 号坑，这里同样踩到。 */
    env[@"DYLD_FALLBACK_LIBRARY_PATH"] =
        [S(g_app) stringByAppendingPathComponent:@"Contents/Frameworks"];
    env[@"WINEESYNC"] = @"1";
    env[@"WINEMSYNC"] = @"1";
    env[@"WINE_CPU_TOPOLOGY"] = @"4:0,1,2,3";
    env[@"WINEDEBUG"] = (self.logCheck.state == NSControlStateValueOn) ? @"err+all" : @"-all";
    if (self.hudCheck.state == NSControlStateValueOn) env[@"MTL_HUD_ENABLED"] = @"1";
    else [env removeObjectForKey:@"MTL_HUD_ENABLED"];
    if (!env[@"LANG"] || [env[@"LANG"] length] == 0) env[@"LANG"] = @"en_US.UTF-8";
    return env;
}

// ---------------------------------------------------------------- 启动

- (void)killStale {
    NSTask *k = [NSTask new];
    k.launchPath = @"/usr/bin/pkill";
    k.arguments = @[@"-9", @"-f", @"Paranormal HK.app/Contents/SharedSupport"];
    k.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    k.standardError = k.standardOutput;
    @try { [k launch]; [k waitUntilExit]; } @catch (NSException *e) {}
    NSTask *ws = [NSTask new];
    ws.launchPath = S(g_wineserver);
    ws.arguments = @[@"-k"];
    ws.environment = [self environment];
    ws.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    ws.standardError = ws.standardOutput;
    @try { [ws launch]; } @catch (NSException *e) {}
    [NSThread sleepForTimeInterval:2.0];
}

- (void)launchOnce {
    if (![[NSFileManager defaultManager] fileExistsAtPath:S(g_exe)]) {
        self.status.stringValue = @"找不到游戏主程序，App 可能不完整。";
        return;
    }
    [self applyConfig];

    self.task = [NSTask new];
    self.task.launchPath = S(g_wine);
    self.task.currentDirectoryPath = S(g_game);
    self.task.arguments = @[ @"explorer",
        [NSString stringWithFormat:@"/desktop=PHK,%@", [self resolution]], S(g_exe) ];
    self.task.environment = [self environment];
    NSString *logPath = [DataDir() stringByAppendingPathComponent:@"logs/wine.log"];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    self.task.standardOutput = fh ?: [NSFileHandle fileHandleWithNullDevice];
    self.task.standardError = self.task.standardOutput;
    self.task.standardInput = [NSFileHandle fileHandleWithNullDevice];

    __weak App *weak = self;
    self.task.terminationHandler = ^(NSTask *t) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weak taskEnded:t]; });
    };
    @try {
        [self.task launch];
    } @catch (NSException *e) {
        self.status.stringValue = [NSString stringWithFormat:@"启动失败：%@", e.reason];
        LauncherLog(@"启动异常：%@", e.reason);
        [self finish];
        return;
    }
    self.startedAt = [NSDate timeIntervalSinceReferenceDate];
    LauncherLog(@"第 %d 次启动（%@ / %@）", self.attempt + 1, [self resolution], S(g_exe));
    self.status.stringValue = @"正在启动…（wine 初始化 + 解包，约 20~40 秒）";
}

- (void)play:(id)sender {
    if (self.running) return;
    self.running = YES;
    self.attempt = 0;
    self.playBtn.enabled = NO;
    self.stopBtn.enabled = YES;
    [self saveSettings];
    [self killStale];
    [self launchOnce];
    [self startWatch];
}

- (void)startWatch {
    [self.watch invalidate];
    self.watch = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
        if (!self.running) { [t invalidate]; return; }
        if (GameWindowVisible()) {
            self.status.stringValue = @"游戏已在运行。";
            [t invalidate]; self.watch = nil;
            return;
        }
        NSTimeInterval el = [NSDate timeIntervalSinceReferenceDate] - self.startedAt;
        if (el > 90) {
            [t invalidate]; self.watch = nil;
            if (self.attempt >= 1) {
                LauncherLog(@"两次都没等到游戏窗口，放弃");
                self.status.stringValue = @"两次都没能启动。可以点「结束游戏」清理后重试。";
                [self finish];
            } else {
                self.attempt++;
                LauncherLog(@"90 秒没出窗口，自动重来一次");
                self.status.stringValue = @"没等到画面，正在自动重来…";
                [self killStale];
                [self launchOnce];
                [self startWatch];
            }
        }
    }];
}

- (void)taskEnded:(NSTask *)t {
    if (!self.running) return;
    if (GameWindowVisible()) return;        /* 只是会话里的某个辅助进程退出，别误判 */
    LauncherLog(@"wine 退出（代码 %d）", t.terminationStatus);
    [self finish];
}

- (void)finish {
    self.running = NO;
    self.playBtn.enabled = YES;
    self.stopBtn.enabled = NO;
    [self.watch invalidate];
    self.watch = nil;
}

- (void)stop:(id)sender {
    LauncherLog(@"用户点了结束游戏");
    [self killStale];
    [self finish];
    self.status.stringValue = @"已结束游戏进程。";
}

- (void)openData:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:DataDir()]];
}

- (void)openLog:(id)sender {
    NSString *p = [DataDir() stringByAppendingPathComponent:@"logs/launcher.log"];
    MakeDir([p stringByDeletingLastPathComponent]);
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:p]];
}

// ---------------------------------------------------------------- 生命周期

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [self buildUI];
    [self loadSettings];

    NSString *auto1 = [DataDir() stringByAppendingPathComponent:@"autoplay"];
    BOOL autoPlay = [[NSProcessInfo processInfo].arguments containsObject:@"--play"]
        || [[NSFileManager defaultManager] fileExistsAtPath:auto1];
    if (autoPlay) {
        [[NSFileManager defaultManager] removeItemAtPath:auto1 error:NULL];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self play:nil]; });
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

- (void)applicationWillTerminate:(NSNotification *)n {
    if (self.running) [self killStale];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        resolve_paths();
        LauncherLog(@"启动器启动：%s", g_exe);
        App *app = [App new];
        NSApplication *ns = [NSApplication sharedApplication];
        ns.delegate = app;
        [ns setActivationPolicy:NSApplicationActivationPolicyRegular];
        [ns run];
    }
    return 0;
}
