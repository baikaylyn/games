// 鬼泣4 特别版 · 启动器
// 所有设置由面板控制；点「启动游戏」= 写配置 + 启动游戏 + 拉起鼠标重映射器。
//
// 为什么是独立 app、而不是替换游戏本体的 CFBundleExecutable：
//   Kegworks 必须由 LaunchServices 启动（直接跑会 FileUtilsError error 1），
//   所以启动器只能 open -a 游戏本体，不能自己变成游戏本体。
//
// 编译：
//   clang -O2 -fobjc-arc -framework Cocoa -framework ApplicationServices \
//         -o /tmp/DMC4Launcher dmc4_launcher.m
//
// 设置存：~/Library/Application Support/MacNativeGames/DMC4/launcher-settings.json

#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>
#import <sys/wait.h>
#import <signal.h>
#include <pthread.h>

// 重映射器以「进程内线程」方式运行：同一个签名、同一份 TCC 授权，
// 不再有子进程归属问题。编译时用 -Dmain=dmc4_input_main 改名。
extern int dmc4_input_main(int argc, char **argv);

static volatile int g_remap_state = 0;   // 0=未启动 1=运行中 2=已退出 3=权限失败

static void *dmc4_remap_thread(void *arg) {
    char **argv = (char **)arg;
    int argc = 0;
    while (argv[argc]) argc++;
    int r = dmc4_input_main(argc, argv);
    g_remap_state = (r == 0) ? 2 : 3;
    return NULL;
}

// ---------------------------------------------------------------- 常量

static NSArray *kRes     = nil;
static NSArray *kQuality = nil;
static NSArray *kTexture = nil, *kTextureV = nil;
static NSArray *kEffect  = nil, *kEffectV  = nil;
static NSArray *kDL      = nil, *kDLV      = nil;
static NSArray *kHDR     = nil, *kHDRV     = nil;
static NSArray *kAA      = nil, *kAAV      = nil;
static NSArray *kChar    = nil;
static NSArray *kSens    = nil;
static NSArray *kJob     = nil;

static NSString *g_gameApp, *g_config, *g_template, *g_infoPlist, *g_userReg;
static NSString *g_remapper, *g_settings;

// ---------------------------------------------------------------- 路径

static BOOL PathExists(NSString *p) {
    return p.length && [[NSFileManager defaultManager] fileExistsAtPath:p];
}

static void ResolvePaths(void) {
    NSString *def = @"/Volumes/SSD/Game/DMC4/Devil May Cry 4.app";
    const char *env = getenv("DMC4_APP");
    g_gameApp = env ? @(env) : def;

    if (!PathExists(g_gameApp)) {
        NSString *parent = [[[NSBundle mainBundle] bundlePath] stringByDeletingLastPathComponent];
        NSString *cand = [parent stringByAppendingPathComponent:@"Devil May Cry 4.app"];
        if (PathExists(cand)) g_gameApp = cand;
    }

    g_config    = [g_gameApp stringByAppendingPathComponent:
                   @"Contents/SharedSupport/prefix/drive_c/users/Kegworks/AppData/Local/CAPCOM/DEVILMAYCRY4SPECIALEDITION/config.ini"];
    g_template  = @"/Volumes/SSD/Game/游戏构建/鬼泣4/_build/config.ini";
    g_infoPlist = [g_gameApp stringByAppendingPathComponent:@"Contents/Info.plist"];
    g_userReg   = [g_gameApp stringByAppendingPathComponent:@"Contents/SharedSupport/prefix/user.reg"];

    NSString *res = [[NSBundle mainBundle] pathForResource:@"dmc4_input_v4" ofType:nil];
    if (!res) res = @"/Volumes/SSD/Game/游戏构建/鬼泣4/_build/dmc4_input_v4";
    g_remapper = res;

    g_settings = [NSHomeDirectory() stringByAppendingPathComponent:
                  @"Library/Application Support/MacNativeGames/DMC4/launcher-settings.json"];
}

