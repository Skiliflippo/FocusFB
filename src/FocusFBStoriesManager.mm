#import "FocusFBStoriesManager.h"
#import "FocusFBPrefs.h"
#import "FocusFBTabManager.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <os/lock.h>
#include <atomic>
#include <unordered_set>
#include <string>

typedef void (*FFBAppSendEventIMP)(id, SEL, UIEvent *);
typedef NSURLSessionDataTask *(*FFBSessionTaskReqIMP)(id, SEL, NSURLRequest *);
typedef NSURLSessionDataTask *(*FFBSessionTaskReqCompIMP)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));

static FFBAppSendEventIMP       gOrigAppSendEvent    = NULL;
static FFBSessionTaskReqIMP     gOrigDataTaskReq     = NULL;
static FFBSessionTaskReqCompIMP gOrigDataTaskReqComp = NULL;

static BOOL gInstalledSendEventHook   = NO;
static BOOL gInstalledURLSessionHooks = NO;
static BOOL gStoriesReadyAfterActive  = NO;

static std::atomic<double> gLastUserTouchTime{0.0};
static os_unfair_lock gStoryHookLock = OS_UNFAIR_LOCK_INIT;
static std::unordered_set<std::string> gHookedSnacksClasses;
static std::unordered_set<std::string> gHookedClassSelPairs;

static NSTimer *gActiveStoryLoopTimer = nil;

double FocusFBLastUserTouchTimestamp(void) {
    return gLastUserTouchTime.load(std::memory_order_relaxed);
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. NSURLProtocol Isolato che emette un vero NSHTTPURLResponse 200 in memoria
// ─────────────────────────────────────────────────────────────────────────────

@interface FFBStoryIncognitoURLProtocol : NSURLProtocol
@end

@implementation FFBStoryIncognitoURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *scheme = request.URL.scheme.lowercaseString;
    return [scheme isEqualToString:@"focusfb-incognito"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSURL *origURL = [NSURL URLWithString:@"https://graph.facebook.com/graphql"];
    NSDictionary<NSString *, NSString *> *headers = @{
        @"Content-Type": @"application/json; charset=utf-8"
    };
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:origURL
                                                          statusCode:200
                                                         HTTPVersion:@"HTTP/1.1"
                                                        headerFields:headers];
    NSData *payload = [@"{\"data\":{},\"extensions\":{\"is_final\":true}}" dataUsingEncoding:NSUTF8StringEncoding];
    id<NSURLProtocolClient> client = self.client;
    [client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (payload) {
        [client URLProtocol:self didLoadData:payload];
    }
    [client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

static NSURLSession *FFBIsolatedStoryMockSession(void) {
    static NSURLSession *mockSession = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.protocolClasses = @[FFBStoryIncognitoURLProtocol.class];
        cfg.URLCache = nil;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        mockSession = [NSURLSession sessionWithConfiguration:cfg];
    });
    return mockSession;
}

static NSURLRequest *FFBIsolatedStoryMockRequest(void) {
    static NSURLRequest *req = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *u = [NSURL URLWithString:@"focusfb-incognito://graphql/story-seen-ok"];
        req = [NSURLRequest requestWithURL:u];
    });
    return req;
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Rilevamento Visualizzatore Storie Attivo + Loop Video prima della Fine
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBControllerNameLooksLikeStoryViewer(NSString *clsName) {
    if (clsName.length == 0) return NO;
    NSString *lower = clsName.lowercaseString;
    if ([lower containsString:@"storiestray"] ||
        [lower containsString:@"inlinesnacks"] ||
        [lower containsString:@"traycell"]) {
        return NO;
    }
    // Nota: in Facebook iOS le Storie 24h usano il prefisso FBSnacks* (mai FBStory* che è il Feed)
    return ([lower hasPrefix:@"fbsnacks"] ||
            [lower containsString:@"snacksbucket"] ||
            [lower containsString:@"snacksviewer"] ||
            [lower containsString:@"snacksmedia"] ||
            [lower hasPrefix:@"lsstorybucket"] ||
            [lower containsString:@"storiesviewer"]);
}

