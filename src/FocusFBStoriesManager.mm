#import "FocusFBStoriesManager.h"
#import "FocusFBPrefs.h"
#import "FocusFBTabManager.h"

#import <objc/runtime.h>
#import <objc/message.h>
#include <os/lock.h>
#include <unordered_set>
#include <string>

typedef NSURLSessionDataTask *(*FFBSessionTaskReqIMP)(id, SEL, NSURLRequest *);
typedef NSURLSessionDataTask *(*FFBSessionTaskReqCompIMP)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *));

static FFBSessionTaskReqIMP     gOrigDataTaskReq     = NULL;
static FFBSessionTaskReqCompIMP gOrigDataTaskReqComp = NULL;

static BOOL gInstalledURLSessionHooks = NO;
static BOOL gStoriesReady             = NO;

static os_unfair_lock gStoryHookLock = OS_UNFAIR_LOCK_INIT;
static std::unordered_set<std::string> gHookedSnacksClasses;
static std::unordered_set<std::string> gHookedClassSelPairs;

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
// 2. Rilevamento Visualizzatore Storie Full-Screen Attivo
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBControllerNameLooksLikeStoryViewer(NSString *clsName) {
    if (clsName.length == 0) return NO;
    NSString *lower = clsName.lowercaseString;
    if ([lower containsString:@"storiestray"] ||
        [lower containsString:@"snackstray"] ||
        [lower containsString:@"inlinesnacks"] ||
        [lower containsString:@"traycell"]) {
        return NO;
    }
    return ([lower hasPrefix:@"fbsnacks"] ||
            [lower containsString:@"snacksbucket"] ||
            [lower containsString:@"snacksviewer"] ||
            [lower containsString:@"snacksmedia"] ||
            [lower containsString:@"snacksthread"] ||
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
    if (!request || !gStoriesReady) return NO;
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (!prefs.enabled || !prefs.storiesIncognitoMode) return NO;

    @try {
        NSString *friendlyHdr = [request valueForHTTPHeaderField:@"X-FB-Friendly-Name"];
        if (friendlyHdr.length > 0) {
            return FFBStringMatchesStorySeenMutation(friendlyHdr);
        }

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
// 4. Hook Pigri (Lazy) e 100% ABI-Exact con imp_implementationWithBlock su FBSnacks*
// ─────────────────────────────────────────────────────────────────────────────

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
        if (argType[0] != '@' || argType[1] != '\0') {
            return -1;
        }
    }
    return (int)(nargs - 2);
}

static inline BOOL FFBIsIncognitoActiveNow(void) {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    return (prefs.enabled && prefs.storiesIncognitoMode);
}

static void FFBInstallSeenBlockOnSnacksMethod(Class cls, Method m) {
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
            if (FFBIsIncognitoActiveNow()) return;
            origFn(selfObj, sel);
        });
    } else if (objArgs == 1) {
        typedef void (*Orig1)(id, SEL, id);
        Orig1 origFn = (Orig1)origIMP;
        newIMP = imp_implementationWithBlock(^(id selfObj, id a1) {
            if (FFBIsIncognitoActiveNow()) return;
            origFn(selfObj, sel, a1);
        });
    } else if (objArgs == 2) {
        typedef void (*Orig2)(id, SEL, id, id);
        Orig2 origFn = (Orig2)origIMP;
        newIMP = imp_implementationWithBlock(^(id selfObj, id a1, id a2) {
            if (FFBIsIncognitoActiveNow()) return;
            origFn(selfObj, sel, a1, a2);
        });
    } else if (objArgs == 3) {
        typedef void (*Orig3)(id, SEL, id, id, id);
        Orig3 origFn = (Orig3)origIMP;
        newIMP = imp_implementationWithBlock(^(id selfObj, id a1, id a2, id a3) {
            if (FFBIsIncognitoActiveNow()) return;
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
    if (!rawName || strncmp(rawName, "FBSnacks", 8) != 0) return;

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
                FFBInstallSeenBlockOnSnacksMethod(cls, m);
            }
        } else if ([lowerSel containsString:@"_sendseenthreadids"] ||
                   [lowerSel containsString:@"sendseenthreadids"] ||
                   [lowerSel containsString:@"markstoryseen"] ||
                   [lowerSel containsString:@"markstoryasseen"] ||
                   [lowerSel containsString:@"updateseenstate"]) {
            FFBInstallSeenBlockOnSnacksMethod(cls, m);
        }
    }

    free(methods);
}

void FocusFBNotifyStoryCandidateController(UIViewController *vc) {
    if (!vc || !gStoriesReady) return;
    NSString *clsName = NSStringFromClass(vc.class);
    if (!FFBControllerNameLooksLikeStoryViewer(clsName)) return;

    static NSArray<NSString *> *knownNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownNames = @[
            @"FBSnacksBucketsSeenStateManager",
            @"FBSnacksSeenStateManager",
            @"FBSnacksViewerViewController",
            @"FBSnacksBucketViewController",
            @"FBSnacksThreadContainerViewController",
            @"FBSnacksMediaContainerViewController"
        ];
    });

    for (NSString *name in knownNames) {
        Class c = NSClassFromString(name);
        if (c) FFBHookExactSnacksClassIfNeeded(c);
    }

    Class vcCls = vc.class;
    while (vcCls && vcCls != UIViewController.class && vcCls != NSObject.class) {
        FFBHookExactSnacksClassIfNeeded(vcCls);
        vcCls = class_getSuperclass(vcCls);
    }
    for (UIViewController *child in vc.childViewControllers) {
        FFBHookExactSnacksClassIfNeeded(child.class);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Installazione Post-Avvio
// ─────────────────────────────────────────────────────────────────────────────

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

void FocusFBInstallStoriesManager(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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
        gStoriesReady = YES;
    });
}
