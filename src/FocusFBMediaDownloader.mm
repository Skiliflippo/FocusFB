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

static const NSInteger kFFBQuickDownloadBtnTag = 0x70C5D1;
static const NSInteger kFFBShareSheetBarTag    = 0x70C5D2;

typedef void (*FFBAVPlayerReplaceItemIMP)(id, SEL, AVPlayerItem *);
typedef void (*FFBWindowDidAddSubviewIMP)(id, SEL, UIView *);
typedef void (*FFBAppSendEventMediaIMP)(id, SEL, UIEvent *);

static FFBAVPlayerReplaceItemIMP gOrigAVPlayerReplaceItem = NULL;
static FFBWindowDidAddSubviewIMP gOrigWindowDidAddSubview = NULL;
static FFBAppSendEventMediaIMP   gOrigAppSendEventMedia   = NULL;

static BOOL gInstalledPlayerHook    = NO;
static BOOL gInstalledWindowAddHook = NO;
static BOOL gInstalledSendEventHook = NO;
static BOOL gMediaDownloaderReady   = NO;
static BOOL gDownloadInFlight       = NO;
static CGPoint gLastTouchDownPt     = {0.0, 0.0};
static uint64_t gTouchSeqID         = 0;

static os_unfair_lock gPlayerTrackLock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<AVPlayer *> *gTrackedAVPlayers = nil;

static NSTimer *gQuickBtnVisibilityTimer = nil;
static NSTimer *gShareSheetFollowTimer   = nil;

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
// 1. Modello Candidato Video / Reel / Storia Video
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

static FFBMediaCandidate *gRecentActiveVideoCandidate = nil;

// ─────────────────────────────────────────────────────────────────────────────
// 2. Risoluzione URL Video, Analisi Header DASH `efg=` & Scansione Profonda FNF/Reels
// ─────────────────────────────────────────────────────────────────────────────

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

    // Escludi sempre immagini statiche / avatar / anteprime
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

// Scansione ivar a 3 livelli (eseguita SOLO su apertura menu Condividi o tap Download, zero costo durante lo scroll!)
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

    // Selettori diretti noti su FBVideoPlaybackController / FBVideoPlaybackItem / FBSnacksVideoManager
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
                                    UIView * _Nullable excludedSheetSubtree,
                                    NSUInteger depth,
                                    int *visitedNodes,
                                    NSMutableArray<FFBMediaCandidate *> *outCandidates) {
    if (!view || depth > 44 || *visitedNodes > 4500) return;
    if (view == excludedSheetSubtree || view.hidden || view.alpha <= 0.02) return;
    if (view.tag == kFFBQuickDownloadBtnTag || view.tag == kFFBShareSheetBarTag) return;
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

        // Controlla anche il UIViewController proprietario della vista (es. FBSnacksBucketViewController)
        UIResponder *resp = view.nextResponder;
        if ([resp isKindOfClass:UIViewController.class]) {
            FFBDeepScanObjectForVideoStreams(resp, nil, 0, visited, cand, &bestStreamScore);
        }

        if ([cand hasUsableVideo]) {
            // Bonus per il video più centrato sullo schermo (evita Reel pre-caricati fuori vista)
            CGPoint winCenter = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds));
            CGPoint vCenter = CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis));
            CGFloat dist = hypot(winCenter.x - vCenter.x, winCenter.y - vCenter.y);
            cand.screenAreaScore = area + (CGFloat)(bestStreamScore * 50) - (dist * 120.0);
            [outCandidates addObject:cand];
        }
    }

    for (UIView *sub in view.subviews) {
        FFBScanSubtreeForVideos(sub, win, excludedSheetSubtree, depth + 1, visitedNodes, outCandidates);
    }
}

static void FFBCollectVideoFromStoryControllers(UIViewController *vc,
                                                NSUInteger depth,
                                                NSMutableArray<FFBMediaCandidate *> *outCandidates) {
    if (!vc || depth > 12) return;
    NSString *clsName = NSStringFromClass(vc.class) ?: @"";
    if ([clsName containsString:@"SnacksBucketViewController"] ||
        [clsName containsString:@"SnacksMediaContainer"] ||
        [clsName containsString:@"SnacksThreadContainer"]) {
        if (vc.isViewLoaded && !vc.view.hidden && vc.view.window) {
            FFBMediaCandidate *cand = [[FFBMediaCandidate alloc] init];
            int bestScore = 0;
            NSMutableSet<NSValue *> *visited = [NSMutableSet set];
            FFBDeepScanObjectForVideoStreams(vc, nil, 0, visited, cand, &bestScore);
            if ([cand hasUsableVideo]) {
                CGRect b = vc.view.bounds;
                cand.rawVisibleArea = CGRectGetWidth(b) * CGRectGetHeight(b);
                cand.screenAreaScore = cand.rawVisibleArea + (CGFloat)(bestScore * 50);
                cand.capturedAt = CFAbsoluteTimeGetCurrent();
                [outCandidates addObject:cand];
            }
        }
    }
    for (UIViewController *child in vc.childViewControllers) {
        FFBCollectVideoFromStoryControllers(child, depth + 1, outCandidates);
    }
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        FFBCollectVideoFromStoryControllers(vc.presentedViewController, depth + 1, outCandidates);
    }
}

