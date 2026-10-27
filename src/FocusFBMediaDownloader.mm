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
static char kWindowMediaLongPressKey;

typedef id (*FFBAVURLAssetInitIMP)(id, SEL, NSURL *, NSDictionary *);
static FFBAVURLAssetInitIMP gOrigAVURLAssetInit = NULL;
static BOOL gInstalledAVAssetHook = NO;

static os_unfair_lock gAssetMapLock = OS_UNFAIR_LOCK_INIT;
static NSMapTable<AVAsset *, NSURL *> *gAssetURLTable = nil;
static NSTimer *gQuickBtnVisibilityTimer = nil;
static BOOL gDownloadInFlight = NO;

// Selettori opzionali delle classi media interne di Facebook (FBVideoPlayback*, FBSnacks*, FBWebImage*)
@interface NSObject (FFBFacebookMediaSelectors)
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
- (nullable id)imageSpecifier;
- (nullable NSArray *)allInfoURLsSortedByDescImageFlag;
- (nullable UIImage *)displayedImage;
@end

// ─────────────────────────────────────────────────────────────────────────────
// 1. Modello Candidato Media Trovato sullo Schermo
// ─────────────────────────────────────────────────────────────────────────────

@interface FFBMediaCandidate : NSObject
@property (nonatomic, assign) BOOL isVideo;
@property (nonatomic, strong, nullable) NSURL *hdVideoURL;
@property (nonatomic, strong, nullable) NSURL *sdVideoURL;
@property (nonatomic, strong, nullable) AVAsset *avAsset;
@property (nonatomic, strong, nullable) NSURL *imageURL;
@property (nonatomic, strong, nullable) UIImage *image;
@property (nonatomic, assign) CGFloat rawVisibleArea;
@property (nonatomic, assign) CGFloat screenAreaScore;
@end

@implementation FFBMediaCandidate
@end

// ─────────────────────────────────────────────────────────────────────────────
// 2. Tracciamento Sicuro AVURLAsset -> NSURL
// ─────────────────────────────────────────────────────────────────────────────

static NSURL *FFBLookupURLForAsset(AVAsset *asset) {
    if (!asset) return nil;
    if ([asset isKindOfClass:AVURLAsset.class]) {
        NSURL *u = ((AVURLAsset *)asset).URL;
        if (u) return u;
    }
    os_unfair_lock_lock(&gAssetMapLock);
    NSURL *mapped = gAssetURLTable ? [gAssetURLTable objectForKey:asset] : nil;
    os_unfair_lock_unlock(&gAssetMapLock);
    return mapped;
}

