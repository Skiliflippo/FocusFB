#import "FocusFBMediaDownloader.h"
#import "FocusFBPrefs.h"
#import "FocusFBTabManager.h"
#import "FocusFBStoriesManager.h"
#import "FocusFBSettingsViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <os/lock.h>

static const NSInteger kFFBInlineReelDownloadBtnTag = 0x70C5D5;

typedef void (*FFBAVPlayerReplaceItemIMP)(id, SEL, AVPlayerItem *);

static FFBAVPlayerReplaceItemIMP gOrigAVPlayerReplaceItem = NULL;
static BOOL gInstalledPlayerHook  = NO;
static BOOL gMediaDownloaderReady = NO;
static BOOL gDownloadInFlight     = NO;

static os_unfair_lock gPlayerTrackLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<AVPlayer *> *gTrackedAVPlayers = nil;
static NSHashTable<UIButton *> *gMountedReelButtons = nil;

static char kIsReelsCollectionCacheKey;
static char kLastCellBtnSyncTimeKey;

// Selettori opzionali delle classi video interne di Facebook (FBVideoPlayback*, FBSnacks*, FNF*)
@interface NSObject (FFBFacebookVideoSelectors)
- (nullable id)controller;
- (nullable id)manager;
- (nullable id)mediaView;
- (nullable id)currentVideoPlaybackItem;
- (nullable NSURL *)HDPlaybackURL;
- (nullable NSURL *)SDPlaybackURL;
- (nullable NSURL *)hdPlaybackURL;
- (nullable NSURL *)sdPlaybackURL;
- (nullable NSURL *)playableURL;
- (nullable NSURL *)videoURL;
- (nullable NSURL *)audioURL;
- (nullable NSURL *)audioPlaybackURL;
@end

// ─────────────────────────────────────────────────────────────────────────────
// 1. Icone Vettoriali nello Stile Esatto di Facebook Reels (Stroke 2.15pt #FFFFFF)
// ─────────────────────────────────────────────────────────────────────────────

static UIImage *FFBReelOutlineDownloadImage(void) {
    static UIImage *cachedImg = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize sz = CGSizeMake(26.0, 26.0);
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.opaque = NO;
        fmt.scale = UIScreen.mainScreen.scale;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
        cachedImg = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGContextRef cg = ctx.CGContext;
            CGContextSetStrokeColorWithColor(cg, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(cg, 2.15);
            CGContextSetLineCap(cg, kCGLineCapRound);
            CGContextSetLineJoin(cg, kCGLineJoinRound);

            // Asta verticale freccia
            CGContextMoveToPoint(cg, 13.0, 3.4);
            CGContextAddLineToPoint(cg, 13.0, 16.2);
            CGContextStrokePath(cg);

            // Punta freccia arrotondata
            CGContextMoveToPoint(cg, 7.9, 11.4);
            CGContextAddLineToPoint(cg, 13.0, 16.5);
            CGContextAddLineToPoint(cg, 18.1, 11.4);
            CGContextStrokePath(cg);

            // Vaschetta inferiore arrotondata (stesso raggio degli angoli di Mi piace / Salva di Facebook)
            UIBezierPath *tray = [UIBezierPath bezierPath];
            tray.lineWidth = 2.15;
            tray.lineCapStyle = kCGLineCapRound;
            tray.lineJoinStyle = kCGLineJoinRound;
            [tray moveToPoint:CGPointMake(4.4, 16.4)];
            [tray addLineToPoint:CGPointMake(4.4, 19.6)];
            [tray addQuadCurveToPoint:CGPointMake(7.0, 22.2) controlPoint:CGPointMake(4.4, 22.2)];
            [tray addLineToPoint:CGPointMake(19.0, 22.2)];
            [tray addQuadCurveToPoint:CGPointMake(21.6, 19.6) controlPoint:CGPointMake(21.6, 22.2)];
            [tray addLineToPoint:CGPointMake(21.6, 16.4)];
            [[UIColor whiteColor] setStroke];
            [tray stroke];
        }];
    });
    return cachedImg;
}

static UIImage *FFBReelOutlineCheckmarkImage(void) {
    static UIImage *cachedCheck = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGSize sz = CGSizeMake(26.0, 26.0);
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.opaque = NO;
        fmt.scale = UIScreen.mainScreen.scale;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
        cachedCheck = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            CGContextRef cg = ctx.CGContext;
            CGContextSetStrokeColorWithColor(cg, [UIColor whiteColor].CGColor);
            CGContextSetLineWidth(cg, 2.25);
            CGContextSetLineCap(cg, kCGLineCapRound);
            CGContextSetLineJoin(cg, kCGLineJoinRound);

            CGContextMoveToPoint(cg, 5.5, 13.8);
            CGContextAddLineToPoint(cg, 10.8, 19.2);
            CGContextAddLineToPoint(cg, 20.6, 7.6);
            CGContextStrokePath(cg);
        }];
    });
    return cachedCheck;
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Modello Candidato Video & Estrazione Stream (FNF / DASH efg= / HLS / AVPlayer)
// ─────────────────────────────────────────────────────────────────────────────

@interface FFBMediaCandidate : NSObject
@property (nonatomic, strong, nullable) NSURL *hdVideoURL;
@property (nonatomic, strong, nullable) NSURL *sdVideoURL;
@property (nonatomic, strong, nullable) NSURL *separateAudioURL;
@property (nonatomic, strong, nullable) AVAsset *avAsset;
@property (nonatomic, assign) CGFloat rawVisibleArea;
@property (nonatomic, assign) CGFloat screenAreaScore;
@property (nonatomic, assign) CFAbsoluteTime capturedAt;
- (BOOL)hasUsableVideo;
@end

@implementation FFBMediaCandidate
- (BOOL)hasUsableVideo {
    return (self.hdVideoURL != nil || self.sdVideoURL != nil || self.avAsset != nil);
}
@end