static FFBMediaCandidate *FFBFindActiveVideoOnScreen(UIView * _Nullable excludedSheetSubtree) {
    UIWindow *mainWin = FocusFBActiveWindow();
    if (!mainWin) return nil;

    NSMutableArray<FFBMediaCandidate *> *candidates = [NSMutableArray array];
    int visitedNodes = 0;
    FFBScanSubtreeForVideos(mainWin, mainWin, excludedSheetSubtree, 0, &visitedNodes, candidates);

    if (FocusFBIsStoryViewerVisibleNow() && mainWin.rootViewController) {
        FFBCollectVideoFromStoryControllers(mainWin.rootViewController, 0, candidates);
    }

    // Fallback sui player AVPlayer tracciati attivamente
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

    if (candidates.count == 0) {
        if (excludedSheetSubtree != nil && gRecentActiveVideoCandidate &&
            (CFAbsoluteTimeGetCurrent() - gRecentActiveVideoCandidate.capturedAt) < 20.0) {
            return gRecentActiveVideoCandidate;
        }
        return nil;
    }

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
    gRecentActiveVideoCandidate = best;
    return best;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Downloader MP4 + HLS (.m3u8 fMP4/TS) + Muxing Automatico Audio/Video DASH
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

static NSURL *FFBDownloadOrExportCandidateToLocalMP4(FFBMediaCandidate *cand, BOOL preferSD) {
    NSURL *videoURL = (preferSD && cand.sdVideoURL) ? cand.sdVideoURL : (cand.hdVideoURL ?: cand.sdVideoURL);
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
                    // Se il flusso DASH scaricato non contiene traccia audio e abbiamo l'URL audio separato, uniscili!
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

// ─────────────────────────────────────────────────────────────────────────────
// 4. Salvataggio nel Rullino iOS (PHPhotoLibrary + Fallback Share Sheet)
// ─────────────────────────────────────────────────────────────────────────────

static void FFBPresentShareSheetForItem(id item) {
    if (!item) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = FocusFBTopMostViewController();
        if (!top) return;
        UIActivityViewController *act = [[UIActivityViewController alloc] initWithActivityItems:@[item]
                                                                          applicationActivities:nil];
        if (act.popoverPresentationController) {
            act.popoverPresentationController.sourceView = top.view;
            act.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(top.view.bounds), CGRectGetMidY(top.view.bounds), 1, 1);
        }
        [top presentViewController:act animated:YES completion:nil];
    });
}

static void FFBSaveLocalVideoFileToCameraRoll(NSURL *localVideoURL, BOOL shareInstead) {
    if (!localVideoURL) {
        FocusFBShowToast(FFBLoc(@"DL.Failed"), @"exclamationmark.triangle.fill");
        return;
    }
    if (shareInstead || !NSClassFromString(@"PHPhotoLibrary") || !NSClassFromString(@"PHAssetChangeRequest")) {
        FFBPresentShareSheetForItem(localVideoURL);
        return;
    }

    @try {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                FFBPresentShareSheetForItem(localVideoURL);
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
                                });
                            } else {
                                FFBPresentShareSheetForItem(remuxed);
                            }
                        }];
                    } else {
                        FFBPresentShareSheetForItem(localVideoURL);
                    }
                }
            }];
        }];
    } @catch (__unused NSException *ex) {
        FFBPresentShareSheetForItem(localVideoURL);
    }
}