static BOOL FFBCheckStoryViewerInControllerTree(UIViewController *vc, NSUInteger depth) {
    if (!vc || depth > 14) return NO;
    if (vc.isViewLoaded && !vc.view.hidden && vc.view.alpha > 0.01 && vc.view.window != nil) {
        if (FFBControllerNameLooksLikeStoryViewer(NSStringFromClass(vc.class))) {
            return YES;
        }
    }
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        if (FFBCheckStoryViewerInControllerTree(vc.presentedViewController, depth + 1)) {
            return YES;
        }
    }
    for (UIViewController *child in vc.childViewControllers) {
        if (FFBCheckStoryViewerInControllerTree(child, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

BOOL FocusFBIsStoryViewerVisibleNow(void) {
    if (!NSThread.isMainThread) return NO;
    UIWindow *win = FocusFBActiveWindow();
    if (!win || !win.rootViewController) return NO;
    return FFBCheckStoryViewerInControllerTree(win.rootViewController, 0);
}

static BOOL FFBHasActiveDraggingScrollView(UIView *root, NSUInteger depth) {
    if (!root || depth > 9 || root.hidden || root.alpha <= 0.01) return NO;
    if ([root isKindOfClass:UIScrollView.class]) {
        UIScrollView *sv = (UIScrollView *)root;
        if (sv.isTracking || sv.isDragging || sv.isDecelerating) {
            return YES;
        }
    }
    for (UIView *sub in root.subviews) {
        if (FFBHasActiveDraggingScrollView(sub, depth + 1)) return YES;
    }
    return NO;
}

static void FFBRewindNearEndStoryPlayersInView(UIView *view, NSUInteger depth, BOOL forceIfStopped) {
    if (!view || depth > 12 || view.hidden || view.alpha <= 0.01) return;
    @try {
        AVPlayer *player = nil;
        if ([view.layer isKindOfClass:AVPlayerLayer.class]) {
            player = ((AVPlayerLayer *)view.layer).player;
        }
        if (player && player.currentItem) {
            player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
            CMTime dur = player.currentItem.duration;
            CMTime cur = player.currentItem.currentTime;
            if (CMTIME_IS_NUMERIC(dur) && CMTIME_IS_NUMERIC(cur)) {
                Float64 durSec = CMTimeGetSeconds(dur);
                Float64 curSec = CMTimeGetSeconds(cur);
                if (durSec > 0.45 && (curSec >= durSec - 0.28 || (forceIfStopped && player.rate == 0.0f && curSec >= durSec - 0.6))) {
                    [player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                    [player play];
                }
            }
        }
    } @catch (__unused NSException *e) {
    }
    for (UIView *sub in view.subviews) {
        FFBRewindNearEndStoryPlayersInView(sub, depth + 1, forceIfStopped);
    }
}

static void FFBStartStoryLoopWatchdogIfNeeded(void) {
    if (!NSThread.isMainThread || gActiveStoryLoopTimer != nil) return;
    gActiveStoryLoopTimer = [NSTimer scheduledTimerWithTimeInterval:0.15
                                                            repeats:YES
                                                              block:^(NSTimer *timer) {
        if (!FocusFBIsStoryViewerVisibleNow()) {
            [timer invalidate];
            if (gActiveStoryLoopTimer == timer) {
                gActiveStoryLoopTimer = nil;
            }
            return;
        }
        FocusFBPrefs *prefs = [FocusFBPrefs shared];
        if (!prefs.enabled || !prefs.storiesDisableAutoAdvance) return;
        UIWindow *win = FocusFBActiveWindow();
        if (win) {
            FFBRewindNearEndStoryPlayersInView(win, 0, NO);
        }
    }];
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Filtro Rete / GraphQL per Mutazioni "Storia Visualizzata" (Seen State)
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBStringMatchesStorySeenMutation(NSString *text) {
    if (text.length < 8) return NO;
    static NSRegularExpression *seenRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        seenRegex = [NSRegularExpression
            regularExpressionWithPattern:@"(?:storiesUpdateSeenState)|(?:StoryUpdateSeenState)|(?:updateStorySeenState)|(?:StoriesSeenMutation)|(?:Snacks\\w*Seen\\w*Mutation)|(?:MarkStor\\w*Seen)|(?:story_card_seen)|(?:bucket_seen_state)"
                                 options:NSRegularExpressionCaseInsensitive
                                   error:nil];
    });
    return [seenRegex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] != nil;
}

BOOL FocusFBIsStorySeenNetworkRequest(NSURLRequest *request) {
    if (!request || !gStoriesReadyAfterActive) return NO;
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.storiesIncognitoMode) return NO;

    @try {
        // 1. Controllo istantaneo sull'header X-FB-Friendly-Name
        NSString *friendlyHdr = [request valueForHTTPHeaderField:@"X-FB-Friendly-Name"];
        if (friendlyHdr.length > 0) {
            return FFBStringMatchesStorySeenMutation(friendlyHdr);
        }

        // 2. Controllo leggero sul body solo per richieste POST GraphQL di piccole dimensioni
        NSURL *url = request.URL;
        NSString *path = url.path.lowercaseString ?: @"";
        if (![path containsString:@"graphql"]) return NO;

        NSData *body = request.HTTPBody;
        if (!body || body.length < 16 || body.length > 49152) return NO;

        NSString *raw = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        if (!raw) return NO;
        if (FFBStringMatchesStorySeenMutation(raw)) return YES;

        if ([raw containsString:@"%"]) {
            NSString *decoded = [raw stringByReplacingOccurrencesOfString:@"+" withString:@" "].stringByRemovingPercentEncoding;
            if (decoded && FFBStringMatchesStorySeenMutation(decoded)) {
                return YES;
            }
        }
    } @catch (__unused NSException *e) {
    }
    return NO;
}

static NSURLSessionDataTask *FFBHook_NSURLSession_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    if (FocusFBIsStorySeenNetworkRequest(request)) {
        NSURLSession *origSession = [self isKindOfClass:NSURLSession.class] ? (NSURLSession *)self : nil;
        if (origSession && origSession.delegate != nil) {
            return [FFBIsolatedStoryMockSession() dataTaskWithRequest:FFBIsolatedStoryMockRequest()
                                                    completionHandler:^(__unused NSData *d, __unused NSURLResponse *r, __unused NSError *e) {}];
        }
        return [FFBIsolatedStoryMockSession() dataTaskWithRequest:FFBIsolatedStoryMockRequest()];
    }
    return gOrigDataTaskReq ? gOrigDataTaskReq(self, _cmd, request) : nil;
}

static NSURLSessionDataTask *FFBHook_NSURLSession_dataTaskWithRequestCompletion(
    id self,
    SEL _cmd,
    NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    if (FocusFBIsStorySeenNetworkRequest(request)) {
        return [FFBIsolatedStoryMockSession() dataTaskWithRequest:FFBIsolatedStoryMockRequest()
                                                completionHandler:completionHandler];
    }
    return gOrigDataTaskReqComp ? gOrigDataTaskReqComp(self, _cmd, request, completionHandler) : nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. Hook Pigri (Lazy) e 100% ABI-Exact con imp_implementationWithBlock solo su FBSnacks*
// ─────────────────────────────────────────────────────────────────────────────

enum FFBStoryHookKind : int {
    FFBStoryHookKindBlockSeen = 1,
    FFBStoryHookKindBlockAutoAdvance = 2,
    FFBStoryHookKindTouchGatedTransition = 3,
};

// Restituisce il numero di argomenti oggetto puri (0..3 oltre a self e _cmd), oppure -1 se la firma non è v@:[@...]
static int FFBExactPureObjectArgCount(Method m) {
    if (!m) return -1;
    char retType[16] = {0};
    method_getReturnType(m, retType, sizeof(retType));
    if (retType[0] != 'v' || retType[1] != '\0') return -1;

    unsigned int nargs = method_getNumberOfArguments(m);
    if (nargs < 2 || nargs > 5) return -1;

    for (unsigned int i = 2; i < nargs; i++) {
        char argType[16] = {0};
        method_getArgumentType(m, i, argType, sizeof(argType));
        // Accetta esclusivamente argomenti oggetto standard ('@'), mai struct, blocchi speciali o scalari
        if (argType[0] != '@' || argType[1] != '\0') {
            return -1;
        }
    }
    return (int)(nargs - 2);
}

static BOOL FFBShouldBlockStoryCallNow(FFBStoryHookKind kind) {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled) return NO;

    if (kind == FFBStoryHookKindBlockSeen) {
        return prefs.storiesIncognitoMode;
    }
    if (!prefs.storiesDisableAutoAdvance) {
        return NO;
    }
    if (kind == FFBStoryHookKindBlockAutoAdvance) {
        if (NSThread.isMainThread) {
            UIWindow *win = FocusFBActiveWindow();
            if (win) FFBRewindNearEndStoryPlayersInView(win, 0, YES);
        }
        return YES;
    }
    if (kind == FFBStoryHookKindTouchGatedTransition) {
        double sinceTouch = CFAbsoluteTimeGetCurrent() - FocusFBLastUserTouchTimestamp();
        BOOL userScrolling = NO;
        if (NSThread.isMainThread) {
            UIWindow *win = FocusFBActiveWindow();
            if (win) userScrolling = FFBHasActiveDraggingScrollView(win, 0);
        }
        if (sinceTouch > 0.55 && !userScrolling) {
            if (NSThread.isMainThread) {
                UIWindow *win = FocusFBActiveWindow();
                if (win) FFBRewindNearEndStoryPlayersInView(win, 0, YES);
            }
            return YES;
        }
    }
    return NO;
}

static void FFBInstallBlockHookOnSnacksMethod(Class cls, Method m, FFBStoryHookKind kind) {
    int objArgs = FFBExactPureObjectArgCount(m);
    if (objArgs < 0) return;

    SEL sel = method_getName(m);
    IMP origIMP = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!sel || !origIMP || !types) return;

    std::string key = std::string(class_getName(cls)) + "::" + std::string(sel_getName(sel));
    os_unfair_lock_lock(&gStoryHookLock);
    bool inserted = gHookedClassSelPairs.insert(key).second;
    os_unfair_lock_unlock(&gStoryHookLock);
    if (!inserted) return;

    IMP newIMP = NULL;
    if (objArgs == 0) {
        typedef void (*Orig0)(id, SEL);
        Orig0 origFn = (Orig0)origIMP;
        newIMP = imp_implementationWithBlock(^(id selfObj) {
            if (FFBShouldBlockStoryCallNow(kind)) return;
            origFn(selfObj, sel);
        });
    } else if (objArgs == 1) {
        typedef void (*Orig1)(id, SEL, id);
        Orig1 origFn = (Orig1)origIMP;
        newIMP = imp_implementationWithBlock(^(id selfObj, id a1) {
            if (FFBShouldBlockStoryCallNow(kind)) return;
            origFn(selfObj, sel, a1);
        });
    } else if (objArgs == 2) {
        typedef void (*Orig2)(id, SEL, id, id);
        Orig2 origFn = (Orig2)origIMP;
        newIMP = imp_implementationWithBlock(^(id selfObj, id a1, id a2) {
            if (FFBShouldBlockStoryCallNow(kind)) return;
            origFn(selfObj, sel, a1, a2);
        });
    } else if (objArgs == 3) {
        typedef void (*Orig3)(id, SEL, id, id, id);
        Orig3 origFn = (Orig3)origIMP;
        newIMP = imp_implementationWithBlock(^(id selfObj, id a1, id a2, id a3) {
            if (FFBShouldBlockStoryCallNow(kind)) return;
            origFn(selfObj, sel, a1, a2, a3);
        });
    }

    if (newIMP) {
        class_replaceMethod(cls, sel, newIMP, types);
    }
}