static NSURL *FFBLookupURLForAsset(AVAsset *asset) {
    if (!asset) return nil;
    if ([asset isKindOfClass:AVURLAsset.class]) {
        return ((AVURLAsset *)asset).URL;
    }
    if ([asset isKindOfClass:AVComposition.class]) {
        for (AVCompositionTrack *tr in ((AVComposition *)asset).tracks) {
            if ([tr.mediaType isEqualToString:AVMediaTypeVideo]) {
                for (AVCompositionTrackSegment *seg in tr.segments) {
                    if (!seg.isEmpty && seg.sourceURL) return seg.sourceURL;
                }
            }
        }
    }
    if ([asset respondsToSelector:@selector(URL)]) {
        @try {
            id u = [asset valueForKey:@"URL"];
            if ([u isKindOfClass:NSURL.class]) return (NSURL *)u;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static id FFBSafeObjectProperty(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != 2) return nil;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || enc[0] != '@') return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSURL *FFBSafeURLProperty(id obj, SEL sel) {
    id val = FFBSafeObjectProperty(obj, sel);
    if ([val isKindOfClass:NSURL.class]) return (NSURL *)val;
    if ([val isKindOfClass:NSString.class] && [(NSString *)val hasPrefix:@"http"]) {
        return [NSURL URLWithString:(NSString *)val];
    }
    return nil;
}

typedef NS_ENUM(NSInteger, FFBStreamKind) {
    FFBStreamKindNotVideo = 0,
    FFBStreamKindProgressiveVideoWithAudio = 1,
    FFBStreamKindHLSPlaylist = 2,
    FFBStreamKindDASHVideoTrack = 3,
    FFBStreamKindDASHAudioTrack = 4,
};

static NSString *FFBDecodeEfgTagFromURLString(NSString *urlStr) {
    NSRange r = [urlStr rangeOfString:@"efg="];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r);
    NSRange amp = [urlStr rangeOfString:@"&" options:0 range:NSMakeRange(start, urlStr.length - start)];
    NSUInteger len = (amp.location == NSNotFound ? urlStr.length : amp.location) - start;
    if (len == 0 || len > 2048) return nil;

    NSString *b64 = [urlStr substringWithRange:NSMakeRange(start, len)];
    b64 = [b64 stringByRemovingPercentEncoding] ?: b64;
    b64 = [[b64 stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
               stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    NSUInteger rem = b64.length % 4;
    if (rem > 0) {
        b64 = [b64 stringByPaddingToLength:(b64.length + (4 - rem)) withString:@"=" startingAtIndex:0];
    }
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!decoded.length) return nil;
    return [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
}

static FFBStreamKind FFBClassifyStreamURL(NSURL *url, NSString * _Nullable hintName, int *outResHeight) {
    if (outResHeight) *outResHeight = 0;
    if (!url) return FFBStreamKindNotVideo;
    NSString *abs = url.absoluteString;
    if (abs.length < 12 || abs.length > 4096) return FFBStreamKindNotVideo;

    NSString *lower = abs.lowercaseString;
    if (![lower hasPrefix:@"http"]) return FFBStreamKindNotVideo;

    NSString *pathLower = url.path.lowercaseString ?: @"";
    if ([pathLower hasSuffix:@".jpg"] || [pathLower hasSuffix:@".jpeg"] ||
        [pathLower hasSuffix:@".png"] || [pathLower hasSuffix:@".webp"] ||
        [pathLower hasSuffix:@".gif"] || [lower containsString:@"safe_image"]) {
        return FFBStreamKindNotVideo;
    }

    if ([pathLower hasSuffix:@".m3u8"] || [lower containsString:@".m3u8?"]) {
        if (outResHeight) *outResHeight = 1080;
        return FFBStreamKindHLSPlaylist;
    }

    if (![pathLower hasSuffix:@".mp4"] && ![lower containsString:@".mp4?"]) {
        return FFBStreamKindNotVideo;
    }

    NSString *lowerHint = hintName.lowercaseString ?: @"";
    if ([lowerHint containsString:@"audio"]) {
        return FFBStreamKindDASHAudioTrack;
    }

    NSString *efg = FFBDecodeEfgTagFromURLString(abs).lowercaseString;
    if (efg.length > 0) {
        if ([efg containsString:@"audio"] || [efg containsString:@"heaac"] || [efg containsString:@"opus"]) {
            return FFBStreamKindDASHAudioTrack;
        }
        if (outResHeight) {
            if ([efg containsString:@"1080"]) *outResHeight = 1080;
            else if ([efg containsString:@"720"]) *outResHeight = 720;
            else if ([efg containsString:@"540"]) *outResHeight = 540;
            else if ([efg containsString:@"480"]) *outResHeight = 480;
            else if ([efg containsString:@"360"]) *outResHeight = 360;
        }
        if ([efg containsString:@"progressive"] || [efg containsString:@"xpv_progressive"]) {
            if (outResHeight && *outResHeight == 0) *outResHeight = 720;
            return FFBStreamKindProgressiveVideoWithAudio;
        }
        return FFBStreamKindDASHVideoTrack;
    }

    if (outResHeight) *outResHeight = 720;
    return FFBStreamKindProgressiveVideoWithAudio;
}

static void FFBRecordURLIntoCandidate(NSURL *url,
                                      NSString * _Nullable hint,
                                      FFBMediaCandidate *cand,
                                      int *bestVideoScore) {
    int resH = 0;
    FFBStreamKind kind = FFBClassifyStreamURL(url, hint, &resH);
    if (kind == FFBStreamKindNotVideo) return;

    if (kind == FFBStreamKindDASHAudioTrack) {
        if (!cand.separateAudioURL) {
            cand.separateAudioURL = url;
        }
        return;
    }

    int score = resH;
    if (kind == FFBStreamKindProgressiveVideoWithAudio) score += 5000;
    else if (kind == FFBStreamKindHLSPlaylist) score += 3500;
    else if (kind == FFBStreamKindDASHVideoTrack) score += 1000;
    if ([hint.lowercaseString containsString:@"hd"]) score += 800;

    if (!cand.hdVideoURL || score > *bestVideoScore) {
        if (cand.hdVideoURL && ![cand.hdVideoURL.absoluteString isEqualToString:url.absoluteString]) {
            cand.sdVideoURL = cand.hdVideoURL;
        }
        cand.hdVideoURL = url;
        *bestVideoScore = score;
    } else if (!cand.sdVideoURL && ![cand.hdVideoURL.absoluteString isEqualToString:url.absoluteString]) {
        cand.sdVideoURL = url;
    }
}

static void FFBPopulateFromPlaybackItem(id playbackItem, FFBMediaCandidate *cand, int *bestVideoScore) {
    if (!playbackItem || !cand) return;
    NSURL *hd = FFBSafeURLProperty(playbackItem, @selector(HDPlaybackURL))
             ?: FFBSafeURLProperty(playbackItem, @selector(hdPlaybackURL))
             ?: FFBSafeURLProperty(playbackItem, @selector(playableURL))
             ?: FFBSafeURLProperty(playbackItem, @selector(videoURL));
    NSURL *sd = FFBSafeURLProperty(playbackItem, @selector(SDPlaybackURL))
             ?: FFBSafeURLProperty(playbackItem, @selector(sdPlaybackURL));
    NSURL *au = FFBSafeURLProperty(playbackItem, @selector(audioURL))
             ?: FFBSafeURLProperty(playbackItem, @selector(audioPlaybackURL));
    if (hd) FFBRecordURLIntoCandidate(hd, @"hd", cand, bestVideoScore);
    if (sd) FFBRecordURLIntoCandidate(sd, @"sd", cand, bestVideoScore);
    if (au && !cand.separateAudioURL) cand.separateAudioURL = au;
}

static BOOL FFBSkipDeepIvarClassName(NSString *clsName) {
    if (clsName.length == 0) return YES;
    static NSArray<NSString *> *skipPrefixes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        skipPrefixes = @[@"UI", @"NS", @"CA", @"_UI", @"OS_", @"WK", @"CF", @"CKComponentScope"];
    });
    for (NSString *p in skipPrefixes) {
        if ([clsName hasPrefix:p]) return YES;
    }
    return NO;
}

static void FFBDeepScanObjectForVideoStreams(id obj,
                                             NSString * _Nullable hint,
                                             int hopDepth,
                                             NSMutableSet<NSValue *> *visited,
                                             FFBMediaCandidate *cand,
                                             int *bestVideoScore) {
    if (!obj || hopDepth > 3 || visited.count > 120) return;

    if ([obj isKindOfClass:NSURL.class]) {
        FFBRecordURLIntoCandidate((NSURL *)obj, hint, cand, bestVideoScore);
        return;
    }
    if ([obj isKindOfClass:NSString.class]) {
        NSString *s = (NSString *)obj;
        if (s.length > 16 && s.length < 4096 && [s hasPrefix:@"http"]) {
            NSURL *u = [NSURL URLWithString:s];
            if (u) FFBRecordURLIntoCandidate(u, hint, cand, bestVideoScore);
        }
        return;
    }
    if ([obj isKindOfClass:AVPlayer.class]) {
        AVPlayer *p = (AVPlayer *)obj;
        if (p.currentItem.asset && !cand.avAsset) {
            cand.avAsset = p.currentItem.asset;
            NSURL *u = FFBLookupURLForAsset(p.currentItem.asset);
            if (u) FFBRecordURLIntoCandidate(u, hint, cand, bestVideoScore);
        }
        return;
    }
    if ([obj isKindOfClass:AVAsset.class]) {
        if (!cand.avAsset) cand.avAsset = (AVAsset *)obj;
        NSURL *u = FFBLookupURLForAsset((AVAsset *)obj);
        if (u) FFBRecordURLIntoCandidate(u, hint, cand, bestVideoScore);
        return;
    }
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dict = (NSDictionary *)obj;
        NSUInteger checked = 0;
        for (id k in dict) {
            if (++checked > 20) break;
            NSString *kStr = [k isKindOfClass:NSString.class] ? (NSString *)k : hint;
            FFBDeepScanObjectForVideoStreams(dict[k], kStr, hopDepth + 1, visited, cand, bestVideoScore);
        }
        return;
    }
    if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray *)obj;
        NSUInteger limit = MIN((NSUInteger)8, arr.count);
        for (NSUInteger i = 0; i < limit; i++) {
            FFBDeepScanObjectForVideoStreams(arr[i], hint, hopDepth + 1, visited, cand, bestVideoScore);
        }
        return;
    }

    NSValue *ptrKey = [NSValue valueWithPointer:(__bridge const void *)obj];
    if ([visited containsObject:ptrKey]) return;
    [visited addObject:ptrKey];

    FFBPopulateFromPlaybackItem(obj, cand, bestVideoScore);
    id item = FFBSafeObjectProperty(obj, @selector(currentVideoPlaybackItem));
    if (item) {
        FFBPopulateFromPlaybackItem(item, cand, bestVideoScore);
        FFBDeepScanObjectForVideoStreams(item, @"playbackItem", hopDepth + 1, visited, cand, bestVideoScore);
    }

    if (hopDepth >= 3) return;

    Class cls = object_getClass(obj);
    int superHops = 0;
    while (cls && superHops < 6) {
        NSString *clsName = NSStringFromClass(cls);
        if (hopDepth > 0 && FFBSkipDeepIvarClassName(clsName)) break;
        if ([clsName isEqualToString:@"NSObject"] ||
            [clsName isEqualToString:@"UIResponder"] ||
            [clsName isEqualToString:@"UIView"] ||
            [clsName isEqualToString:@"UIViewController"]) {
            break;
        }

        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(cls, &ivarCount);
        if (ivars) {
            for (unsigned int i = 0; i < ivarCount && i < 48; i++) {
                const char *enc = ivar_getTypeEncoding(ivars[i]);
                if (!enc || enc[0] != '@') continue;
                const char *rawName = ivar_getName(ivars[i]);
                NSString *ivName = rawName ? [NSString stringWithUTF8String:rawName] : nil;

                id val = nil;
                @try {
                    val = object_getIvar(obj, ivars[i]);
                } @catch (__unused NSException *e) {
                    val = nil;
                }
                if (!val) continue;
                FFBDeepScanObjectForVideoStreams(val, ivName, hopDepth + 1, visited, cand, bestVideoScore);
            }
            free(ivars);
        }
        cls = class_getSuperclass(cls);
        superHops++;
    }
}