static id FFBHook_AVURLAsset_initWithURL(id self, SEL _cmd, NSURL *URL, NSDictionary *options) {
    id obj = gOrigAVURLAssetInit ? gOrigAVURLAssetInit(self, _cmd, URL, options) : nil;
    if (obj && URL) {
        os_unfair_lock_lock(&gAssetMapLock);
        if (!gAssetURLTable) {
            gAssetURLTable = [NSMapTable weakToStrongObjectsMapTable];
        }
        [gAssetURLTable setObject:URL forKey:(AVAsset *)obj];
        os_unfair_lock_unlock(&gAssetMapLock);
    }
    return obj;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Estrazione Video / Reels / Storie / Immagini dalla Gerarchia Visibile
// ─────────────────────────────────────────────────────────────────────────────

static NSURL *FFBSafeURLProperty(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m || method_getNumberOfArguments(m) != 2) return nil;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || enc[0] != '@') return nil;
    @try {
        id val = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        if ([val isKindOfClass:NSURL.class]) return (NSURL *)val;
        if ([val isKindOfClass:NSString.class] && [(NSString *)val hasPrefix:@"http"]) {
            return [NSURL URLWithString:(NSString *)val];
        }
    } @catch (__unused NSException *e) {
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

static id FFBSafeIvarObject(id obj, const char *ivarName) {
    if (!obj || !ivarName) return nil;
    @try {
        Ivar iv = class_getInstanceVariable(object_getClass(obj), ivarName);
        if (!iv) return nil;
        const char *enc = ivar_getTypeEncoding(iv);
        if (!enc || enc[0] != '@') return nil;
        return object_getIvar(obj, iv);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void FFBPopulateFromPlaybackItem(id playbackItem, FFBMediaCandidate *cand) {
    if (!playbackItem || !cand) return;
    NSURL *hd = FFBSafeURLProperty(playbackItem, @selector(HDPlaybackURL))
             ?: FFBSafeURLProperty(playbackItem, @selector(hdPlaybackURL))
             ?: FFBSafeURLProperty(playbackItem, @selector(playableURL))
             ?: FFBSafeURLProperty(playbackItem, @selector(videoURL));
    NSURL *sd = FFBSafeURLProperty(playbackItem, @selector(SDPlaybackURL))
             ?: FFBSafeURLProperty(playbackItem, @selector(sdPlaybackURL));
    if (hd || sd) {
        cand.isVideo = YES;
        cand.hdVideoURL = hd ?: sd;
        if (sd && hd && ![sd.absoluteString isEqualToString:hd.absoluteString]) {
            cand.sdVideoURL = sd;
        }
    }
}

static AVPlayer *FFBExtractAVPlayerFromViewOrLayer(UIView *view) {
    if (!view) return nil;
    if ([view.layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *p = ((AVPlayerLayer *)view.layer).player;
        if (p) return p;
    }
    for (CALayer *subLayer in view.layer.sublayers) {
        if ([subLayer isKindOfClass:AVPlayerLayer.class]) {
            AVPlayer *p = ((AVPlayerLayer *)subLayer).player;
            if (p) return p;
        }
    }
    id pObj = FFBSafeObjectProperty(view, NSSelectorFromString(@"player"));
    if ([pObj isKindOfClass:AVPlayer.class]) {
        return (AVPlayer *)pObj;
    }
    return nil;
}

static void FFBExtractImageFromWebSpecifier(id spec, FFBMediaCandidate *cand) {
    if (!spec || !cand) return;
    NSArray *urls = FFBSafeObjectProperty(spec, @selector(allInfoURLsSortedByDescImageFlag));
    if ([urls isKindOfClass:NSArray.class] && urls.count > 0) {
        id first = urls.firstObject;
        if ([first isKindOfClass:NSURL.class]) {
            cand.imageURL = (NSURL *)first;
            return;
        }
        NSURL *nested = FFBSafeURLProperty(first, NSSelectorFromString(@"url"))
                     ?: FFBSafeURLProperty(first, NSSelectorFromString(@"imageURL"));
        if (nested) {
            cand.imageURL = nested;
            return;
        }
    }
    NSURL *directURL = FFBSafeURLProperty(spec, NSSelectorFromString(@"url"))
                    ?: FFBSafeURLProperty(spec, NSSelectorFromString(@"imageURL"));
    if (directURL) {
        cand.imageURL = directURL;
        return;
    }
    id memImg = FFBSafeObjectProperty(spec, NSSelectorFromString(@"image"));
    if ([memImg isKindOfClass:UIImage.class]) {
        cand.image = (UIImage *)memImg;
    }
}

static void FFBScanSubtreeForMedia(UIView *view,
                                   UIWindow *win,
                                   CGPoint targetPoint,
                                   BOOL requirePointHit,
                                   NSUInteger depth,
                                   NSMutableArray<FFBMediaCandidate *> *outCandidates) {
    if (!view || depth > 16 || view.hidden || view.alpha <= 0.02) return;
    if (view.tag == kFFBQuickDownloadBtnTag) return;

    CGRect rectInWin = [view convertRect:view.bounds toView:win];
    CGRect visibleRect = CGRectIntersection(rectInWin, win.bounds);
    if (CGRectIsNull(visibleRect) || CGRectGetWidth(visibleRect) < 90.0 || CGRectGetHeight(visibleRect) < 90.0) {
        // Continua comunque nei figli se un wrapper intermedio ha bounds zero ma clipToBounds = NO
        if (view.clipsToBounds && (CGRectGetWidth(rectInWin) < 90.0 || CGRectGetHeight(rectInWin) < 90.0)) {
            return;
        }
    }

    BOOL containsPoint = !requirePointHit || CGRectContainsPoint(CGRectInset(rectInWin, -12.0, -12.0), targetPoint);
    CGFloat area = MAX(1.0, CGRectGetWidth(visibleRect) * CGRectGetHeight(visibleRect));

    if (containsPoint && area >= (105.0 * 105.0)) {
        // A. Controllo FBVideoPlaybackController / FBSnacksNewVideoView / VideoContainerView
        id ctrl = FFBSafeObjectProperty(view, @selector(controller))
               ?: FFBSafeObjectProperty(view, @selector(manager))
               ?: FFBSafeIvarObject(view, "_controller")
               ?: FFBSafeIvarObject(view, "_videoPlaybackController");
        if (ctrl) {
            id item = FFBSafeObjectProperty(ctrl, @selector(currentVideoPlaybackItem));
            if (item) {
                FFBMediaCandidate *vcand = [[FFBMediaCandidate alloc] init];
                FFBPopulateFromPlaybackItem(item, vcand);
                if (vcand.isVideo) {
                    vcand.rawVisibleArea = area;
                    vcand.screenAreaScore = area + 500000.0; // Priorità massima: URL MP4 diretto HD/SD
                    [outCandidates addObject:vcand];
                }
            }
        }

        // B. Controllo AVPlayerLayer / AVPlayer attivo
        AVPlayer *player = FFBExtractAVPlayerFromViewOrLayer(view);
        if (player && player.currentItem && player.currentItem.asset) {
            FFBMediaCandidate *pcand = [[FFBMediaCandidate alloc] init];
            pcand.isVideo = YES;
            pcand.avAsset = player.currentItem.asset;
            pcand.hdVideoURL = FFBLookupURLForAsset(player.currentItem.asset);
            pcand.rawVisibleArea = area;
            CGFloat playingBonus = (player.rate > 0.01f) ? 250000.0 : 50000.0;
            pcand.screenAreaScore = area + playingBonus;
            [outCandidates addObject:pcand];
        }

        // C. Controllo FBSnacksPhotoView / FBWebImageView (Storie Foto + Feed ad alta risoluzione)
        id spec = FFBSafeObjectProperty(view, @selector(imageSpecifier));
        if (!spec) {
            id innerPhoto = FFBSafeIvarObject(view, "_photoView");
            if (innerPhoto) {
                spec = FFBSafeObjectProperty(innerPhoto, @selector(imageSpecifier));
                if (!spec) {
                    id innerPhoto2 = FFBSafeIvarObject(innerPhoto, "_photoView");
                    if (innerPhoto2) {
                        spec = FFBSafeObjectProperty(innerPhoto2, @selector(imageSpecifier));
                    }
                }
            }
        }
        if (spec) {
            FFBMediaCandidate *scand = [[FFBMediaCandidate alloc] init];
            FFBExtractImageFromWebSpecifier(spec, scand);
            if (scand.imageURL || scand.image) {
                scand.screenAreaScore = area + 30000.0;
                [outCandidates addObject:scand];
            }
        }

        // D. Controllo UIImageView nativa
        if ([view isKindOfClass:UIImageView.class]) {
            UIImage *img = ((UIImageView *)view).image;
            if (img && img.size.width * img.scale >= 180.0 && img.size.height * img.scale >= 180.0) {
                FFBMediaCandidate *icand = [[FFBMediaCandidate alloc] init];
                icand.image = img;
                icand.screenAreaScore = area;
                [outCandidates addObject:icand];
            }
        } else {
            // E. Controllo CALayer.contents (CGImageRef usato da ComponentKit CKComponent e React Native)
            id contents = view.layer.contents;
            if (contents && CFGetTypeID((__bridge CFTypeRef)contents) == CGImageGetTypeID()) {
                CGImageRef cgImg = (__bridge CGImageRef)contents;
                size_t pxW = CGImageGetWidth(cgImg);
                size_t pxH = CGImageGetHeight(cgImg);
                if (pxW >= 200 && pxH >= 200) {
                    UIImage *img = [UIImage imageWithCGImage:cgImg];
                    if (img) {
                        FFBMediaCandidate *lcand = [[FFBMediaCandidate alloc] init];
                        lcand.image = img;
                        lcand.screenAreaScore = area;
                        [outCandidates addObject:lcand];
                    }
                }
            }
        }
    }

    for (UIView *sub in view.subviews) {
        FFBScanSubtreeForMedia(sub, win, targetPoint, requirePointHit, depth + 1, outCandidates);
    }
}

static FFBMediaCandidate *FFBFindBestMediaAtPoint(UIWindow *win, CGPoint pointInWin, BOOL requirePointHit) {
    if (!win) return nil;

    // Controlla prima se il top view controller è FBPhotoViewController (foto full-screen)
    UIViewController *topVC = FocusFBTopMostViewController();
    if (topVC && [NSStringFromClass(topVC.class) containsString:@"PhotoViewController"]) {
        id disp = FFBSafeObjectProperty(topVC, @selector(displayedImage));
        if ([disp isKindOfClass:UIImage.class]) {
            FFBMediaCandidate *c = [[FFBMediaCandidate alloc] init];
            c.image = (UIImage *)disp;
            c.screenAreaScore = 999999.0;
            return c;
        }
    }

    NSMutableArray<FFBMediaCandidate *> *candidates = [NSMutableArray array];
    UIView *rootView = topVC.viewIfLoaded ?: win;
    // Se il topVC è un container generico, scansiona l'intera finestra attiva
    if (!rootView || rootView.window != win || CGRectGetHeight(rootView.bounds) < 200.0) {
        rootView = win;
    }
    FFBScanSubtreeForMedia(win, win, pointInWin, requirePointHit, 0, candidates);
    if (candidates.count == 0 && requirePointHit) {
        // Fallback tollerante al centro dello schermo se l'utente è in Reels/Storie
        if (FocusFBIsStoryViewerVisibleNow()) {
            FFBScanSubtreeForMedia(win, win, CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds)), NO, 0, candidates);
        }
    }
    if (candidates.count == 0) return nil;

    // Preferisci sempre il video se presente sullo stesso punto rispetto alla sua thumbnail statica!
    [candidates sortUsingComparator:^NSComparisonResult(FFBMediaCandidate *a, FFBMediaCandidate *b) {
        if (a.isVideo != b.isVideo) {
            return a.isVideo ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.screenAreaScore > b.screenAreaScore) return NSOrderedAscending;
        if (a.screenAreaScore < b.screenAreaScore) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    // Unisci eventuale URL MP4 diretto da un candidato fratello con AVAsset
    FFBMediaCandidate *best = candidates.firstObject;
    if (best.isVideo && !best.hdVideoURL) {
        for (FFBMediaCandidate *other in candidates) {
            if (other.isVideo && other.hdVideoURL) {
                best.hdVideoURL = other.hdVideoURL;
                best.sdVideoURL = other.sdVideoURL;
                break;
            }
        }
    }
    return best;
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Downloader Universale (MP4 Diretto + HLS .m3u8 fMP4/TS + Muxing Audio/Video)
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
                                                   timeoutInterval:30.0];
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
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC)));
    return outData;
}