static void FFBHookExactSnacksClassIfNeeded(Class cls) {
    if (!cls) return;
    const char *rawName = class_getName(cls);
    if (!rawName) return;

    // Sicurezza assoluta: opera SOLO su classi FBSnacks* (Storie 24h), mai su FBStory* (Feed) o Swift _TtC*
    if (strncmp(rawName, "FBSnacks", 8) != 0) return;

    std::string clsKey(rawName);
    os_unfair_lock_lock(&gStoryHookLock);
    bool alreadyDone = !gHookedSnacksClasses.insert(clsKey).second;
    os_unfair_lock_unlock(&gStoryHookLock);
    if (alreadyDone) return;

    NSString *lowerCls = [NSString stringWithUTF8String:rawName].lowercaseString;
    BOOL isSeenStateClass = ([lowerCls containsString:@"seenstate"] ||
                             [lowerCls containsString:@"seenmanager"]);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) return;

    for (unsigned int i = 0; i < count; i++) {
        Method m = methods[i];
        if (FFBExactPureObjectArgCount(m) < 0) continue;

        NSString *lowerSel = NSStringFromSelector(method_getName(m)).lowercaseString;
        if ([lowerSel hasPrefix:@"init"] ||
            [lowerSel hasPrefix:@"dealloc"] ||
            [lowerSel hasPrefix:@".cxx"] ||
            [lowerSel containsString:@"viewersheet"] ||
            [lowerSel containsString:@"viewerlist"]) {
            continue;
        }

        if (isSeenStateClass) {
            if ([lowerSel containsString:@"sendseen"] ||
                [lowerSel containsString:@"_sendseen"] ||
                [lowerSel containsString:@"markstory"] ||
                [lowerSel containsString:@"markbucket"] ||
                [lowerSel containsString:@"markthread"] ||
                [lowerSel containsString:@"updateseen"] ||
                [lowerSel containsString:@"reportseen"] ||
                [lowerSel containsString:@"flushseen"]) {
                FFBInstallBlockHookOnSnacksMethod(cls, m, FFBStoryHookKindBlockSeen);
                continue;
            }
        } else if ([lowerSel containsString:@"_sendseenthreadids"] ||
                   [lowerSel containsString:@"sendseenthreadids"] ||
                   [lowerSel containsString:@"markstoryseen"] ||
                   [lowerSel containsString:@"markstoryasseen"] ||
                   [lowerSel containsString:@"updateseenstate"]) {
            FFBInstallBlockHookOnSnacksMethod(cls, m, FFBStoryHookKindBlockSeen);
            continue;
        }

        if ([lowerSel containsString:@"autoadvance"] ||
            [lowerSel containsString:@"timerdidfinish"] ||
            [lowerSel containsString:@"timerdidexpire"] ||
            [lowerSel containsString:@"progressviewdidfinish"] ||
            [lowerSel containsString:@"progressbardidfinish"] ||
            [lowerSel containsString:@"mediaviewdidfinishplaying"] ||
            [lowerSel containsString:@"videoplaybackcontrollerdidfinish"]) {
            FFBInstallBlockHookOnSnacksMethod(cls, m, FFBStoryHookKindBlockAutoAdvance);
            continue;
        }

        if ([lowerSel containsString:@"advancetonext"] ||
            [lowerSel containsString:@"movetonextbucket"] ||
            [lowerSel containsString:@"transitiontonextbucket"] ||
            [lowerSel containsString:@"gotonextbucket"] ||
            [lowerSel containsString:@"shownextbucket"] ||
            [lowerSel containsString:@"_gotonextthread"]) {
            FFBInstallBlockHookOnSnacksMethod(cls, m, FFBStoryHookKindTouchGatedTransition);
            continue;
        }
    }

    free(methods);
}