static BOOL FFBViewHostsCustomVideoLayerOrComponent(UIView *view) {
    NSString *clsName = NSStringFromClass(object_getClass(view)) ?: @"";
    if ([clsName containsString:@"VideoPlayerComponentStatefulView"] ||
        [clsName containsString:@"VideoContainerView"] ||
        [clsName containsString:@"VideoPlaybackContainerView"] ||
        [clsName containsString:@"SnacksNewVideoView"] ||
        [clsName containsString:@"SnacksMediaContainerView"] ||
        [clsName containsString:@"FNFPlayer"]) {
        return YES;
    }

    CALayer *rootLayer = view.layer;
    NSString *layerCls = NSStringFromClass(object_getClass(rootLayer)) ?: @"";
    if ([rootLayer isKindOfClass:AVPlayerLayer.class] ||
        [rootLayer isKindOfClass:AVSampleBufferDisplayLayer.class] ||
        [layerCls containsString:@"FNF"]) {
        return YES;
    }

    for (CALayer *sub in rootLayer.sublayers) {
        NSString *subCls = NSStringFromClass(object_getClass(sub)) ?: @"";
        if ([sub isKindOfClass:AVPlayerLayer.class] ||
            [sub isKindOfClass:AVSampleBufferDisplayLayer.class] ||
            [subCls containsString:@"FNF"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL FFBSubtreeContainsAnyVideoSurface(UIView *view, NSUInteger depth) {
    if (!view || depth > 28 || view.hidden || view.alpha <= 0.02) return NO;
    if (FFBViewHostsCustomVideoLayerOrComponent(view)) return YES;
    for (UIView *sub in view.subviews) {
        if (FFBSubtreeContainsAnyVideoSurface(sub, depth + 1)) return YES;
    }
    return NO;
}

static AVPlayer *FFBExtractAVPlayerFromView(UIView *view) {
    if (!view) return nil;
    if ([view.layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *p = ((AVPlayerLayer *)view.layer).player;
        if (p) return p;
    }
    for (CALayer *sub in view.layer.sublayers) {
        if ([sub isKindOfClass:AVPlayerLayer.class]) {
            AVPlayer *p = ((AVPlayerLayer *)sub).player;
            if (p) return p;
        }
    }
    id pObj = FFBSafeObjectProperty(view, NSSelectorFromString(@"player"));
    return [pObj isKindOfClass:AVPlayer.class] ? (AVPlayer *)pObj : nil;
}

static void FFBScanSubtreeForVideos(UIView *view,
                                    UIWindow *win,
                                    NSUInteger depth,
                                    int *visitedNodes,
                                    NSMutableArray<FFBMediaCandidate *> *outCandidates) {
    if (!view || depth > 44 || *visitedNodes > 4500) return;
    if (view.hidden || view.alpha <= 0.02 || view.tag == kFFBInlineReelDownloadBtnTag) return;
    (*visitedNodes)++;

    CGRect rectInWin = [view convertRect:view.bounds toView:win];
    CGRect vis = CGRectIntersection(rectInWin, win.bounds);
    CGFloat visW = CGRectIsNull(vis) ? 0.0 : CGRectGetWidth(vis);
    CGFloat visH = CGRectIsNull(vis) ? 0.0 : CGRectGetHeight(vis);

    if (view.clipsToBounds && (visW < 80.0 || visH < 80.0)) {
        return;
    }

    CGFloat area = visW * visH;
    if (area >= (100.0 * 100.0) && FFBViewHostsCustomVideoLayerOrComponent(view)) {
        FFBMediaCandidate *cand = [[FFBMediaCandidate alloc] init];
        cand.rawVisibleArea = area;
        cand.capturedAt = CFAbsoluteTimeGetCurrent();
        int bestStreamScore = 0;

        AVPlayer *player = FFBExtractAVPlayerFromView(view);
        if (player && player.currentItem.asset) {
            cand.avAsset = player.currentItem.asset;
            NSURL *u = FFBLookupURLForAsset(player.currentItem.asset);
            if (u) FFBRecordURLIntoCandidate(u, @"avplayer", cand, &bestStreamScore);
        }

        NSMutableSet<NSValue *> *visited = [NSMutableSet set];
        FFBDeepScanObjectForVideoStreams(view, nil, 0, visited, cand, &bestStreamScore);

        UIResponder *resp = view.nextResponder;
        if ([resp isKindOfClass:UIViewController.class]) {
            FFBDeepScanObjectForVideoStreams(resp, nil, 0, visited, cand, &bestStreamScore);
        }

        if ([cand hasUsableVideo]) {
            CGPoint winCenter = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds));
            CGPoint vCenter = CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis));
            CGFloat dist = hypot(winCenter.x - vCenter.x, winCenter.y - vCenter.y);
            cand.screenAreaScore = area + (CGFloat)(bestStreamScore * 50) - (dist * 120.0);
            [outCandidates addObject:cand];
        }
    }

    for (UIView *sub in view.subviews) {
        FFBScanSubtreeForVideos(sub, win, depth + 1, visitedNodes, outCandidates);
    }
}

static FFBMediaCandidate *FFBFindBestCandidateForReelScope(UIView * _Nullable preferredReelPage) {
    UIWindow *mainWin = FocusFBActiveWindow();
    if (!mainWin) return nil;

    NSMutableArray<FFBMediaCandidate *> *candidates = [NSMutableArray array];

    // 1. Scansiona prima la pagina specifica del Reel su cui l'utente ha premuto Download
    if (preferredReelPage && preferredReelPage.window == mainWin) {
        int visitedPage = 0;
        FFBScanSubtreeForVideos(preferredReelPage, mainWin, 0, &visitedPage, candidates);
    }

    // 2. Fallback sull'intera finestra attiva se il player video risiede in un fratello del layer overlay
    if (candidates.count == 0) {
        int visitedWin = 0;
        FFBScanSubtreeForVideos(mainWin, mainWin, 0, &visitedWin, candidates);
    }

    // 3. Fallback sui player AVPlayer tracciati attivamente
    if (candidates.count == 0) {
        os_unfair_lock_lock(&gPlayerTrackLock);
        NSArray<AVPlayer *> *players = gTrackedAVPlayers ? gTrackedAVPlayers.allObjects : @[];
        os_unfair_lock_unlock(&gPlayerTrackLock);

        for (AVPlayer *p in players) {
            if (!p.currentItem.asset) continue;
            FFBMediaCandidate *pc = [[FFBMediaCandidate alloc] init];
            pc.avAsset = p.currentItem.asset;
            int sc = 0;
            NSURL *u = FFBLookupURLForAsset(p.currentItem.asset);
            if (u) FFBRecordURLIntoCandidate(u, @"trackedPlayer", pc, &sc);
            if ([pc hasUsableVideo]) {
                pc.rawVisibleArea = 200.0 * 200.0;
                pc.screenAreaScore = (p.rate > 0.01f ? 300000.0 : 50000.0) + (CGFloat)(sc * 40);
                pc.capturedAt = CFAbsoluteTimeGetCurrent();
                [candidates addObject:pc];
            }
        }
    }

    if (candidates.count == 0) return nil;

    [candidates sortUsingComparator:^NSComparisonResult(FFBMediaCandidate *a, FFBMediaCandidate *b) {
        if (a.screenAreaScore > b.screenAreaScore) return NSOrderedAscending;
        if (a.screenAreaScore < b.screenAreaScore) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    FFBMediaCandidate *best = candidates.firstObject;
    if (!best.separateAudioURL) {
        for (FFBMediaCandidate *other in candidates) {
            if (other.separateAudioURL) {
                best.separateAudioURL = other.separateAudioURL;
                break;
            }
        }
    }
    return best;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Download MP4 + HLS (.m3u8 fMP4/TS) + Muxing Automatico Audio/Video DASH
// ─────────────────────────────────────────────────────────────────────────────

static NSData *FFBSyncFetchURL(NSURL *url, NSString * _Nullable byteRange) {
    if (!url) return nil;
    if (url.isFileURL) {
        return [NSData dataWithContentsOfURL:url];
    }

    __block NSData *outData = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:35.0];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15" forHTTPHeaderField:@"User-Agent"];
    if (byteRange.length > 0) {
        [req setValue:[NSString stringWithFormat:@"bytes=%@", byteRange] forHTTPHeaderField:@"Range"];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                                 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!err && data.length > 0) {
            if ([resp isKindOfClass:NSHTTPURLResponse.class]) {
                NSInteger code = ((NSHTTPURLResponse *)resp).statusCode;
                if (code >= 200 && code < 300) {
                    outData = data;
                }
            } else {
                outData = data;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(38 * NSEC_PER_SEC)));
    return outData;
}

static NSString *FFBExtractQuotedAttr(NSString *line, NSString *attrName) {
    NSString *needle = [NSString stringWithFormat:@"%@=\"", attrName];
    NSRange r = [line rangeOfString:needle];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r);
    NSRange endQuote = [line rangeOfString:@"\"" options:0 range:NSMakeRange(start, line.length - start)];
    if (endQuote.location == NSNotFound) return nil;
    return [line substringWithRange:NSMakeRange(start, endQuote.location - start)];
}

static NSString *FFBNormalizeHLSByteRangeHeader(NSString *rawRange, long long *ioNextOffset) {
    if (rawRange.length == 0) return nil;
    NSRange at = [rawRange rangeOfString:@"@"];
    if (at.location != NSNotFound) {
        long long len = [[rawRange substringToIndex:at.location] longLongValue];
        long long start = [[rawRange substringFromIndex:NSMaxRange(at)] longLongValue];
        if (len <= 0) return nil;
        if (ioNextOffset) *ioNextOffset = start + len;
        return [NSString stringWithFormat:@"%lld-%lld", start, start + len - 1];
    }
    long long len = [rawRange longLongValue];
    if (len <= 0 || !ioNextOffset) return nil;
    long long start = *ioNextOffset;
    *ioNextOffset = start + len;
    return [NSString stringWithFormat:@"%lld-%lld", start, start + len - 1];
}

static NSURL *FFBDownloadHLSMediaTrack(NSURL *mediaPlaylistURL, NSString *filePrefix) {
    NSData *plData = FFBSyncFetchURL(mediaPlaylistURL, nil);
    if (!plData.length) return nil;
    NSString *text = [[NSString alloc] initWithData:plData encoding:NSUTF8StringEncoding];
    if (!text.length) return nil;

    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSURL *initMapURL = nil;
    NSString *initMapRange = nil;
    long long mapOffset = 0;
    long long segOffset = 0;
    NSString *pendingByteRange = nil;

    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;

        if ([line hasPrefix:@"#EXT-X-MAP:"]) {
            NSString *uri = FFBExtractQuotedAttr(line, @"URI");
            NSString *br = FFBExtractQuotedAttr(line, @"BYTERANGE");
            if (uri.length > 0) {
                initMapURL = [NSURL URLWithString:uri relativeToURL:mediaPlaylistURL].absoluteURL;
                initMapRange = br.length > 0 ? FFBNormalizeHLSByteRangeHeader(br, &mapOffset) : nil;
            }
            continue;
        }
        if ([line hasPrefix:@"#EXT-X-BYTERANGE:"]) {
            NSString *brVal = [[line substringFromIndex:17] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            pendingByteRange = FFBNormalizeHLSByteRangeHeader(brVal, &segOffset);
            continue;
        }
        if ([line hasPrefix:@"#"]) continue;

        NSURL *segURL = [NSURL URLWithString:line relativeToURL:mediaPlaylistURL].absoluteURL;
        if (segURL) {
            [segments addObject:@{
                @"url": segURL,
                @"range": pendingByteRange ?: @""
            }];
        }
        pendingByteRange = nil;
        if (segments.count >= 400) break;
    }

    if (segments.count == 0) return nil;

    BOOL isFMP4 = (initMapURL != nil) ||
                  [segments.firstObject[@"url"] path].lowercaseString.pathExtension.length == 0 ||
                  [[segments.firstObject[@"url"] path].lowercaseString containsString:@"mp4"];
    NSString *ext = isFMP4 ? @"mp4" : @"ts";
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@_%@.%@", filePrefix, [NSUUID UUID].UUIDString, ext]];
    [[NSFileManager defaultManager] createFileAtPath:outPath contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:outPath];
    if (!fh) return nil;

    if (initMapURL) {
        NSData *initBytes = FFBSyncFetchURL(initMapURL, initMapRange);
        if (initBytes.length > 0) {
            [fh writeData:initBytes];
        }
    }

    NSUInteger writtenSegments = 0;
    for (NSDictionary *seg in segments) {
        NSString *r = seg[@"range"];
        NSData *chunk = FFBSyncFetchURL(seg[@"url"], r.length > 0 ? r : nil);
        if (chunk.length > 0) {
            [fh writeData:chunk];
            writtenSegments++;
        }
    }
    [fh closeFile];

    if (writtenSegments == 0) {
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
        return nil;
    }
    return [NSURL fileURLWithPath:outPath];
}

static NSURL *FFBRemuxOrMergeToStandardMP4(NSURL *videoFileURL, NSURL * _Nullable audioFileURL) {
    if (!videoFileURL) return nil;
    AVURLAsset *vAsset = [AVURLAsset URLAssetWithURL:videoFileURL options:nil];
    AVAssetTrack *vTrack = [[vAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!vTrack) {
        return videoFileURL;
    }

    AVMutableComposition *comp = [AVMutableComposition composition];
    CMTime dur = vAsset.duration;
    if (!CMTIME_IS_NUMERIC(dur) || CMTimeGetSeconds(dur) <= 0.05) {
        return videoFileURL;
    }

    AVMutableCompositionTrack *compV = [comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                         preferredTrackID:kCMPersistentTrackID_Invalid];
    [compV insertTimeRange:CMTimeRangeMake(kCMTimeZero, dur) ofTrack:vTrack atTime:kCMTimeZero error:nil];
    compV.preferredTransform = vTrack.preferredTransform;

    AVAssetTrack *aTrack = nil;
    CMTime audioDur = dur;
    if (audioFileURL) {
        AVURLAsset *aAsset = [AVURLAsset URLAssetWithURL:audioFileURL options:nil];
        aTrack = [[aAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (aTrack && CMTIME_IS_NUMERIC(aAsset.duration) && CMTimeGetSeconds(aAsset.duration) > 0.05) {
            audioDur = CMTimeMinimum(dur, aAsset.duration);
        }
    }
    if (!aTrack) {
        aTrack = [[vAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    }
    if (aTrack) {
        AVMutableCompositionTrack *compA = [comp addMutableTrackWithMediaType:AVMediaTypeAudio
                                                             preferredTrackID:kCMPersistentTrackID_Invalid];
        [compA insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioDur) ofTrack:aTrack atTime:kCMTimeZero error:nil];
    }

    NSString *finalPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                           [NSString stringWithFormat:@"FocusFB_Final_%@.mp4", [NSUUID UUID].UUIDString]];
    NSURL *finalURL = [NSURL fileURLWithPath:finalPath];

    NSArray<NSString *> *presets = @[AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality];
    for (NSString *preset in presets) {
        [[NSFileManager defaultManager] removeItemAtURL:finalURL error:nil];
        AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:comp presetName:preset];
        if (!exporter) continue;
        exporter.outputURL = finalURL;
        exporter.outputFileType = AVFileTypeMPEG4;
        exporter.shouldOptimizeForNetworkUse = YES;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [exporter exportAsynchronouslyWithCompletionHandler:^{
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)));

        if (exporter.status == AVAssetExportSessionStatusCompleted &&
            [[NSFileManager defaultManager] fileExistsAtPath:finalPath]) {
            return finalURL;
        }
    }
    return videoFileURL;
}

static NSURL *FFBResolveHLSPlaylistToMP4(NSURL *playlistURL) {
    NSData *data = FFBSyncFetchURL(playlistURL, nil);
    if (!data.length) return nil;
    NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!content.length || ![content containsString:@"#EXTM3U"]) return nil;

    if (![content containsString:@"#EXT-X-STREAM-INF"]) {
        NSURL *rawTrack = FFBDownloadHLSMediaTrack(playlistURL, @"ffb_hls_single");
        if (!rawTrack) return nil;
        NSURL *muxed = FFBRemuxOrMergeToStandardMP4(rawTrack, nil);
        if (muxed && ![muxed isEqual:rawTrack]) {
            [[NSFileManager defaultManager] removeItemAtURL:rawTrack error:nil];
        }
        return muxed;
    }

    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableDictionary<NSString *, NSURL *> *audioGroups = [NSMutableDictionary dictionary];
    NSURL *fallbackAudioURL = nil;

    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"#EXT-X-MEDIA:"] && [line containsString:@"TYPE=AUDIO"]) {
            NSString *gid = FFBExtractQuotedAttr(line, @"GROUP-ID");
            NSString *uri = FFBExtractQuotedAttr(line, @"URI");
            if (uri.length > 0) {
                NSURL *absAudio = [NSURL URLWithString:uri relativeToURL:playlistURL].absoluteURL;
                if (gid.length > 0 && !audioGroups[gid]) {
                    audioGroups[gid] = absAudio;
                }
                if (!fallbackAudioURL) fallbackAudioURL = absAudio;
            }
        }
    }

    long long bestBandwidth = -1;
    NSString *bestAudioGroup = nil;
    NSURL *bestVideoPlaylistURL = nil;

    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![line hasPrefix:@"#EXT-X-STREAM-INF:"]) continue;

        long long bw = 0;
        NSRange bwRange = [line rangeOfString:@"BANDWIDTH="];
        if (bwRange.location != NSNotFound) {
            bw = [[line substringFromIndex:NSMaxRange(bwRange)] longLongValue];
        }
        NSString *aGroup = FFBExtractQuotedAttr(line, @"AUDIO");

        for (NSUInteger j = i + 1; j < lines.count; j++) {
            NSString *uriLine = [lines[j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (uriLine.length == 0) continue;
            if ([uriLine hasPrefix:@"#"]) break;
            if (bw >= bestBandwidth) {
                bestBandwidth = bw;
                bestAudioGroup = aGroup;
                bestVideoPlaylistURL = [NSURL URLWithString:uriLine relativeToURL:playlistURL].absoluteURL;
            }
            i = j;
            break;
        }
    }

    if (!bestVideoPlaylistURL) return nil;
    NSURL *vTrackFile = FFBDownloadHLSMediaTrack(bestVideoPlaylistURL, @"ffb_hls_vid");
    if (!vTrackFile) return nil;

    NSURL *aPlaylist = (bestAudioGroup && audioGroups[bestAudioGroup]) ? audioGroups[bestAudioGroup] : fallbackAudioURL;
    NSURL *aTrackFile = aPlaylist ? FFBDownloadHLSMediaTrack(aPlaylist, @"ffb_hls_aud") : nil;

    NSURL *finalMP4 = FFBRemuxOrMergeToStandardMP4(vTrackFile, aTrackFile);
    if (finalMP4 && ![finalMP4 isEqual:vTrackFile]) {
        [[NSFileManager defaultManager] removeItemAtURL:vTrackFile error:nil];
    }
    if (aTrackFile) {
        [[NSFileManager defaultManager] removeItemAtURL:aTrackFile error:nil];
    }
    return finalMP4;
}