static void FFBPerformCandidateDownload(FFBMediaCandidate *cand, BOOL preferSD, BOOL shareInstead) {
    if (gDownloadInFlight) return;
    if (!cand || ![cand hasUsableVideo]) {
        FocusFBShowToast(FFBLoc(@"DL.NotFound"), @"info.circle.fill");
        return;
    }

    gDownloadInFlight = YES;
    FocusFBShowToast(FFBLoc(@"DL.Downloading"), @"arrow.down.circle.fill");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *localMP4 = FFBDownloadOrExportCandidateToLocalMP4(cand, preferSD);
        dispatch_async(dispatch_get_main_queue(), ^{
            gDownloadInFlight = NO;
            FFBSaveLocalVideoFileToCameraRoll(localMP4, shareInstead);
        });
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Barra "Scarica video" Integrata nel Menu Condividi / Opzioni di Facebook
//    (Quando fai long-press su un Reel o tocchi Condividi / ••• su Reel o Video!)
// ─────────────────────────────────────────────────────────────────────────────

@interface FFBShareSheetDownloadBar : UIView
@property (nonatomic, strong, nullable) FFBMediaCandidate *videoCandidate;
@property (nonatomic, weak, nullable) UIView *trackedSheetCard;
- (void)updatePositionRelativeToSheetCard;
@end

@implementation FFBShareSheetDownloadBar {
    UIVisualEffectView *_blurView;
    UIButton *_mainDownloadBtn;
    UIButton *_shareFileBtn;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.tag = kFFBShareSheetBarTag;
        self.backgroundColor = [UIColor clearColor];

        _blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.layer.cornerRadius = 16.0;
        _blurView.layer.borderWidth = 0.8;
        _blurView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
        _blurView.clipsToBounds = YES;
        [self addSubview:_blurView];

        _mainDownloadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _mainDownloadBtn.translatesAutoresizingMaskIntoConstraints = NO;
        _mainDownloadBtn.tintColor = [UIColor whiteColor];
        _mainDownloadBtn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
        _mainDownloadBtn.contentEdgeInsets = UIEdgeInsetsMake(0, 16, 0, 10);

        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:18.0 weight:UIImageSymbolWeightBold];
        UIImage *dlIcon = [UIImage systemImageNamed:@"arrow.down.circle.fill" withConfiguration:symCfg];
        [_mainDownloadBtn setImage:dlIcon forState:UIControlStateNormal];

        NSString *labelText = [NSString stringWithFormat:@"  %@  •  %@",
                               FFBLoc(@"DL.ShareBarAction"),
                               FFBLoc(@"DL.ShareBarSub")];
        [_mainDownloadBtn setTitle:labelText forState:UIControlStateNormal];
        _mainDownloadBtn.titleLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightSemibold];
        _mainDownloadBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [_mainDownloadBtn addTarget:self action:@selector(handleMainDownloadTap) forControlEvents:UIControlEventTouchUpInside];

        _shareFileBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _shareFileBtn.translatesAutoresizingMaskIntoConstraints = NO;
        _shareFileBtn.tintColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        UIImageSymbolConfiguration *shareCfg = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
        [_shareFileBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up" withConfiguration:shareCfg]
                       forState:UIControlStateNormal];
        [_shareFileBtn addTarget:self action:@selector(handleShareFileTap) forControlEvents:UIControlEventTouchUpInside];

        UIView *divider = [[UIView alloc] init];
        divider.translatesAutoresizingMaskIntoConstraints = NO;
        divider.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.15];

        [_blurView.contentView addSubview:_mainDownloadBtn];
        [_blurView.contentView addSubview:divider];
        [_blurView.contentView addSubview:_shareFileBtn];

        [NSLayoutConstraint activateConstraints:@[
            [_mainDownloadBtn.leadingAnchor constraintEqualToAnchor:_blurView.contentView.leadingAnchor],
            [_mainDownloadBtn.topAnchor constraintEqualToAnchor:_blurView.contentView.topAnchor],
            [_mainDownloadBtn.bottomAnchor constraintEqualToAnchor:_blurView.contentView.bottomAnchor],
            [_mainDownloadBtn.trailingAnchor constraintEqualToAnchor:divider.leadingAnchor],

            [divider.widthAnchor constraintEqualToConstant:0.8],
            [divider.topAnchor constraintEqualToAnchor:_blurView.contentView.topAnchor constant:11.0],
            [divider.bottomAnchor constraintEqualToAnchor:_blurView.contentView.bottomAnchor constant:-11.0],
            [divider.trailingAnchor constraintEqualToAnchor:_shareFileBtn.leadingAnchor],

            [_shareFileBtn.widthAnchor constraintEqualToConstant:50.0],
            [_shareFileBtn.trailingAnchor constraintEqualToAnchor:_blurView.contentView.trailingAnchor],
            [_shareFileBtn.topAnchor constraintEqualToAnchor:_blurView.contentView.topAnchor],
            [_shareFileBtn.bottomAnchor constraintEqualToAnchor:_blurView.contentView.bottomAnchor],
        ]];
    }
    return self;
}

// Impedisce al UITapGestureRecognizer dello sfondo oscurato di intercettare il tocco sul nostro pulsante
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.view != self &&
        gestureRecognizer.view != _mainDownloadBtn &&
        gestureRecognizer.view != _shareFileBtn) {
        return NO;
    }
    return [super gestureRecognizerShouldBegin:gestureRecognizer];
}

