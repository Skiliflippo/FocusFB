#import "FocusFBStoriesManager.h"
#import "FocusFBPrefs.h"
#import "FocusFBTabManager.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <mach-o/dyld.h>
#include <os/lock.h>
#include <atomic>
#include <unordered_map>
#include <unordered_set>
#include <string>

typedef void (*FFBAppSendEventIMP)(id, SEL, UIEvent *);
typedef NSURLSessionDataTask *(*FFBSessionTaskReqIMP)(id, SEL, NSURLRequest *);
typedef NSURLSessionDataTask *(*FFBSessionTaskReqCompIMP)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));
typedef void (*FFBStoryTrampolineIMP)(id, SEL, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, double, double, double, double);

static FFBAppSendEventIMP       gOrigAppSendEvent      = NULL;
static FFBSessionTaskReqIMP     gOrigDataTaskReq       = NULL;
static FFBSessionTaskReqCompIMP gOrigDataTaskReqComp   = NULL;

static BOOL gInstalledSendEventHook   = NO;
static BOOL gInstalledURLSessionHooks = NO;

static std::atomic<double> gLastUserTouchTime{0.0};

struct FFBClassSelKey {
    Class cls;
    SEL sel;
    bool operator==(const FFBClassSelKey &o) const noexcept {
        return cls == o.cls && sel == o.sel;
    }
};

struct FFBClassSelHash {
    size_t operator()(const FFBClassSelKey &k) const noexcept {
        size_t h1 = reinterpret_cast<uintptr_t>(k.cls);
        size_t h2 = reinterpret_cast<uintptr_t>(k.sel);
        return h1 ^ (h2 * 0x9e3779b97f4a7c15ULL + (h1 << 6) + (h1 >> 2));
    }
};

static os_unfair_lock gStoryHookLock = OS_UNFAIR_LOCK_INIT;
static std::unordered_map<FFBClassSelKey, IMP, FFBClassSelHash> gOrigStoryIMPs;
static std::unordered_set<std::string> gScannedImagePaths;