static NSURL *FFBExportAVAssetDirectlyToMP4(AVAsset *asset) {
    if (!asset) return nil;
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"FocusFB_Asset_%@.mp4", [NSUUID UUID].UUIDString]];
    NSURL *outURL = [NSURL fileURLWithPath:outPath];

    NSArray<NSString *> *presets = @[AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality];
    for (NSString *preset in presets) {
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
        AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset presetName:preset];
        if (!exporter) continue;
        exporter.outputURL = outURL;
        exporter.outputFileType = AVFileTypeMPEG4;

        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [exporter exportAsynchronouslyWithCompletionHandler:^{
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)));
        if (exporter.status == AVAssetExportSessionStatusCompleted &&
            [[NSFileManager defaultManager] fileExistsAtPath:outPath]) {
            return outURL;
        }
    }
    return nil;
}

static NSURL *FFBDownloadOrExportCandidateToLocalMP4(FFBMediaCandidate *cand) {
    NSURL *videoURL = cand.hdVideoURL ?: cand.sdVideoURL;
    NSURL *separateAudioURL = cand.separateAudioURL;
    AVAsset *asset = cand.avAsset;

    if (videoURL) {
        NSString *lower = videoURL.absoluteString.lowercaseString;
        if ([lower containsString:@".m3u8"]) {
            NSURL *hlsMP4 = FFBResolveHLSPlaylistToMP4(videoURL);
            if (hlsMP4) return hlsMP4;
        } else {
            NSData *raw = FFBSyncFetchURL(videoURL, nil);
            if (raw.length > 64) {
                if (raw.length < 262144) {
                    NSString *head = [[NSString alloc] initWithBytes:raw.bytes
                                                              length:MIN((NSUInteger)32, raw.length)
                                                            encoding:NSUTF8StringEncoding];
                    if ([head hasPrefix:@"#EXTM3U"]) {
                        NSURL *hlsMP4 = FFBResolveHLSPlaylistToMP4(videoURL);
                        if (hlsMP4) return hlsMP4;
                    }
                }
                NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"FocusFB_Video_%@.mp4", [NSUUID UUID].UUIDString]];
                NSURL *tmpURL = [NSURL fileURLWithPath:tmpPath];
                if ([raw writeToURL:tmpURL atomically:YES]) {
                    AVURLAsset *downloadedAsset = [AVURLAsset URLAssetWithURL:tmpURL options:nil];
                    if ([downloadedAsset tracksWithMediaType:AVMediaTypeAudio].count == 0 && separateAudioURL) {
                        NSData *audData = FFBSyncFetchURL(separateAudioURL, nil);
                        if (audData.length > 128) {
                            NSString *audPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                 [NSString stringWithFormat:@"FocusFB_Audio_%@.mp4", [NSUUID UUID].UUIDString]];
                            NSURL *audURL = [NSURL fileURLWithPath:audPath];
                            if ([audData writeToURL:audURL atomically:YES]) {
                                NSURL *merged = FFBRemuxOrMergeToStandardMP4(tmpURL, audURL);
                                [[NSFileManager defaultManager] removeItemAtURL:audURL error:nil];
                                if (merged && ![merged isEqual:tmpURL]) {
                                    [[NSFileManager defaultManager] removeItemAtURL:tmpURL error:nil];
                                    return merged;
                                }
                            }
                        }
                    }
                    return tmpURL;
                }
            }
        }
    }

    if (asset) {
        if ([asset isKindOfClass:AVComposition.class]) {
            AVComposition *comp = (AVComposition *)asset;
            NSURL *vSegURL = nil;
            NSURL *aSegURL = nil;
            for (AVCompositionTrack *tr in comp.tracks) {
                for (AVCompositionTrackSegment *seg in tr.segments) {
                    if (!seg.isEmpty && seg.sourceURL) {
                        if ([tr.mediaType isEqualToString:AVMediaTypeVideo] && !vSegURL) vSegURL = seg.sourceURL;
                        if ([tr.mediaType isEqualToString:AVMediaTypeAudio] && !aSegURL) aSegURL = seg.sourceURL;
                    }
                }
            }
            if (vSegURL) {
                NSData *vData = FFBSyncFetchURL(vSegURL, nil);
                if (vData.length > 512) {
                    NSURL *vTmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"ffb_comp_v_%@.mp4", [NSUUID UUID].UUIDString]]];
                    [vData writeToURL:vTmp atomically:YES];

                    NSURL *aTmp = nil;
                    if (aSegURL && ![aSegURL isEqual:vSegURL]) {
                        NSData *aData = FFBSyncFetchURL(aSegURL, nil);
                        if (aData.length > 128) {
                            aTmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"ffb_comp_a_%@.mp4", [NSUUID UUID].UUIDString]]];
                            [aData writeToURL:aTmp atomically:YES];
                        }
                    }
                    NSURL *merged = FFBRemuxOrMergeToStandardMP4(vTmp, aTmp);
                    if (merged && ![merged isEqual:vTmp]) [[NSFileManager defaultManager] removeItemAtURL:vTmp error:nil];
                    if (aTmp) [[NSFileManager defaultManager] removeItemAtURL:aTmp error:nil];
                    if (merged) return merged;
                }
            }
        }
        return FFBExportAVAssetDirectlyToMP4(asset);
    }
    return nil;
}