static void FFBLazyHookKnownSnacksClasses(UIViewController *candidateVC) {
    static NSArray<NSString *> *knownNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownNames = @[
            @"FBSnacksBucketsSeenStateManager",
            @"FBSnacksSeenStateManager",
            @"FBSnacksTimerController",
            @"FBSnacksViewerViewController",
            @"FBSnacksBucketViewController",
            @"FBSnacksStackViewController",
            @"FBSnacksMediaContainerView"
        ];
    });

    for (NSString *name in knownNames) {
        Class c = NSClassFromString(name);
        if (c) FFBHookExactSnacksClassIfNeeded(c);
    }

    if (candidateVC) {
        Class vcCls = candidateVC.class;
        while (vcCls && vcCls != UIViewController.class && vcCls != NSObject.class) {
            FFBHookExactSnacksClassIfNeeded(vcCls);
            vcCls = class_getSuperclass(vcCls);
        }
        for (UIViewController *child in candidateVC.childViewControllers) {
            FFBHookExactSnacksClassIfNeeded(child.class);
        }
    }
}

void FocusFBNotifyStoryCandidateController(UIViewController *vc) {
    if (!vc || !gStoriesReadyAfterActive) return;
    NSString *clsName = NSStringFromClass(vc.class);
    if (!FFBControllerNameLooksLikeStoryViewer(clsName)) return;

    FFBLazyHookKnownSnacksClasses(vc);
    FFBStartStoryLoopWatchdogIfNeeded();
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Installazione Post-Avvio Sicura
// ─────────────────────────────────────────────────────────────────────────────

static void FFBHook_UIApplication_sendEvent(id self, SEL _cmd, UIEvent *event) {
    if (event && event.type == UIEventTypeTouches) {
        gLastUserTouchTime.store(CFAbsoluteTimeGetCurrent(), std::memory_order_relaxed);
    }
    if (gOrigAppSendEvent) {
        gOrigAppSendEvent(self, _cmd, event);
    }
}

static BOOL FFBReplaceMethodSimple(Class cls, SEL sel, IMP newIMP, IMP *origOut) {
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

static void FFBActivateStoriesHooksAfterBecomeActive(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!gInstalledSendEventHook) {
            gInstalledSendEventHook = FFBReplaceMethodSimple(UIApplication.class,
                                                             @selector(sendEvent:),
                                                             (IMP)FFBHook_UIApplication_sendEvent,
                                                             (IMP *)&gOrigAppSendEvent);
        }

        if (!gInstalledURLSessionHooks) {
            BOOL ok1 = FFBReplaceMethodSimple(NSURLSession.class,
                                              @selector(dataTaskWithRequest:),
                                              (IMP)FFBHook_NSURLSession_dataTaskWithRequest,
                                              (IMP *)&gOrigDataTaskReq);
            BOOL ok2 = FFBReplaceMethodSimple(NSURLSession.class,
                                              @selector(dataTaskWithRequest:completionHandler:),
                                              (IMP)FFBHook_NSURLSession_dataTaskWithRequestCompletion,
                                              (IMP *)&gOrigDataTaskReqComp);
            gInstalledURLSessionHooks = (ok1 || ok2);
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            FocusFBPrefs *prefs = [FocusFBPrefs shared];
            if (!prefs.enabled || !prefs.storiesDisableAutoAdvance) return;
            if (!FocusFBIsStoryViewerVisibleNow()) return;

            AVPlayerItem *item = [note.object isKindOfClass:AVPlayerItem.class] ? (AVPlayerItem *)note.object : nil;
            if (item) {
                [item seekToTime:kCMTimeZero completionHandler:nil];
            }
            UIWindow *win = FocusFBActiveWindow();
            if (win) {
                FFBRewindNearEndStoryPlayersInView(win, 0, YES);
            }
        }];

        gStoriesReadyAfterActive = YES;
    });
}

void FocusFBInstallStoriesManager(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            FFBActivateStoriesHooksAfterBecomeActive();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                FFBActivateStoriesHooksAfterBecomeActive();
            }
        });
    });
}