// ---------------------------------------------------------------- ini 读写
// 沿用霍格沃茨启动器的实现：兼容 LF/CRLF，同键去重，未找到 section 就追加。

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

    if (sectionStart < 0) {
        NSMutableString *add = [NSMutableString stringWithFormat:@"\n[%@]%@\n", section, eol];
        for (NSString *k in kv) {
            if (kv[k] == nil || kv[k] == [NSNull null]) continue;
            [add appendFormat:@"%@=%@%@\n", k, kv[k], eol];
        }
        return [text stringByAppendingString:add];
    }

    for (NSInteger i = sectionStart + 1; i < sectionEnd; i++) {
        NSString *raw = lines[i];
        NSString *t = [raw stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange eq = [t rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [t substringToIndex:eq.location];
        if (pending[key] == nil) {
            if (kv[key] != nil) { [lines removeObjectAtIndex:i]; i--; sectionEnd--; }
            continue;
        }
        id v = pending[key];
        if (v == [NSNull null]) {
            [lines removeObjectAtIndex:i];
            i--; sectionEnd--;
        } else {
            lines[i] = [NSString stringWithFormat:@"%@=%@%@", key, v, eol];
            [pending removeObjectForKey:key];
        }
    }
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
    if (!path) return NO;
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (!text) return NO;
    NSString *out = ini_update(text, section, kv);
    return [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---------------------------------------------------------------- 控件辅助

@interface FlippedView : NSView @end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

// ---------------------------------------------------------------- 启动器

@interface DMC4 : NSObject <NSWindowDelegate, NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSPopUpButton *resPopup, *qualityPopup, *texturePopup;
@property (nonatomic, strong) NSPopUpButton *effectPopup, *dlPopup, *hdrPopup, *aaPopup;
@property (nonatomic, strong) NSPopUpButton *jobPopup, *charPopup, *sensPopup;
@property (nonatomic, strong) NSButton *vsyncCheck, *fullscreenCheck, *godrayCheck;
@property (nonatomic, strong) NSButton *renderCheck, *fastCheck, *hudCheck;
@property (nonatomic, strong) NSButton *mouseCheck, *captureCheck, *autoStartCheck;
@property (nonatomic, strong) NSTextField *statusField;
@property (nonatomic, strong) NSTask *remapper;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, copy) NSDictionary *saved;
@property (nonatomic) BOOL autoPlay;
@end

@implementation DMC4

// ---- 小工具 ----

- (NSTextField *)label:(NSString *)text frame:(NSRect)f size:(CGFloat)sz bold:(BOOL)b color:(NSColor *)c {
    NSTextField *t = [NSTextField labelWithString:text];
    t.frame = f;
    t.font = b ? [NSFont boldSystemFontOfSize:sz] : [NSFont systemFontOfSize:sz];
    t.textColor = c ?: NSColor.labelColor;
    return t;
}

- (NSPopUpButton *)popup:(NSRect)f items:(NSArray *)items {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:f pullsDown:NO];
    [p addItemsWithTitles:items];
    p.font = [NSFont systemFontOfSize:12];
    return p;
}

- (NSButton *)check:(NSRect)f title:(NSString *)title on:(BOOL)on {
    NSButton *b = [NSButton checkboxWithTitle:title target:nil action:nil];
    b.frame = f;
    b.font = [NSFont systemFontOfSize:12];
    b.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    return b;
}

- (NSButton *)button:(NSRect)f title:(NSString *)title action:(SEL)sel key:(NSString *)key {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
    b.frame = f;
    b.bezelStyle = NSBezelStyleRounded;
    b.font = [NSFont systemFontOfSize:13];
    if (key.length) b.keyEquivalent = key;
    return b;
}

- (NSBox *)separator:(CGFloat)y {
    NSBox *b = [[NSBox alloc] initWithFrame:NSMakeRect(24, y, 712, 1)];
    b.boxType = NSBoxSeparator;
    return b;
}

// ---- 设置读写 ----

- (void)select:(NSPopUpButton *)p value:(NSString *)v {
    if (!v) return;
    NSUInteger i = [p.itemTitles indexOfObject:v];
    if (i != NSNotFound) [p selectItemAtIndex:(NSInteger)i];
}

- (BOOL)flag:(NSString *)k def:(BOOL)d {
    id v = self.saved[k];
    return v ? [v boolValue] : d;
}

- (void)loadSettings {
    NSData *d = [NSData dataWithContentsOfFile:g_settings];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    self.saved = [obj isKindOfClass:[NSDictionary class]] ? obj : @{};

    [self select:self.resPopup      value:self.saved[@"res"] ?: @"1024x576"];
    [self select:self.qualityPopup  value:self.saved[@"quality"] ?: @"最低"];
    [self select:self.texturePopup  value:self.saved[@"texture"] ?: @"低"];
    [self select:self.effectPopup   value:self.saved[@"effect"] ?: @"低"];
    [self select:self.dlPopup       value:self.saved[@"dl"] ?: @"单色镜面（最快）"];
    [self select:self.hdrPopup      value:self.saved[@"hdr"] ?: @"整数对数（推荐）"];
    [self select:self.aaPopup       value:self.saved[@"aa"] ?: @"关闭"];
    [self select:self.jobPopup      value:self.saved[@"job"] ?: @"4"];
    [self select:self.charPopup     value:self.saved[@"char"] ?: @"维吉尔·但丁（近战 J / 枪 I）"];
    [self select:self.sensPopup     value:self.saved[@"sens"] ?: @"6（推荐）"];

    self.vsyncCheck.state      = [self flag:@"vsync" def:NO] ? NSControlStateValueOn : NSControlStateValueOff;
    self.fullscreenCheck.state = [self flag:@"fullscreen" def:NO] ? NSControlStateValueOn : NSControlStateValueOff;
    self.godrayCheck.state     = [self flag:@"godray" def:NO] ? NSControlStateValueOn : NSControlStateValueOff;
    self.renderCheck.state     = [self flag:@"render" def:YES] ? NSControlStateValueOn : NSControlStateValueOff;
    self.fastCheck.state       = [self flag:@"fastmath" def:YES] ? NSControlStateValueOn : NSControlStateValueOff;
    self.hudCheck.state        = [self flag:@"hud" def:NO] ? NSControlStateValueOn : NSControlStateValueOff;
    self.mouseCheck.state      = [self flag:@"mouse" def:YES] ? NSControlStateValueOn : NSControlStateValueOff;
    self.captureCheck.state    = [self flag:@"capture" def:YES] ? NSControlStateValueOn : NSControlStateValueOff;
    self.autoStartCheck.state  = [self flag:@"autostart" def:NO] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (BOOL)saveSettings {
    NSDictionary *s = @{
        @"res": self.resPopup.titleOfSelectedItem,
        @"quality": self.qualityPopup.titleOfSelectedItem,
        @"texture": self.texturePopup.titleOfSelectedItem,
        @"effect": self.effectPopup.titleOfSelectedItem,
        @"dl": self.dlPopup.titleOfSelectedItem,
        @"hdr": self.hdrPopup.titleOfSelectedItem,
        @"aa": self.aaPopup.titleOfSelectedItem,
        @"job": self.jobPopup.titleOfSelectedItem,
        @"char": self.charPopup.titleOfSelectedItem,
        @"sens": self.sensPopup.titleOfSelectedItem,
        @"vsync": @(self.vsyncCheck.state == NSControlStateValueOn),
        @"fullscreen": @(self.fullscreenCheck.state == NSControlStateValueOn),
        @"godray": @(self.godrayCheck.state == NSControlStateValueOn),
        @"render": @(self.renderCheck.state == NSControlStateValueOn),
        @"fastmath": @(self.fastCheck.state == NSControlStateValueOn),
        @"hud": @(self.hudCheck.state == NSControlStateValueOn),
        @"mouse": @(self.mouseCheck.state == NSControlStateValueOn),
        @"capture": @(self.captureCheck.state == NSControlStateValueOn),
        @"autostart": @(self.autoStartCheck.state == NSControlStateValueOn),
    };
    NSString *dir = [g_settings stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSJSONSerialization dataWithJSONObject:s
                                                options:NSJSONWritingPrettyPrinted error:nil];
    return [d writeToFile:g_settings atomically:YES];
}

// ---- 写游戏配置 ----

- (void)applyConfig {
    if (!PathExists(g_config)) return;

    NSString *quality = (self.qualityPopup.indexOfSelectedItem == 0) ? @"0" : @"1";
    NSString *texture = kTextureV[self.texturePopup.indexOfSelectedItem];
    NSString *effect  = kEffectV[self.effectPopup.indexOfSelectedItem];
    NSString *dl      = kDLV[self.dlPopup.indexOfSelectedItem];
    NSString *hdr     = kHDRV[self.hdrPopup.indexOfSelectedItem];
    NSString *aa      = kAAV[self.aaPopup.indexOfSelectedItem];
    NSString *res     = kRes[self.resPopup.indexOfSelectedItem];
    NSString *job     = [NSString stringWithFormat:@"%ld", (long)self.jobPopup.indexOfSelectedItem + 1];

    NSDictionary *g = @{
        @"HDR": @"DEFAULT",
        @"AntiAlias": aa,
        @"AltAntiAlias": @"NONE",
        @"DeferredLightingLight": dl,
        @"DeferredLightingHDR": hdr,
        @"SLI": @"OFF",
        @"GodRay": self.godrayCheck.state == NSControlStateValueOn ? @"ON" : @"OFF",
        @"Stereo": @"OFF",
        @"EffectVolume": effect,
        @"TextureResolution": [quality isEqualToString:@"0"] ? @"0" : @"1",
        @"Quality": quality,
        @"FrameRate": @"2",
        @"TextureDetail": texture,
        @"TextureMipLimite": @"2",
    };
    NSDictionary *d = @{
        @"Resolution": res,
        @"Aspect": @"DEFAULT",
        @"RefreshRate": @"60.00Hz",
        @"FullScreen": self.fullscreenCheck.state == NSControlStateValueOn ? @"ON" : @"OFF",
        @"VSYNC": self.vsyncCheck.state == NSControlStateValueOn ? @"ON" : @"OFF",
    };
    NSDictionary *c = @{
        @"JobThread": job,
        @"RenderingThread": self.renderCheck.state == NSControlStateValueOn ? @"ON" : @"OFF",
    };

    ini_write(g_config, @"GRAPHICS", g);
    ini_write(g_config, @"DISPLAY", d);
    ini_write(g_config, @"CPU", c);

    // 同步模板，保证「直接双击游戏 app」也拿到同一套设置
    ini_write(g_template, @"GRAPHICS", g);
    ini_write(g_template, @"DISPLAY", d);
    ini_write(g_template, @"CPU", c);
}

- (void)applyInfoPlist {
    NSData *data = [NSData dataWithContentsOfFile:g_infoPlist];
    if (!data) return;
    NSMutableDictionary *pl = [[NSPropertyListSerialization
        propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves
        format:NULL error:nil] mutableCopy];
    if (![pl isKindOfClass:[NSMutableDictionary class]]) return;
    pl[@"METAL_HUD"] = self.hudCheck.state == NSControlStateValueOn ? @"1" : @"0";
    pl[@"FASTMATH"]  = self.fastCheck.state == NSControlStateValueOn ? @"1" : @"0";
    NSData *out = [NSPropertyListSerialization dataWithPropertyList:pl
                    format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    [out writeToFile:g_infoPlist atomically:YES];
}

- (BOOL)ensureRegistry {
    if ([self gameRunning]) return NO;
    NSString *txt = [NSString stringWithContentsOfFile:g_userReg
                                              encoding:NSUTF8StringEncoding error:nil];
    if (!txt) return NO;
    NSDictionary *want = @{
        @"VideoMemorySize": @"4096",
        @"csmt": @"3",
        @"OffscreenRenderingMode": @"fbo",
        @"renderer": @"vulkan",
    };
    NSString *out = ini_update(txt, @"Software\\\\Wine\\\\Direct3D", want);
    if ([out isEqualToString:txt]) return NO;
    [[NSFileManager defaultManager] copyItemAtPath:g_userReg
                                            toPath:[g_userReg stringByAppendingString:@".launcher.bak"]
                                             error:nil];
    return [out writeToFile:g_userReg atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

// ---- 进程 ----

- (BOOL)gameRunning {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/usr/bin/pgrep";
    t.arguments = @[@"-f", @"DevilMayCry4SpecialEdition.exe"];
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { return NO; }
    return t.terminationStatus == 0;
}

- (void)run:(NSString *)path args:(NSArray *)args {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = path;
    t.arguments = args;
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
}

- (void)startRemapper {
    if (g_remap_state == 1) return;
    if (!CGPreflightPostEventAccess()) {
        self.statusField.stringValue = @"鼠标接管需要辅助功能权限，请点「授权」。";
        return;
    }
    NSMutableArray *args = [NSMutableArray arrayWithObject:@"dmc4_input"];
    [args addObject:@"--no-signals"];
    [args addObject:@"--melee"];
    [args addObject:(self.charPopup.indexOfSelectedItem == 0 ? @"i" : @"j")];
    [args addObject:@"--sens"];
    [args addObject:[NSString stringWithFormat:@"%ld", (long)self.sensPopup.indexOfSelectedItem * 2 + 4]];
    if (self.captureCheck.state != NSControlStateValueOn) [args addObject:@"--no-capture"];

    char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = strdup([args[i] UTF8String]);
    argv[args.count] = NULL;

    g_remap_state = 1;
    pthread_t t;
    if (pthread_create(&t, NULL, dmc4_remap_thread, argv) != 0) {
        g_remap_state = 0;
        self.statusField.stringValue = @"重映射线程创建失败";
        return;
    }
    pthread_detach(t);
}

- (void)stopRemapper {
    // 进程内线程无法单独停止；退出 app 时进程结束，重映射器的 atexit 会还原鼠标关联。
}

// ---- 动作 ----

- (void)startGame:(id)sender {
    if (!PathExists(g_gameApp)) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"找不到游戏本体";
        a.informativeText = [NSString stringWithFormat:@"路径：%@\n请确认固态盘已插好。", g_gameApp];
        [a runModal];
        return;
    }

    [self saveSettings];
    [self applyConfig];
    [self applyInfoPlist];
    [self ensureRegistry];

    // 先启动游戏：不依赖辅助功能权限，绝不让授权框卡住启动
    [self run:@"/usr/bin/open" args:@[@"-a", g_gameApp]];

    if (self.mouseCheck.state == NSControlStateValueOn) {
        if (CGPreflightPostEventAccess()) {
            [self startRemapper];
            self.statusField.stringValue = @"已启动：游戏 + 鼠标接管（进程内）";
        } else {
            self.statusField.stringValue = @"游戏已启动；鼠标接管需要辅助功能权限——系统设置里勾选「鬼泣4 启动器」，然后退出重开启动器（只需一次）。";
        }
    } else {
        self.statusField.stringValue = @"已启动游戏（鼠标接管已关闭）";
    }
}

- (void)authorize:(id)sender {
    NSDictionary *opts = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
    BOOL ok = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    self.statusField.stringValue = ok
        ? @"已有辅助功能权限，可以直接启动。"
        : @"已打开授权提示：勾选「鬼泣4 启动器」后，再点一次「启动游戏」。";
}

- (void)openAccessibilitySettings:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (void)stopGame:(id)sender {
    [self stopRemapper];
    [self run:@"/usr/bin/pkill" args:@[@"-9", @"-f", @"DevilMayCry4SpecialEdition.exe"]];
    [self run:@"/usr/bin/pkill" args:@[@"-9", @"-f", @"wineserver"]];
    [self run:@"/usr/bin/pkill" args:@[@"-9", @"-f", @"windows.system32"]];
    self.statusField.stringValue = @"已结束游戏与鼠标接管";
}

- (void)resetDefaults:(id)sender {
    [self select:self.resPopup value:@"1024x576"];
    [self select:self.qualityPopup value:@"最低"];
    [self select:self.texturePopup value:@"低"];
    [self select:self.effectPopup value:@"低"];
    [self select:self.dlPopup value:@"单色镜面（最快）"];
    [self select:self.hdrPopup value:@"整数对数（推荐）"];
    [self select:self.aaPopup value:@"关闭"];
    [self select:self.jobPopup value:@"4"];
    [self select:self.charPopup value:@"维吉尔·但丁（近战 J / 枪 I）"];
    [self select:self.sensPopup value:@"6（推荐）"];
    self.vsyncCheck.state = NSControlStateValueOff;
    self.fullscreenCheck.state = NSControlStateValueOff;
    self.godrayCheck.state = NSControlStateValueOff;
    self.renderCheck.state = NSControlStateValueOn;
    self.fastCheck.state = NSControlStateValueOn;
    self.hudCheck.state = NSControlStateValueOff;
    self.mouseCheck.state = NSControlStateValueOn;
    self.captureCheck.state = NSControlStateValueOn;
    self.autoStartCheck.state = NSControlStateValueOff;
    [self saveSettings];
    self.statusField.stringValue = @"已恢复推荐默认值";
}

// ---- 界面 ----

- (void)buildWindow {
    NSRect r = NSMakeRect(0, 0, 760, 620);
    self.window = [[NSWindow alloc] initWithContentRect:r
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"鬼泣4 特别版 · 启动器";
    self.window.delegate = self;
    [self.window center];

    FlippedView *v = [[FlippedView alloc] initWithFrame:r];
    self.window.contentView = v;

    [v addSubview:[self label:@"鬼泣4 特别版" frame:NSMakeRect(24, 14, 400, 28)
                        size:20 bold:YES color:nil]];
    [v addSubview:[self label:@"所有设置都在这里；点「启动游戏」= 写配置 + 启动 + 鼠标接管"
                       frame:NSMakeRect(24, 42, 700, 18)
                        size:11 bold:NO color:NSColor.secondaryLabelColor]];
    [v addSubview:[self separator:68]];

    // 左列
    [v addSubview:[self label:@"显示" frame:NSMakeRect(24, 80, 200, 20) size:13 bold:YES color:nil]];

    [v addSubview:[self label:@"分辨率" frame:NSMakeRect(24, 112, 80, 20) size:12 bold:NO color:nil]];
    self.resPopup = [self popup:NSMakeRect(110, 108, 240, 26) items:kRes];
    [v addSubview:self.resPopup];

    [v addSubview:[self label:@"窗口" frame:NSMakeRect(24, 144, 80, 20) size:12 bold:NO color:nil]];
    self.fullscreenCheck = [self check:NSMakeRect(110, 144, 110, 20) title:@"全屏" on:NO];
    [v addSubview:self.fullscreenCheck];
    self.vsyncCheck = [self check:NSMakeRect(230, 144, 120, 20) title:@"垂直同步" on:NO];
    [v addSubview:self.vsyncCheck];

    [v addSubview:[self label:@"画质" frame:NSMakeRect(24, 184, 200, 20) size:13 bold:YES color:nil]];

    [v addSubview:[self label:@"画质档" frame:NSMakeRect(24, 216, 80, 20) size:12 bold:NO color:nil]];
    self.qualityPopup = [self popup:NSMakeRect(110, 212, 240, 26) items:kQuality];
    [v addSubview:self.qualityPopup];

    [v addSubview:[self label:@"纹理细节" frame:NSMakeRect(24, 248, 80, 20) size:12 bold:NO color:nil]];
    self.texturePopup = [self popup:NSMakeRect(110, 244, 240, 26) items:kTexture];
    [v addSubview:self.texturePopup];

    [v addSubview:[self label:@"特效量" frame:NSMakeRect(24, 280, 80, 20) size:12 bold:NO color:nil]];
    self.effectPopup = [self popup:NSMakeRect(110, 276, 240, 26) items:kEffect];
    [v addSubview:self.effectPopup];

    [v addSubview:[self label:@"延迟光照" frame:NSMakeRect(24, 312, 80, 20) size:12 bold:NO color:nil]];
    self.dlPopup = [self popup:NSMakeRect(110, 308, 240, 26) items:kDL];
    [v addSubview:self.dlPopup];

    [v addSubview:[self label:@"光照 HDR" frame:NSMakeRect(24, 344, 80, 20) size:12 bold:NO color:nil]];
    self.hdrPopup = [self popup:NSMakeRect(110, 340, 240, 26) items:kHDR];
    [v addSubview:self.hdrPopup];

    [v addSubview:[self label:@"抗锯齿" frame:NSMakeRect(24, 376, 80, 20) size:12 bold:NO color:nil]];
    self.aaPopup = [self popup:NSMakeRect(110, 372, 240, 26) items:kAA];
    [v addSubview:self.aaPopup];

    self.godrayCheck = [self check:NSMakeRect(110, 404, 240, 20) title:@"GodRay（体积光，建议关）" on:NO];
    [v addSubview:self.godrayCheck];

    // 右列
    [v addSubview:[self label:@"性能" frame:NSMakeRect(396, 80, 200, 20) size:13 bold:YES color:nil]];

    [v addSubview:[self label:@"工作线程" frame:NSMakeRect(396, 112, 80, 20) size:12 bold:NO color:nil]];
    self.jobPopup = [self popup:NSMakeRect(482, 108, 240, 26) items:kJob];
    [v addSubview:self.jobPopup];

    self.renderCheck = [self check:NSMakeRect(482, 140, 240, 20) title:@"渲染线程（RenderingThread）" on:YES];
    [v addSubview:self.renderCheck];

    self.fastCheck = [self check:NSMakeRect(482, 168, 240, 20) title:@"FASTMATH（MoltenVK 快速数学）" on:YES];
    [v addSubview:self.fastCheck];

    self.hudCheck = [self check:NSMakeRect(482, 196, 240, 20) title:@"Metal HUD（显示帧率，耗一点性能）" on:NO];
    [v addSubview:self.hudCheck];

    [v addSubview:[self label:@"鼠标" frame:NSMakeRect(396, 236, 200, 20) size:13 bold:YES color:nil]];

    self.mouseCheck = [self check:NSMakeRect(482, 268, 240, 20) title:@"启用鼠标接管（左键近战 / 右键鬼手）" on:YES];
    [v addSubview:self.mouseCheck];

    [v addSubview:[self label:@"角色" frame:NSMakeRect(396, 300, 80, 20) size:12 bold:NO color:nil]];
    self.charPopup = [self popup:NSMakeRect(482, 296, 240, 26) items:kChar];
    [v addSubview:self.charPopup];

    [v addSubview:[self label:@"灵敏度" frame:NSMakeRect(396, 332, 80, 20) size:12 bold:NO color:nil]];
    self.sensPopup = [self popup:NSMakeRect(482, 328, 240, 26) items:kSens];
    [v addSubview:self.sensPopup];

    self.captureCheck = [self check:NSMakeRect(482, 360, 240, 20) title:@"锁定光标在游戏框内" on:YES];
    [v addSubview:self.captureCheck];

    NSTextField *note = [self label:
        @"键位：左键=近战 / 右键=鬼手 / 空格=跳跃+确认 / Shift=锁定 /\n"
        @"中键·侧键·F=枪 / 鼠标移动=转视角。\n"
        @"首次使用需在「系统设置 → 隐私与安全性 → 辅助功能」勾选本启动器。"
        frame:NSMakeRect(396, 396, 340, 58) size:11 bold:NO color:NSColor.secondaryLabelColor];
    note.maximumNumberOfLines = 4;
    [v addSubview:note];

    // 底部
    [v addSubview:[self separator:466]];
    self.autoStartCheck = [self check:NSMakeRect(24, 472, 360, 20)
                                title:@"打开启动器后自动启动游戏（双击即玩）" on:NO];
    [v addSubview:self.autoStartCheck];
    [v addSubview:[self button:NSMakeRect(24, 500, 170, 34) title:@"启动游戏"
                          action:@selector(startGame:) key:@"\r"]];
    [v addSubview:[self button:NSMakeRect(206, 500, 130, 34) title:@"结束游戏"
                          action:@selector(stopGame:) key:@""]];
    [v addSubview:[self button:NSMakeRect(348, 500, 130, 34) title:@"恢复默认"
                          action:@selector(resetDefaults:) key:@""]];
    [v addSubview:[self button:NSMakeRect(490, 500, 90, 34) title:@"授权"
                          action:@selector(authorize:) key:@""]];

    self.statusField = [self label:@"就绪" frame:NSMakeRect(24, 552, 712, 34)
                             size:11 bold:NO color:NSColor.secondaryLabelColor];
    self.statusField.maximumNumberOfLines = 2;
    [v addSubview:self.statusField];

    [self loadSettings];
}

// ---- 生命周期 ----

- (void)windowWillClose:(NSNotification *)n {
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)n {
    [self stopRemapper];
}

- (void)tick:(NSTimer *)t {
    if (g_remap_state == 3) {
        self.statusField.stringValue = @"鼠标接管启动失败：缺少辅助功能权限（点「授权」）";
    }
}

@end

// ---------------------------------------------------------------- main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        kRes     = @[@"800x450", @"960x540", @"1024x576", @"1280x720", @"1600x900", @"1920x1080"];
        kQuality = @[@"最低", @"高"];
        kTexture = @[@"最低", @"低", @"中", @"高", @"最高"];
        kTextureV= @[@"LOWEST", @"LOW", @"MEDIUM", @"HIGH", @"HIGHEST"];
        kEffect  = @[@"低", @"高"];
        kEffectV = @[@"LOW", @"HIGH"];
        kDL      = @[@"单色镜面（最快）", @"近似镜面", @"分离镜面（最好）"];
        kDLV     = @[@"MONOCHROME_SPECULAR", @"APPROXIMATE_SPECULAR", @"SEPARATE_SPECULAR"];
        kHDR     = @[@"整数对数（推荐）", @"整数", @"浮点", @"高精度浮点"];
        kHDRV    = @[@"INTEGER_LOG", @"INTEGER", @"FLOAT", @"FLOAT_PRECISION"];
        kAA      = @[@"关闭", @"MSAA 2x", @"MSAA 4x", @"MSAA 8x"];
        kAAV     = @[@"NONE", @"MSAA2X", @"MSAA4X", @"MSAA8X"];
        kChar    = @[@"尼禄（近战 I / 枪 J）", @"维吉尔·但丁（近战 J / 枪 I）"];
        kSens    = @[@"4（最灵敏）", @"6（推荐）", @"8", @"10", @"12（最迟钝）"];
        kJob     = @[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9"];

        ResolvePaths();

        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSMenu *menubar = [NSMenu new];
        NSMenuItem *appItem = [NSMenuItem new];
        [menubar addItem:appItem];
        NSMenu *appMenu = [NSMenu new];
        [appMenu addItemWithTitle:@"关于 鬼泣4 启动器"
                           action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *axItem = [[NSMenuItem alloc] initWithTitle:@"打开辅助功能设置"
                                                        action:@selector(openAccessibilitySettings:)
                                                 keyEquivalent:@""];
        axItem.target = nil;
        [appMenu addItem:axItem];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"退出" action:@selector(terminate:) keyEquivalent:@"q"];
        appItem.submenu = appMenu;
        [app setMainMenu:menubar];

        DMC4 *d = [DMC4 new];
        app.delegate = d;
        [d buildWindow];
        [d.window makeKeyAndOrderFront:nil];
        [app activateIgnoringOtherApps:YES];

        if (d.autoStartCheck.state == NSControlStateValueOn) {
            [d performSelector:@selector(startGame:) withObject:nil afterDelay:0.8];
        }

        d.pollTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                       target:d
                                                     selector:@selector(tick:)
                                                     userInfo:nil
                                                      repeats:YES];

        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--play") == 0) {
                [d performSelector:@selector(startGame:) withObject:nil afterDelay:0.6];
            }
        }

        [app run];
    }
    return 0;
}