static void FFBPresentShareSheetFallback(NSURL *fileURL) {
    if (!fileURL) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = FocusFBTopMostViewController();
        if (!top) return;
        UIActivityViewController *act = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL]
                                                                          applicationActivities:nil];
        if (act.popoverPresentationController) {
            act.popoverPresentationController.sourceView = top.view;
            act.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        }
        [top presentViewController:act animated:YES completion:nil];
    });
}

static void FFBSaveLocalVideoToPhotos(NSURL *localVideoURL, void (^ _Nullable onCompleted)(BOOL savedOK)) {
    if (!localVideoURL) {
        FocusFBShowToast(FFBLoc(@"DL.Failed"), @"exclamationmark.triangle.fill");
        if (onCompleted) onCompleted(NO);
        return;
    }
    if (!NSClassFromString(@"PHPhotoLibrary") || !NSClassFromString(@"PHAssetChangeRequest")) {
        FFBPresentShareSheetFallback(localVideoURL);
        if (onCompleted) onCompleted(YES);
        return;
    }

    @try {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                FFBPresentShareSheetFallback(localVideoURL);
                if (onCompleted) dispatch_async(dispatch_get_main_queue(), ^{ onCompleted(YES); });
                return;
            }

            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:localVideoURL];
            } completionHandler:^(BOOL success, __unused NSError *error) {
                if (success) {
                    [[NSFileManager defaultManager] removeItemAtURL:localVideoURL error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
                        [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
                        FocusFBShowToast(FFBLoc(@"DL.SavedVideo"), @"checkmark.circle.fill");
                        if (onCompleted) onCompleted(YES);
                    });
                } else {
                    NSURL *remuxed = FFBRemuxOrMergeToStandardMP4(localVideoURL, nil);
                    if (remuxed && ![remuxed isEqual:localVideoURL]) {
                        [[NSFileManager defaultManager] removeItemAtURL:localVideoURL error:nil];
                        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:remuxed];
                        } completionHandler:^(BOOL ok2, __unused NSError *err2) {
                            if (ok2) {
                                [[NSFileManager defaultManager] removeItemAtURL:remuxed error:nil];
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
                                    [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
                                    FocusFBShowToast(FFBLoc(@"DL.SavedVideo"), @"checkmark.circle.fill");
                                    if (onCompleted) onCompleted(YES);
                                });
                            } else {
                                FFBPresentShareSheetFallback(remuxed);
                                if (onCompleted) dispatch_async(dispatch_get_main_queue(), ^{ onCompleted(YES); });
                            }
                        }];
                    } else {
                        FFBPresentShareSheetFallback(localVideoURL);
                        if (onCompleted) dispatch_async(dispatch_get_main_queue(), ^{ onCompleted(YES); });
                    }
                }
            }];
        }];
    } @catch (__unused NSException *ex) {
        FFBPresentShareSheetFallback(localVideoURL);
        if (onCompleted) onCompleted(NO);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Pulsante Download Nativo Sopra l'Icona "Mi piace" nei Reels
// ─────────────────────────────────────────────────────────────────────────────

@interface FFBInlineReelDownloadButton : UIButton
@property (nonatomic, weak, nullable) UIView *reelPageView;
- (void)playDownloadingState:(BOOL)active;
- (void)flashCompletedCheckmark;
@end

@implementation FFBInlineReelDownloadButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.tag = kFFBInlineReelDownloadBtnTag;
        self.backgroundColor = [UIColor clearColor];
        self.adjustsImageWhenHighlighted = NO;
        [self setImage:FFBReelOutlineDownloadImage() forState:UIControlStateNormal];
        self.contentMode = UIViewContentModeCenter;

        // Stessa ombra morbida delle icone bianche Mi piace / Commenta / Condividi / Salva dei Reels
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.44f;
        self.layer.shadowRadius = 2.6f;
        self.layer.shadowOffset = CGSizeMake(0.0, 1.0);

        [self addTarget:self action:@selector(onTouchDownAnim) forControlEvents:UIControlEventTouchDown];
        [self addTarget:self action:@selector(onTouchResetAnim) forControlEvents:UIControlEventTouchCancel | UIControlEventTouchDragExit];
        [self addTarget:self action:@selector(onDownloadTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)onTouchDownAnim {
    [UIView animateWithDuration:0.10 animations:^{
        self.transform = CGAffineTransformMakeScale(0.86, 0.86);
        self.alpha = 0.78;
    }];
}

- (void)onTouchResetAnim {
    [UIView animateWithDuration:0.16 animations:^{
        self.transform = CGAffineTransformIdentity;
        self.alpha = 1.0;
    }];
}

- (void)playDownloadingState:(BOOL)active {
    [self.layer removeAnimationForKey:@"ffb_pulse"];
    if (active) {
        CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
        pulse.fromValue = @(1.0);
        pulse.toValue = @(0.38);
        pulse.duration = 0.55;
        pulse.autoreverses = YES;
        pulse.repeatCount = HUGE_VALF;
        [self.layer addAnimation:pulse forKey:@"ffb_pulse"];
    } else {
        self.layer.opacity = 1.0f;
    }
}

- (void)flashCompletedCheckmark {
    [self playDownloadingState:NO];
    [self setImage:FFBReelOutlineCheckmarkImage() forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setImage:FFBReelOutlineDownloadImage() forState:UIControlStateNormal];
    });
}