double FocusFBLastUserTouchTimestamp(void) {
    return gLastUserTouchTime.load(std::memory_order_relaxed);
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Rilevamento Visualizzatore Storie Attivo + Loop Video a Fine Riproduzione
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBViewOrControllerLooksLikeStoryViewer(NSString *clsName) {
    if (clsName.length == 0) return NO;
    NSString *lower = clsName.lowercaseString;
    if ([lower containsString:@"storiestray"] ||
        [lower containsString:@"inlinesnacks"] ||
        [lower containsString:@"traycell"]) {
        return NO;
    }
    return ([lower hasPrefix:@"fbsnacks"] ||
            [lower containsString:@"snacksbucket"] ||
            [lower containsString:@"snacksviewer"] ||
            [lower containsString:@"snacksmedia"] ||
            [lower hasPrefix:@"lsstorybucket"] ||
            [lower containsString:@"storiesviewer"] ||
            [lower containsString:@"storyviewer"]);
}

static BOOL FFBCheckStoryViewerInControllerTree(UIViewController *vc, NSUInteger depth) {
    if (!vc || depth > 14) return NO;
    if (vc.isViewLoaded && !vc.view.hidden && vc.view.alpha > 0.01 && vc.view.window != nil) {
        if (FFBViewOrControllerLooksLikeStoryViewer(NSStringFromClass(vc.class))) {
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

static void FFBRewindEndedStoryPlayersInView(UIView *view, NSUInteger depth) {
    if (!view || depth > 12 || view.hidden || view.alpha <= 0.01) return;
    @try {
        AVPlayer *player = nil;
        if ([view.layer isKindOfClass:AVPlayerLayer.class]) {
            player = ((AVPlayerLayer *)view.layer).player;
        }
        if (player && player.currentItem) {
            CMTime dur = player.currentItem.duration;
            CMTime cur = player.currentItem.currentTime;
            if (CMTIME_IS_NUMERIC(dur) && CMTIME_IS_NUMERIC(cur)) {
                Float64 durSec = CMTimeGetSeconds(dur);
                Float64 curSec = CMTimeGetSeconds(cur);
                if (durSec > 0.4 && (curSec >= durSec - 0.35 || player.rate == 0.0f)) {
                    player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
                    [player seekToTime:kCMTimeZero toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
                    [player play];
                }
            }
        }
    } @catch (__unused NSException *e) {
    }
    for (UIView *sub in view.subviews) {
        FFBRewindEndedStoryPlayersInView(sub, depth + 1);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Filtro Rete / GraphQL per Mutazioni "Storia Visualizzata" (Seen State)
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
    if (!request) return NO;
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.storiesIncognitoMode) return NO;

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
    return NO;
}

static NSURLRequest *FFBMockEmptyGraphQLSuccessRequest(void) {
    // data: URL gestito interamente in memoria da NSURLSession (zero traffico di rete,
    // task reale valido, risposta JSON {"data":{},"extensions":{"is_final":true}}).
    static NSURLRequest *mockReq = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *u = [NSURL URLWithString:@"data:application/json,%7B%22data%22%3A%7B%7D%2C%22extensions%22%3A%7B%22is_final%22%3Atrue%7D%7D"];
        mockReq = [NSURLRequest requestWithURL:u];
    });
    return mockReq;
}

static NSURLSessionDataTask *FFBHook_NSURLSession_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    if (FocusFBIsStorySeenNetworkRequest(request)) {
        request = FFBMockEmptyGraphQLSuccessRequest();
    }
    return gOrigDataTaskReq ? gOrigDataTaskReq(self, _cmd, request) : nil;
}

static NSURLSessionDataTask *FFBHook_NSURLSession_dataTaskWithRequestCompletion(
    id self,
    SEL _cmd,
    NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    if (FocusFBIsStorySeenNetworkRequest(request)) {
        request = FFBMockEmptyGraphQLSuccessRequest();
    }
    return gOrigDataTaskReqComp ? gOrigDataTaskReqComp(self, _cmd, request, completionHandler) : nil;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Hook Runtime Objective-C su FBSnacks* / FBStories* / LSStory* (ABI-Safe)
// ─────────────────────────────────────────────────────────────────────────────

static IMP FFBLookupOrigStoryIMP(id obj, SEL sel) {
    Class cur = object_getClass(obj);
    os_unfair_lock_lock(&gStoryHookLock);
    IMP found = NULL;
    while (cur != Nil) {
        auto it = gOrigStoryIMPs.find(FFBClassSelKey{cur, sel});
        if (it != gOrigStoryIMPs.end()) {
            found = it->second;
            break;
        }
        cur = class_getSuperclass(cur);
    }
    os_unfair_lock_unlock(&gStoryHookLock);
    return found;
}

static BOOL FFBIsABISafeVoidMethod(Method m) {
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || enc[0] != 'v') return NO;
    // Escludi qualsiasi metodo con argomenti struct, array, union o long double
    for (const char *p = enc; *p != '\0'; ++p) {
        if (*p == '{' || *p == '[' || *p == '(' || *p == 'D') {
            return NO;
        }
    }
    unsigned int nargs = method_getNumberOfArguments(m);
    return (nargs >= 2 && nargs <= 7);
}

static void FFBInstallStoryVoidHook(Class cls, Method m, IMP hookIMP) {
    if (!cls || !m || !hookIMP || !FFBIsABISafeVoidMethod(m)) return;
    SEL sel = method_getName(m);
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!orig || !types || orig == hookIMP) return;

    os_unfair_lock_lock(&gStoryHookLock);
    FFBClassSelKey key{cls, sel};
    if (gOrigStoryIMPs.find(key) != gOrigStoryIMPs.end()) {
        os_unfair_lock_unlock(&gStoryHookLock);
        return;
    }
    gOrigStoryIMPs[key] = orig;
    os_unfair_lock_unlock(&gStoryHookLock);

    class_replaceMethod(cls, sel, hookIMP, types);
}

// Trampoline A: blocca l'invio dello stato "visto" delle Storie quando storiesIncognitoMode è attivo
static void FFBTrampoline_BlockStorySeen(id self, SEL _cmd,
                                         uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6,
                                         double d0, double d1, double d2, double d3) {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (prefs.enabled && prefs.storiesIncognitoMode) {
        return;
    }
    FFBStoryTrampolineIMP orig = (FFBStoryTrampolineIMP)FFBLookupOrigStoryIMP(self, _cmd);
    if (orig) {
        orig(self, _cmd, a2, a3, a4, a5, a6, d0, d1, d2, d3);
    }
}

// Trampoline B: blocca il completamento automatico del timer / fine video nelle Storie
static void FFBTrampoline_BlockAutoAdvanceExplicit(id self, SEL _cmd,
                                                   uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6,
                                                   double d0, double d1, double d2, double d3) {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (prefs.enabled && prefs.storiesDisableAutoAdvance) {
        if (NSThread.isMainThread) {
            UIWindow *win = FocusFBActiveWindow();
            if (win) FFBRewindEndedStoryPlayersInView(win, 0);
        }
        return;
    }
    FFBStoryTrampolineIMP orig = (FFBStoryTrampolineIMP)FFBLookupOrigStoryIMP(self, _cmd);
    if (orig) {
        orig(self, _cmd, a2, a3, a4, a5, a6, d0, d1, d2, d3);
    }
}

// Trampoline C: consente cambio persona/storia SOLO se l'utente ha appena toccato o trascinato lo schermo
static void FFBTrampoline_TouchGatedNextStory(id self, SEL _cmd,
                                              uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5, uintptr_t a6,
                                              double d0, double d1, double d2, double d3) {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (prefs.enabled && prefs.storiesDisableAutoAdvance) {
        double sinceTouch = CFAbsoluteTimeGetCurrent() - FocusFBLastUserTouchTimestamp();
        BOOL userScrolling = NO;
        if (NSThread.isMainThread) {
            UIWindow *win = FocusFBActiveWindow();
            if (win) userScrolling = FFBHasActiveDraggingScrollView(win, 0);
        }
        if (sinceTouch > 0.55 && !userScrolling) {
            if (NSThread.isMainThread) {
                UIWindow *win = FocusFBActiveWindow();
                if (win) FFBRewindEndedStoryPlayersInView(win, 0);
            }
            return;
        }
    }
    FFBStoryTrampolineIMP orig = (FFBStoryTrampolineIMP)FFBLookupOrigStoryIMP(self, _cmd);
    if (orig) {
        orig(self, _cmd, a2, a3, a4, a5, a6, d0, d1, d2, d3);
    }
}

static void FFBInspectAndHookStoryClass(Class cls, const char *rawClsName) {
    if (!cls || !rawClsName) return;
    NSString *clsName = [NSString stringWithUTF8String:rawClsName];
    NSString *lowerCls = clsName.lowercaseString;

    BOOL isSnacksOrStory = ([lowerCls hasPrefix:@"fbsnacks"] ||
                            [lowerCls hasPrefix:@"fbstories"] ||
                            [lowerCls hasPrefix:@"fbstory"] ||
                            [lowerCls hasPrefix:@"lsstory"]);
    if (!isSnacksOrStory) return;

    BOOL isSeenManagerClass = ([lowerCls containsString:@"seenstate"] ||
                               [lowerCls containsString:@"seenmanager"] ||
                               [lowerCls hasSuffix:@"seen"]);

    unsigned int methodCount = 0;
    Method *methods = class_copyMethodList(cls, &methodCount);
    if (!methods) return;

    for (unsigned int i = 0; i < methodCount; i++) {
        Method m = methods[i];
        if (!FFBIsABISafeVoidMethod(m)) continue;

        SEL sel = method_getName(m);
        NSString *selStr = NSStringFromSelector(sel);
        NSString *lowerSel = selStr.lowercaseString;

        // Escludi getter / viewer sheet (così puoi sempre vedere chi ha visualizzato la TUA storia)
        if ([lowerSel containsString:@"viewersheet"] ||
            [lowerSel containsString:@"viewerlist"] ||
            [lowerSel hasPrefix:@"get"] ||
            [lowerSel hasPrefix:@"is"] ||
            [lowerSel hasPrefix:@"has"]) {
            continue;
        }

        // 1. Hook Incognito (Seen State)
        if (isSeenManagerClass) {
            if ([lowerSel containsString:@"send"] ||
                [lowerSel containsString:@"mark"] ||
                [lowerSel containsString:@"report"] ||
                [lowerSel containsString:@"record"] ||
                [lowerSel containsString:@"update"] ||
                [lowerSel containsString:@"flush"] ||
                [lowerSel containsString:@"sync"] ||
                [lowerSel containsString:@"didsee"] ||
                [lowerSel containsString:@"didview"]) {
                FFBInstallStoryVoidHook(cls, m, (IMP)FFBTrampoline_BlockStorySeen);
                continue;
            }
        } else if ([lowerSel containsString:@"seen"] &&
                   ([lowerSel containsString:@"sendseen"] ||
                    [lowerSel containsString:@"_sendseen"] ||
                    [lowerSel containsString:@"markstoryseen"] ||
                    [lowerSel containsString:@"markstoryasseen"] ||
                    [lowerSel containsString:@"markbucketseen"] ||
                    [lowerSel containsString:@"markthreadseen"] ||
                    [lowerSel containsString:@"reportseen"] ||
                    [lowerSel containsString:@"updateseenstate"])) {
            FFBInstallStoryVoidHook(cls, m, (IMP)FFBTrampoline_BlockStorySeen);
            continue;
        }

        // 2. Hook Blocco Avanzamento Automatico (Timer / Fine Riproduzione)
        if ([lowerSel containsString:@"autoadvance"] ||
            [lowerSel containsString:@"timerdidfinish"] ||
            [lowerSel containsString:@"timerdidexpire"] ||
            [lowerSel containsString:@"storytimerdid"] ||
            [lowerSel containsString:@"progressviewdidfinish"] ||
            [lowerSel containsString:@"progressbardidfinish"] ||
            [lowerSel containsString:@"mediaviewdidfinishplaying"] ||
            [lowerSel containsString:@"videoplaybackcontrollerdidfinish"]) {
            FFBInstallStoryVoidHook(cls, m, (IMP)FFBTrampoline_BlockAutoAdvanceExplicit);
            continue;
        }

        // 3. Hook Transizione Bucket / Persona successiva (consentita solo su tocco/swipe reale)
        if ([lowerSel containsString:@"advancetonext"] ||
            [lowerSel containsString:@"movetonextbucket"] ||
            [lowerSel containsString:@"transitiontonextbucket"] ||
            [lowerSel containsString:@"gotonextbucket"] ||
            [lowerSel containsString:@"shownextbucket"] ||
            [lowerSel containsString:@"_gotonextthread"]) {
            FFBInstallStoryVoidHook(cls, m, (IMP)FFBTrampoline_TouchGatedNextStory);
            continue;
        }
    }

    free(methods);
}

static BOOL FFBShouldScanImagePathForStories(const char *imagePath) {
    if (!imagePath) return NO;
    if (strstr(imagePath, "/System/Library/") != NULL ||
        strstr(imagePath, "/usr/lib/") != NULL ||
        strstr(imagePath, "FocusFB.dylib") != NULL ||
        strstr(imagePath, "LiveContainer") != NULL) {
        return NO;
    }
    return (strstr(imagePath, ".app/") != NULL);
}

static void FFBScanLoadedFacebookImagesForStoryClasses(void) {
    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *imgPath = _dyld_get_image_name(i);
        if (!FFBShouldScanImagePathForStories(imgPath)) continue;

        os_unfair_lock_lock(&gStoryHookLock);
        bool alreadyScanned = !gScannedImagePaths.insert(std::string(imgPath)).second;
        os_unfair_lock_unlock(&gStoryHookLock);
        if (alreadyScanned) continue;

        unsigned int clsCount = 0;
        const char **clsNames = objc_copyClassNamesForImage(imgPath, &clsCount);
        if (!clsNames) continue;

        for (unsigned int c = 0; c < clsCount; c++) {
            const char *name = clsNames[c];
            if (!name) continue;
            // Prefiltro C ultra-rapido: ispeziona solo classi che iniziano per FB o LS
            if (!((name[0] == 'F' && name[1] == 'B') || (name[0] == 'L' && name[1] == 'S'))) {
                continue;
            }
            if (strstr(name, "Snacks") == NULL &&
                strstr(name, "Stor") == NULL &&
                strstr(name, "stor") == NULL) {
                continue;
            }
            Class cls = objc_lookUpClass(name);
            if (cls) {
                FFBInspectAndHookStoryClass(cls, name);
            }
        }
        free(clsNames);
    }
}

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