static NSString *FFBExtractQuotedAttr(NSString *line, NSString *attrName) {
    NSString *Token = [NSString stringWithFormat:@"%@=\"", attrName];
    NSRange r = [line rangeOfString:Token];
    if (r.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(r);
    NSRange end = [line rangeOfString:@"\"" options:0 range:NSMakeRange(start, line.length - start)];
    if (end.location == NSNotFound) return nil;
    return [line substringWithRange:NSMakeRange(start, end.location - start)];
}

static NSString *FFBConvertByteRangeSpecToHTTPHeader(NSString *spec, long long *ioNextOffset) {
    // Formato HLS: "length@offset" oppure "length"
    if (spec.length == 0) return nil;
    NSArray<NSString *> *parts = [spec componentsSeparatedByString:@"@"];
    long long len = [parts.firstObject longLongValue];
    if (len <= 0) return nil;
    long long offset = (parts.count > 1) ? [parts[1] longLongValue] : (ioNextOffset ? *ioNextOffset : 0);
    long long endInclusive = offset + len - 1;
    if (ioNextOffset) *ioNextOffset = endInclusive + 1;
    return [NSString stringWithFormat:@"%lld-%lld", offset, endInclusive];
}

static NSURL *FFBDownloadHLSMediaTrack(NSURL *mediaPlaylistURL, NSString *tempPrefix) {
    NSData *plData = FFBSyncFetchURL(mediaPlaylistURL, nil);
    if (!plData) return nil;
    NSString *plText = [[NSString alloc] initWithData:plData encoding:NSUTF8StringEncoding];
    if (!plText || ![plText containsString:@"#EXTM3U"]) return nil;

    NSArray<NSString *> *lines = [plText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableData *combined = [NSMutableData data];
    BOOL hasInitMap = NO;
    NSString *pendingByteRange = nil;
    long long rollingOffset = 0;

    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;

        if ([line hasPrefix:@"#EXT-X-MAP:"]) {
            NSString *mapURI = FFBExtractQuotedAttr(line, @"URI");
            NSString *mapBR = FFBExtractQuotedAttr(line, @"BYTERANGE");
            if (mapURI.length > 0) {
                NSURL *absMapURL = [NSURL URLWithString:mapURI relativeToURL:mediaPlaylistURL].absoluteURL;
                long long mapOff = 0;
                NSString *hdrRange = mapBR ? FFBConvertByteRangeSpecToHTTPHeader(mapBR, &mapOff) : nil;
                NSData *initBytes = FFBSyncFetchURL(absMapURL, hdrRange);
                if (!initBytes) return nil;
                [combined appendData:initBytes];
                hasInitMap = YES;
            }
            continue;
        }

        if ([line hasPrefix:@"#EXT-X-BYTERANGE:"]) {
            NSString *spec = [line substringFromIndex:@"#EXT-X-BYTERANGE:".length];
            pendingByteRange = FFBConvertByteRangeSpecToHTTPHeader(spec, &rollingOffset);
            continue;
        }

        if ([line hasPrefix:@"#"]) {
            continue;
        }

        NSURL *segURL = [NSURL URLWithString:line relativeToURL:mediaPlaylistURL].absoluteURL;
        NSData *segData = FFBSyncFetchURL(segURL, pendingByteRange);
        pendingByteRange = nil;
        if (!segData) return nil;
        [combined appendData:segData];
    }

    if (combined.length < 512) return nil;
    NSString *ext = hasInitMap ? @"mp4" : @"ts";
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"%@_%@.%@", tempPrefix, [NSUUID UUID].UUIDString, ext]];
    NSURL *outURL = [NSURL fileURLWithPath:outPath];
    if (![combined writeToURL:outURL atomically:YES]) return nil;
    return outURL;
}

