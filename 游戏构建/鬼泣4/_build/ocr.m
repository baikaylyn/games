// ocr.m <image.png> —— 用 Vision 识别图中文字（Objective-C 版，clang 直接编译）
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <AppKit/AppKit.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "用法: ocr <image.png>\n"); return 2; }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSImage *img = [[NSImage alloc] initWithContentsOfFile:path];
        if (!img) { fprintf(stderr, "打不开图: %s\n", argv[1]); return 1; }
        CGImageRef cg = [img CGImageForProposedRect:NULL context:nil hints:nil];
        if (!cg) { fprintf(stderr, "取不到 CGImage\n"); return 1; }

        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.recognitionLanguages = @[ @"en-US", @"zh-Hans", @"ja-JP" ];
        req.usesLanguageCorrection = NO;

        VNImageRequestHandler *h =
            [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
        NSError *err = nil;
        if (![h performRequests:@[ req ] error:&err]) {
            fprintf(stderr, "识别失败: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }

        NSMutableArray *rows = [NSMutableArray array];
        for (VNRecognizedTextObservation *obs in req.results) {
            VNRecognizedText *c = [obs topCandidates:1].firstObject;
            if (!c) continue;
            NSValue *box = [NSValue valueWithPoint:obs.boundingBox.origin];
            [rows addObject:@[ c.string, @(c.confidence), box ]];
        }
        // Vision 坐标原点在左下 → y 大的在上面
        [rows sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
            CGFloat ya = [a[2] pointValue].y, yb = [b[2] pointValue].y;
            if (fabs(ya - yb) > 0.02) return ya > yb ? NSOrderedAscending : NSOrderedDescending;
            return [a[2] pointValue].x < [b[2] pointValue].x ? NSOrderedAscending : NSOrderedDescending;
        }];
        for (NSArray *r in rows) {
            NSPoint p = [r[2] pointValue];
            printf("[%4.2f @%.2f,%.2f] %s\n",
                   [r[1] floatValue], p.x, p.y, [r[0] UTF8String]);
        }
    }
    return 0;
}