static void FFBStoriesDyldImageAdded(const struct mach_header *mh, __unused intptr_t slide) {
    (void)mh;
    dispatch_async(dispatch_get_main_queue(), ^{
        FFBScanLoadedFacebookImagesForStoryClasses();
    });
}

void FocusFBInstallStoriesManager(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. Tracciamento leggero dei tocchi per distinguere tap/swipe reali dal timer automatico
        if (!gInstalledSendEventHook) {
            gInstalledSendEventHook = FFBReplaceMethodSimple(UIApplication.class,
                                                             @selector(sendEvent:),
                                                             (IMP)FFBHook_UIApplication_sendEvent,
                                                             (IMP *)&gOrigAppSendEvent);
        }

        // 2. Intercettazione richieste HTTP/GraphQL di conferma visualizzazione Storie su NSURLSession
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

        // 3. Loop automatico quando un video dentro le Storie arriva alla fine (evita freeze o salto)
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
                FFBRewindEndedStoryPlayersInView(win, 0);
            }
        }];

        // 4. Scansione classi FBSnacks / FBStories / LSStory immediata + per framework caricati pigramente
        FFBScanLoadedFacebookImagesForStoryClasses();
        _dyld_register_func_for_add_image(FFBStoriesDyldImageAdded);
    });
}