static NSURL *FFBRemuxOrMergeToStandardMP4(NSURL *videoFileURL, NSURL * _Nullable audioFileURL) {
    if (!videoFileURL) return nil;

    AVURLAsset *vAsset = [AVURLAsset URLAssetWithURL:videoFileURL options:nil];
    NSArray<AVAssetTrack *> *vTracks = [vAsset tracksWithMediaType:AVMediaTypeVideo];
    if (vTracks.count == 0) {
        return videoFileURL;
    }

    AVMutableComposition *comp = [AVMutableComposition composition];
    CMTime vDur = vAsset.duration;
    if (!CMTIME_IS_NUMERIC(vDur) || CMTimeGetSeconds(vDur) <= 0.05) {
        return videoFileURL;
    }

    AVMutableCompositionTrack *compVideo = [comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                                             preferredTrackID:kCMPersistentTrackID_Invalid];
    AVAssetTrack *srcV = vTracks.firstObject;
    [compVideo insertTimeRange:CMTimeRangeMake(kCMTimeZero, vDur) ofTrack:srcV atTime:kCMTimeZero error:nil];
    compVideo.preferredTransform = srcV.preferredTransform;

    if (audioFileURL) {
        AVURLAsset *aAsset = [AVURLAsset URLAssetWithURL:audioFileURL options:nil];
        NSArray<AVAssetTrack *> *aTracks = [aAsset tracksWithMediaType:AVMediaTypeAudio];
        if (aTracks.count > 0 && CMTIME_IS_NUMERIC(aAsset.duration)) {
            CMTime muxAudioDur = CMTimeMinimum(vDur, aAsset.duration);
            AVMutableCompositionTrack *compAudio = [comp addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                     preferredTrackID:kCMPersistentTrackID_Invalid];
            [compAudio insertTimeRange:CMTimeRangeMake(kCMTimeZero, muxAudioDur)
                               ofTrack:aTracks.firstObject
                                atTime:kCMTimeZero
                                 error:nil];
        }
    } else {
        NSArray<AVAssetTrack *> *embAudio = [vAsset tracksWithMediaType:AVMediaTypeAudio];
        if (embAudio.count > 0) {
            AVMutableCompositionTrack *compAudio = [comp addMutableTrackWithMediaType:AVMediaTypeAudio
                                                                     preferredTrackID:kCMPersistentTrackID_Invalid];
            [compAudio insertTimeRange:CMTimeRangeMake(kCMTimeZero, vDur)
                               ofTrack:embAudio.firstObject
                                atTime:kCMTimeZero
                                 error:nil];
        }
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
    NSData *rawData = FFBSyncFetchURL(playlistURL, nil);
    if (!rawData) return nil;
    NSString *text = [[NSString alloc] initWithData:rawData encoding:NSUTF8StringEncoding];
    if (!text || ![text containsString:@"#EXTM3U"]) return nil;

    // Se è una media playlist singola (non master)
    if (![text containsString:@"#EXT-X-STREAM-INF:"]) {
        NSURL *trackURL = FFBDownloadHLSMediaTrack(playlistURL, @"ffb_hls_single");
        if (!trackURL) return nil;
        NSURL *muxed = FFBRemuxOrMergeToStandardMP4(trackURL, nil);
        if (muxed && ![muxed isEqual:trackURL]) {
            [[NSFileManager defaultManager] removeItemAtURL:trackURL error:nil];
        }
        return muxed;
    }

    // Master playlist: trova la variante video con BANDWIDTH massimo + eventuale traccia audio separata
    NSMutableDictionary<NSString *, NSURL *> *audioGroups = [NSMutableDictionary dictionary];
    NSURL *fallbackAudioURL = nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

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

static NSURL *FFBDownloadOrExportVideoToLocalMP4(NSURL * _Nullable videoURL, AVAsset * _Nullable asset) {
    if (videoURL) {
        NSString *lower = videoURL.absoluteString.lowercaseString;
        if ([lower containsString:@".m3u8"]) {
            NSURL *hlsMP4 = FFBResolveHLSPlaylistToMP4(videoURL);
            if (hlsMP4) return hlsMP4;
        } else {
            NSData *raw = FFBSyncFetchURL(videoURL, nil);
            if (raw.length > 64) {
                // Verifica se il server ha risposto comunque con una playlist HLS #EXTM3U
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
                    NSURL *vLocal = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"ffb_dash_v_%@.mp4", [NSUUID UUID].UUIDString]]];
                    [vData writeToURL:vLocal atomically:YES];
                    NSURL *aLocal = nil;
                    if (aSegURL) {
                        NSData *aData = FFBSyncFetchURL(aSegURL, nil);
                        if (aData.length > 256) {
                            aLocal = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                      [NSString stringWithFormat:@"ffb_dash_a_%@.mp4", [NSUUID UUID].UUIDString]]];
                            [aData writeToURL:aLocal atomically:YES];
                        }
                    }
                    NSURL *merged = FFBRemuxOrMergeToStandardMP4(vLocal, aLocal);
                    if (merged && ![merged isEqual:vLocal]) {
                        [[NSFileManager defaultManager] removeItemAtURL:vLocal error:nil];
                    }
                    if (aLocal) [[NSFileManager defaultManager] removeItemAtURL:aLocal error:nil];
                    if (merged) return merged;
                }
            }
        }
        return FFBExportAVAssetDirectlyToMP4(asset);
    }
    return nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Salvataggio Diretto nel Rullino iOS (PHPhotoLibrary + Fallback Share Sheet)
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
    if (shareInstead) {
        FFBPresentShareSheetForItem(localVideoURL);
        return;
    }

    @try {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
            if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                // Se l'utente non ha concesso permesso Foto, apri il foglio Condividi nativo iOS
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
                    // Fallback automatico tramite remux MP4 oppure Share Sheet
                    NSURL *remuxed = FFBRemuxOrMergeToStandardMP4(localVideoURL, nil);
                    if (remuxed && ![remuxed isEqual:localVideoURL]) {
                        [[NSFileManager defaultManager] removeItemAtURL:localVideoURL error:nil];
                        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:remuxed];
                        } completionHandler:^(BOOL ok2, __unused NSError *err2) {
                            if (ok2) {
                                [[NSFileManager defaultManager] removeItemAtURL:remuxed error:nil];
                                dispatch_async(dispatch_get_main_queue(), ^{
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

static void FFBSaveImageToCameraRoll(UIImage * _Nullable image, NSURL * _Nullable remoteImageURL, BOOL shareInstead) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *imgData = remoteImageURL ? FFBSyncFetchURL(remoteImageURL, nil) : nil;
        UIImage *finalImg = imgData ? ([UIImage imageWithData:imgData] ?: image) : image;
        if (!finalImg) {
            dispatch_async(dispatch_get_main_queue(), ^{
                FocusFBShowToast(FFBLoc(@"DL.Failed"), @"exclamationmark.triangle.fill");
            });
            return;
        }

        if (shareInstead) {
            FFBPresentShareSheetForItem(finalImg);
            return;
        }

        @try {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
                if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                    FFBPresentShareSheetForItem(finalImg);
                    return;
                }
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    [PHAssetChangeRequest creationRequestForAssetFromImage:finalImg];
                } completionHandler:^(BOOL success, __unused NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (success) {
                            UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
                            [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
                            FocusFBShowToast(FFBLoc(@"DL.SavedPhoto"), @"checkmark.circle.fill");
                        } else {
                            FFBPresentShareSheetForItem(finalImg);
                        }
                    });
                }];
            }];
        } @catch (__unused NSException *ex) {
            FFBPresentShareSheetForItem(finalImg);
        }
    });
}