- (void)updatePositionRelativeToSheetCard {
    UIView *host = self.superview;
    UIView *card = self.trackedSheetCard;
    if (!host || !card || !card.window || card.hidden || card.alpha <= 0.05) {
        [self removeFromSuperview];
        return;
    }

    CGRect cardRect = [card convertRect:card.bounds toView:host];
    CGFloat hostW = CGRectGetWidth(host.bounds);
    CGFloat hostH = CGRectGetHeight(host.bounds);
    if (CGRectGetMinY(cardRect) >= hostH - 40.0 || CGRectGetWidth(cardRect) < 180.0) {
        self.alpha = 0.0;
        return;
    }
    self.alpha = 1.0;

    CGFloat barH = 50.0;
    CGFloat barW = MIN(hostW - 24.0, CGRectGetWidth(cardRect) - 16.0);
    CGFloat barX = floor((hostW - barW) * 0.5);
    CGFloat safeTop = host.safeAreaInsets.top > 0 ? host.safeAreaInsets.top : 50.0;

    CGFloat desiredY = CGRectGetMinY(cardRect) - barH - 8.0;
    if (desiredY < safeTop + 6.0) {
        desiredY = safeTop + 6.0;
    }
    self.frame = CGRectMake(barX, desiredY, barW, barH);
    [host bringSubviewToFront:self];
}

- (FFBMediaCandidate *)resolvedCandidateNow {
    FFBMediaCandidate *fresh = FFBFindActiveVideoOnScreen(self.superview);
    if (fresh && [fresh hasUsableVideo]) {
        self.videoCandidate = fresh;
        return fresh;
    }
    return self.videoCandidate;
}

- (void)handleMainDownloadTap {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];
    FFBMediaCandidate *cand = [self resolvedCandidateNow];
    FFBPerformCandidateDownload(cand, NO, NO);
}

- (void)handleShareFileTap {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen impactOccurred];
    FFBMediaCandidate *cand = [self resolvedCandidateNow];
    FFBPerformCandidateDownload(cand, NO, YES);
}

@end

// Riconosce il Bottom Sheet / Menu Condividi nativo di Facebook (CDSBottomSheet, MDSBottomSheet, FBBottomSheet, Bloks, UITransitionView)
static UIView *FFBFindBottomSheetCardInContainer(UIView *container, UIWindow *win, NSUInteger depth) {
    if (!container || depth > 8 || container.hidden || container.alpha <= 0.05) return nil;
    if (container.tag == kFFBShareSheetBarTag || container.tag == kFFBQuickDownloadBtnTag) return nil;

    CGFloat winW = CGRectGetWidth(win.bounds);
    CGFloat winH = CGRectGetHeight(win.bounds);
    CGRect r = [container convertRect:container.bounds toView:win];

    // Escludi schede di FocusFB, alert di sistema e barra tab inferiore (<= 110pt)
    NSString *clsName = NSStringFromClass(object_getClass(container)) ?: @"";
    if ([clsName hasPrefix:@"FocusFB"] || [clsName hasPrefix:@"FFB"] || [clsName containsString:@"AlertController"]) {
        return nil;
    }

    BOOL anchoredBottom = (CGRectGetMaxY(r) >= winH - 18.0);
    BOOL wideEnough = (CGRectGetWidth(r) >= winW * 0.88);
    CGFloat cardH = CGRectGetHeight(r);
    BOOL sheetHeight = (CGRectGetMinY(r) >= 48.0 && cardH >= 155.0 && cardH <= winH - 48.0);

    if (depth >= 1 && anchoredBottom && wideEnough && sheetHeight) {
        BOOL hasCardVisuals = (container.backgroundColor != nil && CGColorGetAlpha(container.backgroundColor.CGColor) > 0.35) ||
                              container.layer.cornerRadius >= 8.0 ||
                              container.clipsToBounds ||
                              [clsName containsString:@"Sheet"] ||
                              [clsName containsString:@"Drawer"] ||
                              [clsName containsString:@"Modal"];
        if (hasCardVisuals) {
            return container;
        }
    }

    for (UIView *sub in [container.subviews reverseObjectEnumerator]) {
        UIView *found = FFBFindBottomSheetCardInContainer(sub, win, depth + 1);
        if (found) return found;
    }
    return nil;
}

