#import "FocusFBSideloadFix.h"
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>

typedef NSURL *(*FFBContainerURLIMP)(id, SEL, NSString *);
typedef NSString *(*FFBAccessGroupIMP)(id, SEL);

static FFBContainerURLIMP gOrigContainerURL = NULL;
static NSURL *gFallbackGroupBaseURL = nil;
static NSMutableSet<NSString *> *gPatchedKeychainClasses = nil;

static void FFBEnsureDirectory(NSURL *url) {
    if (!url) return;
    if (![url checkResourceIsReachableAndReturnError:nil]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:url
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    }
}

static NSString *FFBProbedKeychainAccessGroup(void) {
    static NSString *cachedGroup = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"focusfb_probe_acct",
            (__bridge id)kSecAttrService: @"focusfb_probe_svc",
            (__bridge id)kSecReturnAttributes: @YES
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
        if (status == errSecItemNotFound) {
            status = SecItemAdd((__bridge CFDictionaryRef)query, &result);
        }
        if (status == errSecSuccess && result) {
            NSDictionary *attrs = (__bridge NSDictionary *)result;
            NSString *group = attrs[(__bridge id)kSecAttrAccessGroup];
            if ([group isKindOfClass:NSString.class] && group.length > 0) {
                cachedGroup = [group copy];
            }
        }
        if (result) {
            CFRelease(result);
        }
    });
    return cachedGroup;
}

static NSURL *FFBHook_containerURLForSecurityApplicationGroupIdentifier(id self, SEL _cmd, NSString *groupIdentifier) {
    NSURL *realURL = nil;
    if (gOrigContainerURL) {
        realURL = gOrigContainerURL(self, _cmd, groupIdentifier);
    }
    if (realURL) {
        return realURL;
    }
    NSString *safeName = (groupIdentifier.length > 0) ? groupIdentifier : @"default.group";
    NSURL *fallback = [gFallbackGroupBaseURL URLByAppendingPathComponent:safeName isDirectory:YES];
    FFBEnsureDirectory(fallback);
    FFBEnsureDirectory([fallback URLByAppendingPathComponent:@"Library" isDirectory:YES]);
    FFBEnsureDirectory([fallback URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES]);
    return fallback;
}

static NSString *FFBHook_accessGroup(id self, SEL _cmd) {
    return FFBProbedKeychainAccessGroup();
}

static void FFBNoOpSetVocab(id self, SEL _cmd, id arg1, NSInteger arg2) {
    // No-op per evitare crash da mancanza di com.apple.developer.siri in sideloading
}

static void FFBNoOpVoid(id self, SEL _cmd) {
    // No-op
}

static BOOL FFBHasOtherSideloadFixerLoaded(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *raw = _dyld_get_image_name(i);
        if (!raw) continue;
        NSString *name = [[NSString stringWithUTF8String:raw] lastPathComponent].lowercaseString;
        if ([name isEqualToString:@"glow.dylib"] ||
            [name containsString:@"sideloadfix"] ||
            [name containsString:@" sideloadbypass"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL FFBIsOfficiallySignedFacebook(void) {
    @try {
        Class proxyCls = NSClassFromString(@"LSApplicationProxy");
        SEL proxySel = NSSelectorFromString(@"bundleProxyForCurrentProcess");
        SEL entSel = NSSelectorFromString(@"entitlements");
        if (proxyCls && [proxyCls respondsToSelector:proxySel]) {
            id proxy = ((id (*)(id, SEL))objc_msgSend)(proxyCls, proxySel);
            if (proxy && [proxy respondsToSelector:entSel]) {
                NSDictionary *ent = ((id (*)(id, SEL))objc_msgSend)(proxy, entSel);
                if ([ent isKindOfClass:NSDictionary.class]) {
                    NSString *appID = ent[@"application-identifier"];
                    if ([appID isKindOfClass:NSString.class] && [appID hasPrefix:@"T84QZS65DQ."]) {
                        return YES;
                    }
                }
            }
        }
    } @catch (__unused NSException *e) {
    }
    return NO;
}

static void FFBReplaceInstanceMethod(Class cls, SEL sel, IMP newIMP, IMP *origOut) {
    if (!cls || !sel || !newIMP) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    const char *types = method_getTypeEncoding(m);
    if (!orig || !types || orig == newIMP) return;
    if (origOut && *origOut == NULL) {
        *origOut = orig;
    }
    if (!class_addMethod(cls, sel, newIMP, types)) {
        method_setImplementation(m, newIMP);
    }
}

static void FFBPatchKeychainClassesNow(void) {
    if (!FFBProbedKeychainAccessGroup()) return;
    NSArray<NSString *> *classNames = @[
        @"FBSDKKeychainStore",
        @"FBKeychainItemController",
        @"FBBaseKeychainStoreDelegate",
        @"UICKeyChainStore",
        @"LSKeychainItemController",
        @"LSKeychainMultiItemController",
        @"FXDeviceKeychainQuery",
        @"FXAccountKeychainQuery"
    ];
    SEL sel = @selector(accessGroup);
    @synchronized (gPatchedKeychainClasses) {
        for (NSString *name in classNames) {
            if ([gPatchedKeychainClasses containsObject:name]) continue;
            Class cls = NSClassFromString(name);
            if (!cls) continue;
            FFBReplaceInstanceMethod(cls, sel, (IMP)FFBHook_accessGroup, NULL);
            [gPatchedKeychainClasses addObject:name];
        }
    }
}

void FocusFBInstallSideloadFixesIfNeeded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (FFBIsOfficiallySignedFacebook() || FFBHasOtherSideloadFixerLoaded()) {
            return;
        }

        gPatchedKeychainClasses = [NSMutableSet set];
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FocusFB_AppGroups"];
        gFallbackGroupBaseURL = [NSURL fileURLWithPath:docs isDirectory:YES];
        FFBEnsureDirectory(gFallbackGroupBaseURL);

        // 1. Fallback sicuro per App Groups (usato solo se il container reale restituisce nil)
        FFBReplaceInstanceMethod(NSFileManager.class,
                                 @selector(containerURLForSecurityApplicationGroupIdentifier:),
                                 (IMP)FFBHook_containerURLForSecurityApplicationGroupIdentifier,
                                 (IMP *)&gOrigContainerURL);

        // 2. Siri Vocabulary crash guard (Sideloading senza entitlement Siri)
        Class vocabCls = NSClassFromString(@"INVocabulary");
        if (vocabCls) {
            FFBReplaceInstanceMethod(vocabCls, NSSelectorFromString(@"setVocabularyStrings:ofType:"), (IMP)FFBNoOpSetVocab, NULL);
            FFBReplaceInstanceMethod(vocabCls, NSSelectorFromString(@"setVocabulary:ofType:"), (IMP)FFBNoOpSetVocab, NULL);
            FFBReplaceInstanceMethod(vocabCls, NSSelectorFromString(@"_THROW_EXCEPTION_FOR_PROCESS_MISSING_ENTITLEMENT_com_apple_developer_siri"), (IMP)FFBNoOpVoid, NULL);
        }

        // 3. Keychain Access Group fix (immediato + differito per framework caricati dopo il boot)
        FFBPatchKeychainClassesNow();
        for (NSNumber *delay in @[@0.4, @1.5, @4.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                FFBPatchKeychainClassesNow();
            });
        }
    });
}