static void FFBPerformCandidateDownload(FFBMediaCandidate *cand, BOOL preferSD, BOOL shareInstead) {
    if (!cand || gDownloadInFlight) return;

    if (!cand.isVideo) {
        FFBSaveImageToCameraRoll(cand.image, cand.imageURL, shareInstead);
        return;
    }

    NSURL *chosenURL = (preferSD && cand.sdVideoURL) ? cand.sdVideoURL : (cand.hdVideoURL ?: cand.sdVideoURL);
    AVAsset *asset = cand.avAsset;
    if (!chosenURL && !asset) {
        FocusFBShowToast(FFBLoc(@"DL.NotFound"), @"info.circle.fill");
        return;
    }

    gDownloadInFlight = YES;
    FocusFBShowToast(FFBLoc(@"DL.Downloading"), @"arrow.down.circle.fill");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL *localMP4 = FFBDownloadOrExportVideoToLocalMP4(chosenURL, asset);
        dispatch_async(dispatch_get_main_queue(), ^{
            gDownloadInFlight = NO;
            FFBSaveLocalVideoFileToCameraRoll(localMP4, shareInstead);
        });
    });
}

static void FFBPresentMediaDownloadSheet(FFBMediaCandidate *cand, CGPoint anchorPointInWin) {
    if (!cand) return;
    UIViewController *top = FocusFBTopMostViewController();
    if (!top || [top isKindOfClass:UIAlertController.class] ||
        [top isKindOfClass:FocusFBSettingsViewController.class]) {
        return;
    }

    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:FFBLoc(@"DL.SheetTitle")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    if (cand.isVideo) {
        NSString *hdTitle = cand.sdVideoURL ? FFBLoc(@"DL.SaveVideoHD") : FFBLoc(@"DL.SaveVideo");
        [sheet addAction:[UIAlertAction actionWithTitle:hdTitle
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            FFBPerformCandidateDownload(cand, NO, NO);
        }]];
        if (cand.sdVideoURL) {
            [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"DL.SaveVideoSD")
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *a) {
                FFBPerformCandidateDownload(cand, YES, NO);
            }]];
        }
    } else {
        [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"DL.SavePhoto")
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            FFBPerformCandidateDownload(cand, NO, NO);
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"DL.Share")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        FFBPerformCandidateDownload(cand, NO, YES);
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = top.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(anchorPointInWin.x, anchorPointInWin.y, 2, 2);
    }
    [top presentViewController:sheet animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. Gesture Handler & Pulsante Rapido su Reels / Storie / Video Fullscreen
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBShouldShowQuickDownloadButtonNow(UIWindow *win) {
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

    // 1. Visualizzatore Storie attivo
    if (FocusFBIsStoryViewerVisibleNow()) {
        return YES;
    }

    // 2. Visualizzatore foto full-screen
    NSString *clsLower = NSStringFromClass(top.class).lowercaseString;
    if ([clsLower containsString:@"photoviewcontroller"] ||
        [clsLower containsString:@"mediaviewer"]) {
        return YES;
    }

    // 3. Reels o Video full-screen (AVPlayerLayer visibile che copre >= 62% dell'altezza dello schermo)
    if ([clsLower containsString:@"reels"] ||
        [clsLower containsString:@"shorts"] ||
        [clsLower containsString:@"inspiration"] ||
        [clsLower containsString:@"fullscreenvideo"] ||
        [clsLower containsString:@"tahoe"]) {
        return YES;
    }

    NSMutableArray<FFBMediaCandidate *> *cands = [NSMutableArray array];
    CGPoint center = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds));
    FFBScanSubtreeForMedia(win, win, center, YES, 0, cands);
    CGFloat minFullscreenArea = CGRectGetWidth(win.bounds) * (CGRectGetHeight(win.bounds) * 0.65);
    for (FFBMediaCandidate *c in cands) {
        if (c.isVideo && c.rawVisibleArea >= minFullscreenArea) {
            return YES;
        }
    }
    return NO;
}