static BOOL FFBViewLooksLikeDimmedBackdrop(UIView *v, UIWindow *win) {
    if (!v || v.hidden || v.alpha <= 0.05) return NO;
    CGRect r = [v convertRect:v.bounds toView:win];
    if (CGRectGetWidth(r) < CGRectGetWidth(win.bounds) * 0.92 ||
        CGRectGetHeight(r) < CGRectGetHeight(win.bounds) * 0.92) {
        return NO;
    }
    if (v.backgroundColor) {
        CGFloat red = 0, green = 0, blue = 0, alpha = 0;
        if ([v.backgroundColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
            CGFloat effAlpha = alpha * v.alpha;
            if (red < 0.25 && green < 0.25 && blue < 0.28 && effAlpha >= 0.12 && effAlpha <= 0.90) {
                return YES;
            }
        }
    }
    NSString *cls = NSStringFromClass(object_getClass(v)) ?: @"";
    return ([cls containsString:@"Dimming"] ||
            [cls containsString:@"Backdrop"] ||
            [cls containsString:@"Scrim"]);
}

static UIViewController *FFBFindSheetControllerInTree(UIViewController *vc, NSUInteger depth) {
    if (!vc || depth > 12 || vc.isBeingDismissed) return nil;
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        UIViewController *foundPres = FFBFindSheetControllerInTree(vc.presentedViewController, depth + 1);
        if (foundPres) return foundPres;
    }
    for (UIViewController *child in [vc.childViewControllers reverseObjectEnumerator]) {
        UIViewController *foundChild = FFBFindSheetControllerInTree(child, depth + 1);
        if (foundChild) return foundChild;
    }

    if ([vc isKindOfClass:FocusFBSettingsViewController.class] ||
        [vc isKindOfClass:UIAlertController.class] ||
        [vc isKindOfClass:UIActivityViewController.class]) {
        return nil;
    }
    NSString *cls = NSStringFromClass(vc.class) ?: @"";
    if ([cls hasPrefix:@"FocusFB"] || [cls hasPrefix:@"FFB"]) return nil;

    if (vc.isViewLoaded && !vc.view.hidden && vc.view.alpha > 0.05 && vc.view.window != nil) {
        if ([cls containsString:@"BottomSheet"] ||
            [cls containsString:@"ActionSheet"] ||
            [cls containsString:@"ShareSheet"] ||
            [cls containsString:@"Popover"] ||
            [cls containsString:@"Drawer"] ||
            (vc.presentingViewController != nil && depth >= 1)) {
            return vc;
        }
    }
    return nil;
}

static BOOL FFBScanViewTreeForModalBottomSheet(UIView *node,
                                               UIWindow *win,
                                               NSUInteger depth,
                                               UIView * _Nullable *outHost,
                                               UIView * _Nullable *outCard) {
    if (!node || depth > 9 || node.hidden || node.alpha <= 0.05) return NO;
    NSString *cls = NSStringFromClass(object_getClass(node)) ?: @"";
    if ([cls hasPrefix:@"FocusFB"] || [cls hasPrefix:@"FFB"]) return NO;

    CGRect r = [node convertRect:node.bounds toView:win];
    if (CGRectGetWidth(r) < CGRectGetWidth(win.bounds) * 0.90 ||
        CGRectGetHeight(r) < CGRectGetHeight(win.bounds) * 0.85) {
        return NO;
    }

    // Controlla prima i figli più profondi (l'ultimo overlay modale aggiunto sopra il contenuto)
    for (UIView *sub in [node.subviews reverseObjectEnumerator]) {
        if (FFBScanViewTreeForModalBottomSheet(sub, win, depth + 1, outHost, outCard)) {
            return YES;
        }
    }

    BOOL hasBackdrop = FFBViewLooksLikeDimmedBackdrop(node, win);
    if (!hasBackdrop) {
        for (UIView *sub in node.subviews) {
            if (FFBViewLooksLikeDimmedBackdrop(sub, win)) {
                hasBackdrop = YES;
                break;
            }
        }
    }
    BOOL namedModal = ([cls containsString:@"TransitionView"] ||
                       [cls containsString:@"BottomSheet"] ||
                       [cls containsString:@"Modal"] ||
                       [cls containsString:@"Sheet"] ||
                       [cls containsString:@"Drawer"]);

    if (hasBackdrop || namedModal) {
        UIView *card = FFBFindBottomSheetCardInContainer(node, win, 0);
        if (card) {
            UIView *host = (card == node && node.superview) ? node.superview : node;
            if (outHost) *outHost = host;
            if (outCard) *outCard = card;
            return YES;
        }
    }
    return NO;
}