- (void)onDownloadTapped {
    [self onTouchResetAnim];
    if (gDownloadInFlight) return;

    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];

    FFBMediaCandidate *cand = FFBFindBestCandidateForReelScope(self.reelPageView);
    if (!cand || ![cand hasUsableVideo]) {
        FocusFBShowToast(FFBLoc(@"DL.NotFound"), @"info.circle.fill");
        return;
    }

    gDownloadInFlight = YES;
    [self playDownloadingState:YES];
    FocusFBShowToast(FFBLoc(@"DL.Downloading"), @"arrow.down.circle.fill");

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *localMP4 = FFBDownloadOrExportCandidateToLocalMP4(cand);
        dispatch_async(dispatch_get_main_queue(), ^{
            gDownloadInFlight = NO;
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf playDownloadingState:NO];
            FFBSaveLocalVideoToPhotos(localMP4, ^(BOOL savedOK) {
                if (savedOK) {
                    [weakSelf flashCompletedCheckmark];
                }
            });
        });
    });
}

@end

// Rilevamento geometrico della colonna destra dei pulsanti di Facebook Reels (Mi piace, Commenti, Condividi, Salva)
@interface FFBActionSlotItem : NSObject
@property (nonatomic, weak) UIView *view;
@property (nonatomic, assign) CGRect rectInPage;
@property (nonatomic, assign) BOOL isGlyphSized;
@end

@implementation FFBActionSlotItem
@end

static void FFBCollectRightEdgeActionViews(UIView *node,
                                           UIView *reelPage,
                                           CGFloat pageW,
                                           CGFloat pageH,
                                           NSUInteger depth,
                                           int *visited,
                                           NSMutableArray<FFBActionSlotItem *> *glyphItems,
                                           NSMutableArray<FFBActionSlotItem *> *boxItems) {
    if (!node || depth > 30 || *visited > 2200) return;
    if (node.hidden || node.alpha <= 0.05 || node.tag == kFFBInlineReelDownloadBtnTag) return;
    (*visited)++;

    if (node != reelPage) {
        CGRect r = [node convertRect:node.bounds toView:reelPage];
        CGFloat w = CGRectGetWidth(r);
        CGFloat h = CGRectGetHeight(r);
        CGFloat midX = CGRectGetMidX(r);
        CGFloat midY = CGRectGetMidY(r);

        // Fascia destra dei Reels (sotto la barra superiore "Reels / Lente / •••", sopra la tab bar)
        if (midX >= pageW - 66.0 && midX <= pageW - 10.0 &&
            midY >= pageH * 0.30 && midY <= pageH - 18.0) {
            if (w >= 16.0 && w <= 38.0 && h >= 16.0 && h <= 38.0 &&
                ![node isKindOfClass:UILabel.class] &&
                (w / h) >= 0.62 && (w / h) <= 1.60) {
                FFBActionSlotItem *it = [[FFBActionSlotItem alloc] init];
                it.view = node;
                it.rectInPage = r;
                it.isGlyphSized = YES;
                [glyphItems addObject:it];
            } else if (w >= 34.0 && w <= 78.0 && h >= 34.0 && h <= 82.0) {
                FFBActionSlotItem *it = [[FFBActionSlotItem alloc] init];
                it.view = node;
                it.rectInPage = r;
                it.isGlyphSized = NO;
                [boxItems addObject:it];
            }
        }
    }

    for (UIView *sub in node.subviews) {
        FFBCollectRightEdgeActionViews(sub, reelPage, pageW, pageH, depth + 1, visited, glyphItems, boxItems);
    }
}