@interface FFBMediaGestureCoordinator : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
- (void)handleWindowMediaLongPress:(UILongPressGestureRecognizer *)gr;
- (void)handleQuickDownloadTap:(UIButton *)sender;
- (void)handleQuickDownloadLongPress:(UILongPressGestureRecognizer *)gr;
- (void)handleQuickDownloadPan:(UIPanGestureRecognizer *)pan;
@end

@implementation FFBMediaGestureCoordinator

+ (instancetype)shared {
    static FFBMediaGestureCoordinator *inst = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        inst = [[FFBMediaGestureCoordinator alloc] init];
    });
    return inst;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.enableMediaDownload) return NO;

    UIView *v = touch.view;
    if (!v || !v.window) return NO;

    // Ignora tocchi sul pulsante rapido stesso o sulla barra tab inferiore
    for (UIView *cur = v; cur != nil; cur = cur.superview) {
        if (cur.tag == kFFBQuickDownloadBtnTag) return NO;
        NSString *cls = NSStringFromClass(object_getClass(cur));
        if ([cls containsString:@"TabBar"] || [cls hasPrefix:@"FocusFB"] || [cls hasPrefix:@"FFB"]) {
            return NO;
        }
        // Lascia intatta la pressione prolungata sui pulsanti piccoli (es. reazioni Mi Piace / Condividi)
        if (([cur isKindOfClass:UIControl.class] || (cur.accessibilityTraits & UIAccessibilityTraitButton) != 0) &&
            CGRectGetHeight(cur.bounds) > 0.0 && CGRectGetHeight(cur.bounds) < 62.0 &&
            CGRectGetWidth(cur.bounds) < 160.0) {
            return NO;
        }
    }
    return YES;
}