static BOOL FFBDetectOpenFacebookBottomSheet(UIView * _Nullable *outHostContainer,
                                             UIView * _Nullable *outSheetCard) {
    if (outHostContainer) *outHostContainer = nil;
    if (outSheetCard) *outSheetCard = nil;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;

        for (UIWindow *win in [ws.windows reverseObjectEnumerator]) {
            if (win.hidden || win.alpha <= 0.05) continue;
            NSString *rootCls = win.rootViewController ? NSStringFromClass(win.rootViewController.class) : @"";
            if ([rootCls hasPrefix:@"FocusFB"] || [rootCls hasPrefix:@"FFB"] ||
                [win.rootViewController isKindOfClass:UIAlertController.class] ||
                [win.rootViewController isKindOfClass:UIActivityViewController.class]) {
                continue;
            }

            // 1. Ricerca nel grafo dei UIViewController (sia presented sia child sheet controller!)
            UIViewController *sheetVC = FFBFindSheetControllerInTree(win.rootViewController, 0);
            if (sheetVC && sheetVC.isViewLoaded && sheetVC.view.window == win) {
                UIView *searchRoot = (CGRectGetMinY([sheetVC.view convertRect:sheetVC.view.bounds toView:win]) > 40.0 && sheetVC.view.superview)
                                     ? sheetVC.view.superview
                                     : sheetVC.view;
                UIView *card = FFBFindBottomSheetCardInContainer(searchRoot, win, 0);
                if (card) {
                    UIView *host = (card == searchRoot && searchRoot.superview) ? searchRoot.superview : searchRoot;
                    if (outHostContainer) *outHostContainer = host;
                    if (outSheetCard) *outSheetCard = card;
                    return YES;
                }
            }

            // 2. Ricerca gerarchica profonda per bottom sheet React Native / Bloks / ComponentKit montati come UIView
            UIView *vHost = nil;
            UIView *vCard = nil;
            if (FFBScanViewTreeForModalBottomSheet(win, win, 0, &vHost, &vCard) && vHost && vCard) {
                if (outHostContainer) *outHostContainer = vHost;
                if (outSheetCard) *outSheetCard = vCard;
                return YES;
            }
        }
    }
    return NO;
}

static void FFBSyncShareSheetDownloadBar(void) {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.enableMediaDownload) {
        if (gShareSheetFollowTimer) {
            [gShareSheetFollowTimer invalidate];
            gShareSheetFollowTimer = nil;
        }
        return;
    }

    UIView *sheetHost = nil;
    UIView *sheetCard = nil;
    BOOL sheetOpen = FFBDetectOpenFacebookBottomSheet(&sheetHost, &sheetCard);

    if (!sheetOpen || !sheetHost || !sheetCard) {
        if (gShareSheetFollowTimer) {
            [gShareSheetFollowTimer invalidate];
            gShareSheetFollowTimer = nil;
        }
        return;
    }

    FFBShareSheetDownloadBar *existingBar = (FFBShareSheetDownloadBar *)[sheetHost viewWithTag:kFFBShareSheetBarTag];
    if (existingBar) {
        existingBar.trackedSheetCard = sheetCard;
        [existingBar updatePositionRelativeToSheetCard];
        return;
    }

    // Mostra la barra "Scarica video" SOLO se sotto al menu Condividi c'è effettivamente un Video / Reel / Storia Video!
    FFBMediaCandidate *videoCand = FFBFindActiveVideoOnScreen(sheetHost);
    if (!videoCand || ![videoCand hasUsableVideo]) {
        return;
    }

    FFBShareSheetDownloadBar *bar = [[FFBShareSheetDownloadBar alloc] initWithFrame:CGRectMake(12, 100, 320, 50)];
    bar.videoCandidate = videoCand;
    bar.trackedSheetCard = sheetCard;
    [sheetHost addSubview:bar];
    [bar updatePositionRelativeToSheetCard];

    if (!gShareSheetFollowTimer) {
        gShareSheetFollowTimer = [NSTimer scheduledTimerWithTimeInterval:0.08
                                                                 repeats:YES
                                                                   block:^(NSTimer *timer) {
            UIView *h = nil;
            UIView *c = nil;
            if (!FFBDetectOpenFacebookBottomSheet(&h, &c) || !h || !c) {
                [timer invalidate];
                if (gShareSheetFollowTimer == timer) {
                    gShareSheetFollowTimer = nil;
                }
                return;
            }
            FFBShareSheetDownloadBar *b = (FFBShareSheetDownloadBar *)[h viewWithTag:kFFBShareSheetBarTag];
            if (b) {
                b.trackedSheetCard = c;
                [b updatePositionRelativeToSheetCard];
            }
        }];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Pulsante Rapido Opzionale (Solo se attivato esplicitamente nelle impostazioni)
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBShouldShowOptionalQuickButtonNow(UIWindow *win) {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.enableMediaDownload || !prefs.showMediaDownloadButton || !win) {
        return NO;
    }

    UIViewController *top = FocusFBTopMostViewController();
    if (!top) return NO;
    if ([top isKindOfClass:FocusFBSettingsViewController.class] ||
        [top.navigationController.viewControllers.firstObject isKindOfClass:FocusFBSettingsViewController.class] ||
        [top isKindOfClass:UIAlertController.class] ||
        [top isKindOfClass:UIActivityViewController.class]) {
        return NO;
    }

    UIView *dummyHost = nil;
    UIView *dummyCard = nil;
    if (FFBDetectOpenFacebookBottomSheet(&dummyHost, &dummyCard)) {
        return NO; // Quando è aperto il menu Condividi c'è già la barra integrata!
    }

    FFBMediaCandidate *videoCand = FFBFindActiveVideoOnScreen(nil);
    if (!videoCand || ![videoCand hasUsableVideo]) {
        return NO;
    }

    if (FocusFBIsStoryViewerVisibleNow()) {
        return YES;
    }

    CGFloat minFullscreenArea = CGRectGetWidth(win.bounds) * (CGRectGetHeight(win.bounds) * 0.55);
    return (videoCand.rawVisibleArea >= minFullscreenArea);
}