static NSArray<FFBActionSlotItem *> *FFBExtractBestAlignedColumn(NSArray<FFBActionSlotItem *> *rawItems) {
    if (rawItems.count < 3) return @[];

    // 1. Deduplica elementi sovrapposti (entro 22pt verticali e 12pt orizzontali)
    NSArray<FFBActionSlotItem *> *sorted = [rawItems sortedArrayUsingComparator:^NSComparisonResult(FFBActionSlotItem *a, FFBActionSlotItem *b) {
        CGFloat ay = CGRectGetMidY(a.rectInPage);
        CGFloat by = CGRectGetMidY(b.rectInPage);
        if (ay < by) return NSOrderedAscending;
        if (ay > by) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    NSMutableArray<FFBActionSlotItem *> *dedup = [NSMutableArray array];
    for (FFBActionSlotItem *cand in sorted) {
        BOOL merged = NO;
        for (NSUInteger i = 0; i < dedup.count; i++) {
            FFBActionSlotItem *ex = dedup[i];
            if (fabs(CGRectGetMidY(cand.rectInPage) - CGRectGetMidY(ex.rectInPage)) < 24.0 &&
                fabs(CGRectGetMidX(cand.rectInPage) - CGRectGetMidX(ex.rectInPage)) < 14.0) {
                // Preferisci il glifo più vicino a 25x25pt (dimensione esatta delle icone Reels)
                CGFloat candDiff = fabs(CGRectGetWidth(cand.rectInPage) - 25.0) + fabs(CGRectGetHeight(cand.rectInPage) - 25.0);
                CGFloat exDiff = fabs(CGRectGetWidth(ex.rectInPage) - 25.0) + fabs(CGRectGetHeight(ex.rectInPage) - 25.0);
                if (candDiff < exDiff) {
                    dedup[i] = cand;
                }
                merged = YES;
                break;
            }
        }
        if (!merged) {
            [dedup addObject:cand];
        }
    }

    if (dedup.count < 3) return @[];

    // 2. Trova la colonna verticale di almeno 3 icone con lo stesso centro X (±8pt) e passo regolare (42..98pt)
    NSArray<FFBActionSlotItem *> *bestChain = @[];
    for (NSUInteger i = 0; i < dedup.count; i++) {
        FFBActionSlotItem *seed = dedup[i];
        CGFloat refX = CGRectGetMidX(seed.rectInPage);
        NSMutableArray<FFBActionSlotItem *> *chain = [NSMutableArray arrayWithObject:seed];
        FFBActionSlotItem *prev = seed;

        for (NSUInteger j = i + 1; j < dedup.count; j++) {
            FFBActionSlotItem *cur = dedup[j];
            if (fabs(CGRectGetMidX(cur.rectInPage) - refX) > 8.5) continue;
            CGFloat dy = CGRectGetMidY(cur.rectInPage) - CGRectGetMidY(prev.rectInPage);
            if (dy >= 40.0 && dy <= 102.0) {
                [chain addObject:cur];
                prev = cur;
            }
        }
        if (chain.count > bestChain.count) {
            bestChain = chain;
        }
    }

    return (bestChain.count >= 3) ? bestChain : @[];
}

static UIView *FFBChooseInteractiveHostInReelPage(UIView *likeView,
                                                  UIView *reelPage,
                                                  CGRect btnRectInPage) {
    UIView *cur = likeView.superview;
    while (cur != nil) {
        if (cur.userInteractionEnabled && !cur.hidden && cur.alpha > 0.10) {
            CGRect rectInCur = [reelPage convertRect:btnRectInPage toView:cur];
            if (CGRectContainsRect(CGRectInset(cur.bounds, -1.0, -1.0), rectInCur)) {
                BOOL ancestorsValid = YES;
                for (UIView *anc = cur; anc != nil; anc = anc.superview) {
                    if (!anc.userInteractionEnabled || anc.hidden || anc.alpha <= 0.05) {
                        ancestorsValid = NO;
                        break;
                    }
                    CGRect rectInAnc = [reelPage convertRect:btnRectInPage toView:anc];
                    if (!CGRectContainsRect(CGRectInset(anc.bounds, -2.0, -2.0), rectInAnc)) {
                        ancestorsValid = NO;
                        break;
                    }
                    if (anc == reelPage) break;
                }
                if (ancestorsValid) {
                    return cur;
                }
            }
        }
        if (cur == reelPage) break;
        cur = cur.superview;
    }
    return reelPage.userInteractionEnabled ? reelPage : nil;
}

static void FFBAttachOrAlignDownloadButtonInReelPage(UIView *reelPage) {
    if (!reelPage || reelPage.hidden || reelPage.alpha <= 0.05 || !reelPage.window) return;

    CGFloat pageW = CGRectGetWidth(reelPage.bounds);
    CGFloat pageH = CGRectGetHeight(reelPage.bounds);
    if (pageW < 260.0 || pageH < 420.0) return;

    // Assicurati che questa pagina contenga effettivamente una superficie video
    if (!FFBSubtreeContainsAnyVideoSurface(reelPage, 0)) {
        UIView *stale = [reelPage viewWithTag:kFFBInlineReelDownloadBtnTag];
        if (stale) [stale removeFromSuperview];
        return;
    }

    NSMutableArray<FFBActionSlotItem *> *glyphs = [NSMutableArray array];
    NSMutableArray<FFBActionSlotItem *> *boxes = [NSMutableArray array];
    int visited = 0;
    FFBCollectRightEdgeActionViews(reelPage, reelPage, pageW, pageH, 0, &visited, glyphs, boxes);

    NSArray<FFBActionSlotItem *> *col = FFBExtractBestAlignedColumn(glyphs);
    if (col.count < 3) {
        col = FFBExtractBestAlignedColumn(boxes);
    }
    if (col.count < 3) return;

    FFBActionSlotItem *likeSlot = col[0];
    FFBActionSlotItem *commentSlot = col[1];
    if (!likeSlot.view) return;

    CGFloat likeCenterX = CGRectGetMidX(likeSlot.rectInPage);
    CGFloat likeIconCenterY = likeSlot.isGlyphSized
                              ? CGRectGetMidY(likeSlot.rectInPage)
                              : (CGRectGetMinY(likeSlot.rectInPage) + 15.0);
    CGFloat commentIconCenterY = commentSlot.isGlyphSized
                                 ? CGRectGetMidY(commentSlot.rectInPage)
                                 : (CGRectGetMinY(commentSlot.rectInPage) + 15.0);

    CGFloat rawStepY = commentIconCenterY - likeIconCenterY;
    CGFloat clampedStepY = MAX(52.0, MIN(82.0, rawStepY));

    // Posiziona l'icona di download sopra l'icona Mi piace con la stessa distanza visiva delle altre icone
    CGFloat targetCenterY = likeIconCenterY - round(clampedStepY * 0.85);
    if (targetCenterY < 96.0) return; // Non sovrapporre mai la barra in alto ("Reels / Lente / •••")

    CGFloat hitSize = 48.0;
    CGRect btnRectInPage = CGRectMake(round(likeCenterX - hitSize * 0.5),
                                      round(targetCenterY - hitSize * 0.5),
                                      hitSize,
                                      hitSize);

    UIView *hostView = FFBChooseInteractiveHostInReelPage(likeSlot.view, reelPage, btnRectInPage);
    if (!hostView) return;

    CGRect btnRectInHost = [reelPage convertRect:btnRectInPage toView:hostView];

    FFBInlineReelDownloadButton *existingBtn = (FFBInlineReelDownloadButton *)[reelPage viewWithTag:kFFBInlineReelDownloadBtnTag];
    if (existingBtn && existingBtn.superview != hostView) {
        [existingBtn removeFromSuperview];
        existingBtn = nil;
    }

    if (!existingBtn) {
        existingBtn = [[FFBInlineReelDownloadButton alloc] initWithFrame:btnRectInHost];
        existingBtn.reelPageView = reelPage;
        [hostView addSubview:existingBtn];
        if (!gMountedReelButtons) {
            gMountedReelButtons = [NSHashTable weakObjectsHashTable];
        }
        [gMountedReelButtons addObject:existingBtn];
    } else {
        existingBtn.reelPageView = reelPage;
        if (fabs(CGRectGetMidX(existingBtn.frame) - CGRectGetMidX(btnRectInHost)) > 0.5 ||
            fabs(CGRectGetMidY(existingBtn.frame) - CGRectGetMidY(btnRectInHost)) > 0.5) {
            existingBtn.frame = btnRectInHost;
        }
        [hostView bringSubviewToFront:existingBtn];
    }
}

static void FFBRemoveAllMountedReelButtons(void) {
    if (!gMountedReelButtons) return;
    for (UIButton *btn in gMountedReelButtons.allObjects) {
        [btn removeFromSuperview];
    }
    [gMountedReelButtons removeAllObjects];
}

static BOOL FFBCollectionViewLooksLikeReelsPager(UICollectionView *cv) {
    if (!cv || cv.hidden || cv.alpha <= 0.05 || !cv.window) return NO;
    CGFloat winW = CGRectGetWidth(cv.window.bounds);
    CGFloat winH = CGRectGetHeight(cv.window.bounds);
    if (CGRectGetWidth(cv.bounds) < winW * 0.88 || CGRectGetHeight(cv.bounds) < winH * 0.68) {
        return NO;
    }

    NSNumber *cached = objc_getAssociatedObject(cv, &kIsReelsCollectionCacheKey);
    if (cached != nil) {
        return cached.boolValue;
    }

    UIResponder *resp = cv.nextResponder;
    int hops = 0;
    while (resp && hops < 10) {
        if ([resp isKindOfClass:UIViewController.class]) {
            NSString *cls = NSStringFromClass(((UIViewController *)resp).class).lowercaseString ?: @"";
            if ([cls containsString:@"marketplace"] ||
                [cls containsString:@"newsfeed"] ||
                [cls containsString:@"mainfeed"]) {
                objc_setAssociatedObject(cv, &kIsReelsCollectionCacheKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return NO;
            }
            if ([cls containsString:@"reels"] ||
                [cls containsString:@"shorts"] ||
                [cls containsString:@"videohome"] ||
                [cls containsString:@"unifiedplayer"] ||
                [cls containsString:@"tahoe"] ||
                [cls containsString:@"watch"]) {
                objc_setAssociatedObject(cv, &kIsReelsCollectionCacheKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return YES;
            }
        }
        resp = resp.nextResponder;
        hops++;
    }

    if (cv.isPagingEnabled && !cv.alwaysBounceHorizontal) {
        objc_setAssociatedObject(cv, &kIsReelsCollectionCacheKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    return NO;
}

static void FFBFindVisibleReelContainersInTree(UIView *node,
                                               UIWindow *win,
                                               NSUInteger depth,
                                               NSMutableArray<UIView *> *outPages) {
    if (!node || depth > 14 || node.hidden || node.alpha <= 0.05) return;
    if ([node isKindOfClass:UICollectionView.class]) {
        UICollectionView *cv = (UICollectionView *)node;
        if (FFBCollectionViewLooksLikeReelsPager(cv)) {
            for (UICollectionViewCell *cell in cv.visibleCells) {
                if (CGRectGetHeight(cell.bounds) >= CGRectGetHeight(win.bounds) * 0.65) {
                    [outPages addObject:cell];
                }
            }
            return;
        }
    }

    // Fallback se il player Reels usa una UIScrollView paginata non-UICollectionView
    if ([node isKindOfClass:UIScrollView.class] && ![node isKindOfClass:UICollectionView.class] && ![node isKindOfClass:UITableView.class]) {
        UIScrollView *sv = (UIScrollView *)node;
        if (sv.isPagingEnabled &&
            CGRectGetWidth(sv.bounds) >= CGRectGetWidth(win.bounds) * 0.88 &&
            CGRectGetHeight(sv.bounds) >= CGRectGetHeight(win.bounds) * 0.68) {
            for (UIView *sub in sv.subviews) {
                if (!sub.hidden && sub.alpha > 0.05 &&
                    CGRectGetWidth(sub.bounds) >= CGRectGetWidth(win.bounds) * 0.88 &&
                    CGRectGetHeight(sub.bounds) >= CGRectGetHeight(win.bounds) * 0.65) {
                    CGRect rInWin = [sub convertRect:sub.bounds toView:win];
                    CGRect inter = CGRectIntersection(rInWin, win.bounds);
                    if (!CGRectIsNull(inter) && CGRectGetHeight(inter) >= 180.0) {
                        [outPages addObject:sub];
                    }
                }
            }
            if (outPages.count > 0) return;
        }
    }

    for (UIView *sub in node.subviews) {
        FFBFindVisibleReelContainersInTree(sub, win, depth + 1, outPages);
    }
}

void FocusFBMediaDownloaderOnScrollLayout(UIScrollView *scrollView) {
    if (!gMediaDownloaderReady || !scrollView) return;

    // Controllo istantaneo O(1): Marketplace e Feed non sono MAI pagingEnabled!
    if ([scrollView isKindOfClass:UICollectionView.class]) {
        UICollectionView *cv = (UICollectionView *)scrollView;
        if (!FFBCollectionViewLooksLikeReelsPager(cv)) return;
        FocusFBPrefs *prefs = [FocusFBPrefs shared];
        if (!prefs.enabled || !prefs.enableMediaDownload) return;

        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        for (UICollectionViewCell *cell in cv.visibleCells) {
            if (CGRectGetHeight(cell.bounds) < 400.0) continue;
            UIView *existing = [cell viewWithTag:kFFBInlineReelDownloadBtnTag];
            NSNumber *lastSync = objc_getAssociatedObject(cell, &kLastCellBtnSyncTimeKey);
            if (existing && existing.superview && lastSync && (now - lastSync.doubleValue) < 0.30) {
                continue;
            }
            objc_setAssociatedObject(cell, &kLastCellBtnSyncTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            FFBAttachOrAlignDownloadButtonInReelPage(cell);
        }
        return;
    }

    if (!scrollView.isPagingEnabled || scrollView.alwaysBounceHorizontal) return;
    if (!scrollView.window || CGRectGetHeight(scrollView.bounds) < 420.0 || CGRectGetWidth(scrollView.bounds) < 260.0) return;

    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.enableMediaDownload) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSNumber *lastSVSync = objc_getAssociatedObject(scrollView, &kLastCellBtnSyncTimeKey);
    if (lastSVSync && (now - lastSVSync.doubleValue) < 0.22) return;
    objc_setAssociatedObject(scrollView, &kLastCellBtnSyncTimeKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIWindow *win = scrollView.window;
    for (UIView *sub in scrollView.subviews) {
        if (sub.hidden || sub.alpha <= 0.05) continue;
        if (CGRectGetWidth(sub.bounds) >= CGRectGetWidth(win.bounds) * 0.88 &&
            CGRectGetHeight(sub.bounds) >= CGRectGetHeight(win.bounds) * 0.65) {
            CGRect rInWin = [sub convertRect:sub.bounds toView:win];
            CGRect inter = CGRectIntersection(rInWin, win.bounds);
            if (!CGRectIsNull(inter) && CGRectGetHeight(inter) >= 180.0) {
                FFBAttachOrAlignDownloadButtonInReelPage(sub);
            }
        }
    }
}

void FocusFBMediaDownloaderSyncUI(void) {
    if (!gMediaDownloaderReady) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FocusFBMediaDownloaderSyncUI();
        });
        return;
    }

    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.enableMediaDownload) {
        FFBRemoveAllMountedReelButtons();
        return;
    }

    UIWindow *win = FocusFBActiveWindow();
    if (!win || !win.rootViewController || !win.rootViewController.isViewLoaded) return;

    NSMutableArray<UIView *> *reelPages = [NSMutableArray array];
    FFBFindVisibleReelContainersInTree(win.rootViewController.view, win, 0, reelPages);

    // Se un player Reels full-screen è presentato modalmente sopra rootViewController
    UIViewController *pres = win.rootViewController.presentedViewController;
    while (pres && !pres.isBeingDismissed) {
        if (pres.isViewLoaded && ![pres isKindOfClass:FocusFBSettingsViewController.class] &&
            ![pres isKindOfClass:UIAlertController.class] &&
            ![pres isKindOfClass:UIActivityViewController.class]) {
            FFBFindVisibleReelContainersInTree(pres.view, win, 0, reelPages);
        }
        pres = pres.presentedViewController;
    }

    for (UIView *page in reelPages) {
        FFBAttachOrAlignDownloadButtonInReelPage(page);
    }
}

static void FFBScheduleReelButtonSyncBurst(void) {
    if (!gMediaDownloaderReady) return;
    NSArray<NSNumber *> *delays = @[@(0.03), @(0.18), @(0.45)];
    for (NSNumber *d in delays) {
        double sec = d.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FocusFBMediaDownloaderSyncUI();
        });
    }
}

void FocusFBNotifyMediaControllerTransition(UIViewController *vc) {
    if (!gMediaDownloaderReady || !vc) return;
    if ([vc isKindOfClass:FocusFBSettingsViewController.class] ||
        [vc isKindOfClass:UIAlertController.class] ||
        [vc isKindOfClass:UIActivityViewController.class]) {
        return;
    }
    FFBScheduleReelButtonSyncBurst();
}

static void FFBHook_AVPlayer_replaceCurrentItem(id self, SEL _cmd, AVPlayerItem *item) {
    if (gOrigAVPlayerReplaceItem) {
        gOrigAVPlayerReplaceItem(self, _cmd, item);
    }
    if (self && item && [self isKindOfClass:AVPlayer.class]) {
        os_unfair_lock_lock(&gPlayerTrackLock);
        if (!gTrackedAVPlayers) {
            gTrackedAVPlayers = [NSHashTable weakObjectsHashTable];
        }
        [gTrackedAVPlayers addObject:(AVPlayer *)self];
        os_unfair_lock_unlock(&gPlayerTrackLock);

        if (gMediaDownloaderReady) {
            FFBScheduleReelButtonSyncBurst();
        }
    }
}

static BOOL FFBMediaHookMethod(Class cls, SEL sel, IMP newIMP, IMP *origOut) {
    if (!cls || !sel || !newIMP) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!orig || !types || orig == newIMP) return NO;
    if (origOut && *origOut == NULL) *origOut = orig;
    if (!class_addMethod(cls, sel, newIMP, types)) {
        method_setImplementation(m, newIMP);
    }
    return YES;
}

static void FFBActivateMediaDownloaderNow(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!gInstalledPlayerHook) {
            gInstalledPlayerHook = FFBMediaHookMethod(AVPlayer.class,
                                                      @selector(replaceCurrentItemWithPlayerItem:),
                                                      (IMP)FFBHook_AVPlayer_replaceCurrentItem,
                                                      (IMP *)&gOrigAVPlayerReplaceItem);
        }
        gMediaDownloaderReady = YES;
        FocusFBMediaDownloaderSyncUI();
    });
}

void FocusFBInstallMediaDownloader(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            FFBActivateMediaDownloaderNow();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                FFBActivateMediaDownloaderNow();
            }
        });

        [nc addObserverForName:FocusFBPreferencesDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            FocusFBMediaDownloaderSyncUI();
        }];

        [nc addObserverForName:AVPlayerItemNewAccessLogEntryNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            FFBScheduleReelButtonSyncBurst();
        }];
    });
}