- (BOOL)gestureRecognizer:(__unused UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ([otherGestureRecognizer isKindOfClass:UILongPressGestureRecognizer.class] &&
        ((UILongPressGestureRecognizer *)otherGestureRecognizer).numberOfTouchesRequired >= 2) {
        return NO;
    }
    return YES;
}

- (void)handleWindowMediaLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    if (gr.numberOfTouches > 1) return;

    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.enableMediaDownload) return;

    UIWindow *win = (UIWindow *)gr.view ?: FocusFBActiveWindow();
    if (!win) return;

    CGPoint pt = [gr locationInView:win];
    FFBMediaCandidate *cand = FFBFindBestMediaAtPoint(win, pt, YES);
    if (!cand) return;

    FFBPresentMediaDownloadSheet(cand, pt);
}

- (void)handleQuickDownloadTap:(UIButton *)sender {
    UIWindow *win = sender.window ?: FocusFBActiveWindow();
    if (!win) return;
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [gen impactOccurred];

    CGPoint center = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds));
    FFBMediaCandidate *cand = FFBFindBestMediaAtPoint(win, center, NO);
    if (!cand) {
        FocusFBShowToast(FFBLoc(@"DL.NotFound"), @"info.circle.fill");
        return;
    }
    FFBPerformCandidateDownload(cand, NO, NO);
}