@interface FFBQuickVideoButtonTarget : NSObject
+ (instancetype)shared;
- (void)handleQuickTap:(UIButton *)sender;
- (void)handleQuickPan:(UIPanGestureRecognizer *)pan;
@end

@implementation FFBQuickVideoButtonTarget

+ (instancetype)shared {
    static FFBQuickVideoButtonTarget *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[FFBQuickVideoButtonTarget alloc] init];
    });
    return inst;
}

- (void)handleQuickTap:(__unused UIButton *)sender {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];
    FFBMediaCandidate *cand = FFBFindActiveVideoOnScreen(nil);
    FFBPerformCandidateDownload(cand, NO, NO);
}

- (void)handleQuickPan:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view;
    UIView *sup = v.superview;
    if (!v || !sup) return;
    CGPoint tr = [pan translationInView:sup];
    CGPoint c = CGPointMake(v.center.x + tr.x, v.center.y + tr.y);
    UIEdgeInsets ins = sup.safeAreaInsets;
    c.x = MAX(28.0, MIN(CGRectGetWidth(sup.bounds) - 28.0, c.x));
    c.y = MAX(ins.top + 36.0, MIN(CGRectGetHeight(sup.bounds) - ins.bottom - 70.0, c.y));
    v.center = c;
    [pan setTranslation:CGPointZero inView:sup];
}

@end

// ─────────────────────────────────────────────────────────────────────────────
// 7. Hook Leggeri su AVPlayer e UIWindow + Sincronizzazione UI
// ─────────────────────────────────────────────────────────────────────────────

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
    }
}

static void FFBScheduleShareSheetSyncBurst(void) {
    if (!gMediaDownloaderReady) return;
    NSArray<NSNumber *> *delays = @[@(0.02), @(0.12), @(0.30), @(0.60)];
    for (NSNumber *d in delays) {
        double sec = d.doubleValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            FFBSyncShareSheetDownloadBar();
        });
    }
}

static void FFBHook_UIWindow_didAddSubview(id self, SEL _cmd, UIView *subview) {
    if (gOrigWindowDidAddSubview) {
        gOrigWindowDidAddSubview(self, _cmd, subview);
    }
    if (!gMediaDownloaderReady || !subview) return;
    if (subview.tag == kFFBQuickDownloadBtnTag || subview.tag == kFFBShareSheetBarTag) return;

    // Quando UIKit o Facebook aggiunge un UITransitionView o un overlay modale alla finestra,
    // aggiorna subito l'eventuale pulsante "Scarica video" sul menu Condividi!
    FFBScheduleShareSheetSyncBurst();
}

void FocusFBNotifyMediaControllerTransition(UIViewController *vc) {
    if (!gMediaDownloaderReady || !vc) return;
    if ([vc isKindOfClass:FocusFBSettingsViewController.class] ||
        [vc isKindOfClass:UIAlertController.class] ||
        [vc isKindOfClass:UIActivityViewController.class]) {
        return;
    }
    FFBScheduleShareSheetSyncBurst();
    FocusFBMediaDownloaderSyncUI();
}