- (void)handleQuickDownloadLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    UIWindow *win = gr.view.window ?: FocusFBActiveWindow();
    if (!win) return;
    CGPoint center = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds));
    FFBMediaCandidate *cand = FFBFindBestMediaAtPoint(win, center, NO);
    if (cand) {
        FFBPresentMediaDownloadSheet(cand, gr.view.center);
    }
}

- (void)handleQuickDownloadPan:(UIPanGestureRecognizer *)pan {
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
// 7. Sincronizzazione Pulsante Rapido & Installazione
// ─────────────────────────────────────────────────────────────────────────────

void FocusFBMediaDownloaderSyncUI(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            FocusFBMediaDownloaderSyncUI();
        });
        return;
    }

    UIWindow *win = FocusFBActiveWindow();
    if (!win) return;

    // 1. Gesture pressione prolungata (1 dito) sulla finestra principale
    UILongPressGestureRecognizer *existingLP = objc_getAssociatedObject(win, &kWindowMediaLongPressKey);
    if (!existingLP || ![win.gestureRecognizers containsObject:existingLP]) {
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[FFBMediaGestureCoordinator shared]
                    action:@selector(handleWindowMediaLongPress:)];
        lp.numberOfTouchesRequired = 1;
        lp.minimumPressDuration = 0.56;
        lp.cancelsTouchesInView = NO;
        lp.delaysTouchesBegan = NO;
        lp.delegate = [FFBMediaGestureCoordinator shared];
        [win addGestureRecognizer:lp];
        objc_setAssociatedObject(win, &kWindowMediaLongPressKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 2. Pulsante download rapido (visibile solo dentro Storie, Reels o Media Full-screen)
    UIView *btnWrap = [win viewWithTag:kFFBQuickDownloadBtnTag];
    BOOL showBtn = FFBShouldShowQuickDownloadButtonNow(win);

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
        blur.frame = CGRectMake(CGRectGetWidth(win.bounds) - sz - 14.0, topY, sz, sz);
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
        [btn addTarget:[FFBMediaGestureCoordinator shared] action:@selector(handleQuickDownloadTap:) forControlEvents:UIControlEventTouchUpInside];
        [blur.contentView addSubview:btn];

        UILongPressGestureRecognizer *btnLP = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[FFBMediaGestureCoordinator shared]
                    action:@selector(handleQuickDownloadLongPress:)];
        btnLP.minimumPressDuration = 0.45;
        [blur addGestureRecognizer:btnLP];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:[FFBMediaGestureCoordinator shared]
                    action:@selector(handleQuickDownloadPan:)];
        [blur addGestureRecognizer:pan];

        [win addSubview:blur];
        btnWrap = blur;
    }

    btnWrap.hidden = NO;
    [win bringSubviewToFront:btnWrap];

    // Mantiene un controllo leggero solo finché il pulsante rapido è visibile,
    // così sparisce istantaneamente appena chiudi il Reel, il Video o la Storia!
    if (!gQuickBtnVisibilityTimer) {
        gQuickBtnVisibilityTimer = [NSTimer scheduledTimerWithTimeInterval:0.55
                                                                   repeats:YES
                                                                     block:^(__unused NSTimer *timer) {
            FocusFBMediaDownloaderSyncUI();
        }];
    }
}

void FocusFBInstallMediaDownloader(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!gInstalledAVAssetHook) {
            Method m = class_getInstanceMethod(AVURLAsset.class, @selector(initWithURL:options:));
            if (m) {
                IMP orig = method_getImplementation(m);
                const char *types = method_getTypeEncoding(m);
                if (orig && types && orig != (IMP)FFBHook_AVURLAsset_initWithURL) {
                    gOrigAVURLAssetInit = (FFBAVURLAssetInitIMP)orig;
                    if (!class_addMethod(AVURLAsset.class, @selector(initWithURL:options:), (IMP)FFBHook_AVURLAsset_initWithURL, types)) {
                        method_setImplementation(m, (IMP)FFBHook_AVURLAsset_initWithURL);
                    }
                    gInstalledAVAssetHook = YES;
                }
            }
        }

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
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