void FocusFBMediaDownloaderSyncUI(void) {
    if (!gMediaDownloaderReady) return;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FocusFBMediaDownloaderSyncUI();
        });
        return;
    }

    FFBSyncShareSheetDownloadBar();

    UIWindow *win = FocusFBActiveWindow();
    if (!win) return;

    UIView *btnWrap = [win viewWithTag:kFFBQuickDownloadBtnTag];
    BOOL showBtn = FFBShouldShowOptionalQuickButtonNow(win);

    if (!showBtn) {
        if (btnWrap) {
            btnWrap.hidden = YES;
        }
        if (gQuickBtnVisibilityTimer) {
            [gQuickBtnVisibilityTimer invalidate];
            gQuickBtnVisibilityTimer = nil;
        }
        return;
    }

    if (!btnWrap) {
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        blur.tag = kFFBQuickDownloadBtnTag;
        CGFloat sz = 40.0;
        CGFloat topY = MAX(win.safeAreaInsets.top + 60.0, 108.0);
        blur.frame = CGRectMake(14.0, topY, sz, sz);
        blur.layer.cornerRadius = sz * 0.5;
        blur.layer.borderWidth = 0.7;
        blur.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
        blur.clipsToBounds = YES;

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = blur.bounds;
        btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16.5 weight:UIImageSymbolWeightBold];
        [btn setImage:[UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:cfg] forState:UIControlStateNormal];
        btn.tintColor = [UIColor whiteColor];
        [btn addTarget:[FFBQuickVideoButtonTarget shared] action:@selector(handleQuickTap:) forControlEvents:UIControlEventTouchUpInside];
        [blur.contentView addSubview:btn];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:[FFBQuickVideoButtonTarget shared]
                    action:@selector(handleQuickPan:)];
        [blur addGestureRecognizer:pan];

        [win addSubview:blur];
        btnWrap = blur;
    }

    btnWrap.hidden = NO;
    [win bringSubviewToFront:btnWrap];

    if (!gQuickBtnVisibilityTimer) {
        gQuickBtnVisibilityTimer = [NSTimer scheduledTimerWithTimeInterval:0.60
                                                                   repeats:YES
                                                                     block:^(__unused NSTimer *timer) {
            FocusFBMediaDownloaderSyncUI();
        }];
    }
}

static void FFBHook_UIApplication_sendEventMedia(id self, SEL _cmd, UIEvent *event) {
    if (gOrigAppSendEventMedia) {
        gOrigAppSendEventMedia(self, _cmd, event);
    }
    if (!gMediaDownloaderReady || !event || event.type != UIEventTypeTouches) return;
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.enableMediaDownload) return;

    NSSet<UITouch *> *touches = event.allTouches;
    if (touches.count != 1) return;
    UITouch *t = touches.anyObject;
    if (!t.window) return;

    UITouchPhase phase = t.phase;
    if (phase == UITouchPhaseBegan) {
        gLastTouchDownPt = [t locationInView:t.window];
        uint64_t seq = ++gTouchSeqID;
        // Se l'utente fa long-press su un Reel (~0.5s), Facebook apre il menu Condividi mentre il dito è ancora giù!
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.58 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gTouchSeqID == seq) {
                FFBSyncShareSheetDownloadBar();
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gTouchSeqID == seq) {
                FFBSyncShareSheetDownloadBar();
            }
        });
    } else if (phase == UITouchPhaseMoved) {
        CGPoint curPt = [t locationInView:t.window];
        if (hypot(curPt.x - gLastTouchDownPt.x, curPt.y - gLastTouchDownPt.y) >= 16.0) {
            ++gTouchSeqID; // Invalida subito il controllo long-press durante qualsiasi scroll/drag!
        }
    } else if (phase == UITouchPhaseEnded) {
        ++gTouchSeqID;
        CGPoint endPt = [t locationInView:t.window];
        // Solo su tap pulito (es. tap su pulsante Condividi o •••), zero lavoro durante scroll/swipe!
        if (hypot(endPt.x - gLastTouchDownPt.x, endPt.y - gLastTouchDownPt.y) < 16.0) {
            FFBScheduleShareSheetSyncBurst();
        }
    } else if (phase == UITouchPhaseCancelled) {
        ++gTouchSeqID;
        // Quando il long-press nativo di Facebook apre la barra Condividi, UIKit cancella il touch attivo!
        FFBScheduleShareSheetSyncBurst();
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
        if (!gInstalledWindowAddHook) {
            gInstalledWindowAddHook = FFBMediaHookMethod(UIWindow.class,
                                                         @selector(didAddSubview:),
                                                         (IMP)FFBHook_UIWindow_didAddSubview,
                                                         (IMP *)&gOrigWindowDidAddSubview);
        }
        if (!gInstalledSendEventHook) {
            gInstalledSendEventHook = FFBMediaHookMethod(UIApplication.class,
                                                         @selector(sendEvent:),
                                                         (IMP)FFBHook_UIApplication_sendEventMedia,
                                                         (IMP *)&gOrigAppSendEventMedia);
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
            FocusFBMediaDownloaderSyncUI();
        }];
    });
}
