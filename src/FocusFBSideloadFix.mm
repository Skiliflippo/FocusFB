#import "FocusFBSideloadFix.h"
#import "FocusFBFishhook.h"
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>

typedef NSURL *(*FFBContainerURLIMP)(id, SEL, NSString *);
typedef id (*FFBInfoKeyIMP)(id, SEL, NSString *);

typedef OSStatus (*FFBSecItemAddFn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*FFBSecItemCopyMatchingFn)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*FFBSecItemUpdateFn)(CFDictionaryRef, CFDictionaryRef);
typedef OSStatus (*FFBSecItemDeleteFn)(CFDictionaryRef);
typedef SecKeyRef (*FFBSecKeyCreateRandomKeyFn)(CFDictionaryRef, CFErrorRef *);

static FFBContainerURLIMP gOrigContainerURL = NULL;
static FFBInfoKeyIMP gOrigObjectForInfoKey = NULL;

static FFBSecItemAddFn gOrigSecItemAdd = NULL;
static FFBSecItemCopyMatchingFn gOrigSecItemCopyMatching = NULL;
static FFBSecItemUpdateFn gOrigSecItemUpdate = NULL;
static FFBSecItemDeleteFn gOrigSecItemDelete = NULL;
static FFBSecKeyCreateRandomKeyFn gOrigSecKeyCreateRandomKey = NULL;

static NSURL *gFallbackGroupBaseURL = nil;
static NSMutableSet<NSString *> *gPatchedKeychainClasses = nil;
static NSString *gCachedValidAccessGroup = nil;

static id FFBHook_objectForInfoDictionaryKey(id self, SEL _cmd, NSString *key) {
    id orig = gOrigObjectForInfoKey ? gOrigObjectForInfoKey(self, _cmd, key) : nil;
    if (!orig && self == [NSBundle mainBundle]) {
        if ([key isEqualToString:@"NFCReaderUsageDescription"]) {
            return @"Scansione tag NFC per sbloccare FocusFB.";
        }
        if ([key isEqualToString:@"NSCameraUsageDescription"]) {
            return @"Scansione codice QR o a barre per sbloccare FocusFB.";
        }
    }
    return orig;
}

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
                gCachedValidAccessGroup = [group copy];
            }
        }
        if (result) {
            CFRelease(result);
        }
    });
    return gCachedValidAccessGroup;
}

// ─────────────────────────────────────────────────────────────────────────────
// Sanitizzazione C-level Keychain (evita logout ripetuti da errore -34018)
// Facebook v580+ ruota i token di sessione e le chiavi dispositivo passando
// direttamente in C kSecAttrAccessGroup = "T84QZS65DQ.platformFamily" (Team Meta).
// In sideloading quell'entitlement non esiste -> iOS rifiuta il salvataggio del
// nuovo token (-34018 errSecMissingEntitlement) e Facebook disconnette l'account.
// Rimuovendo il kSecAttrAccessGroup estraneo su una copia del dizionario, iOS
// (o LiveContainer) usa automaticamente il gruppo valido del contenitore corrente.
// ─────────────────────────────────────────────────────────────────────────────

static BOOL FFBIsForeignAccessGroup(id groupObj) {
    if (![groupObj isKindOfClass:NSString.class]) return NO;
    NSString *grp = (NSString *)groupObj;
    if (grp.length == 0) return YES;
    if (gCachedValidAccessGroup.length > 0 && [grp isEqualToString:gCachedValidAccessGroup]) {
        return NO;
    }
    return YES;
}

static NSDictionary *FFBSanitizeKeychainDict(CFDictionaryRef rawDict, BOOL aggressiveRetry) {
    if (!rawDict) return nil;
    NSDictionary *src = (__bridge NSDictionary *)rawDict;

    id topGroup = src[(__bridge id)kSecAttrAccessGroup];
    NSDictionary *privAttrs = [src[(__bridge id)kSecPrivateKeyAttrs] isKindOfClass:NSDictionary.class]
        ? src[(__bridge id)kSecPrivateKeyAttrs] : nil;
    NSDictionary *pubAttrs = [src[(__bridge id)kSecPublicKeyAttrs] isKindOfClass:NSDictionary.class]
        ? src[(__bridge id)kSecPublicKeyAttrs] : nil;

    BOOL needsTopFix = (topGroup != nil && FFBIsForeignAccessGroup(topGroup));
    BOOL needsPrivFix = (privAttrs && privAttrs[(__bridge id)kSecAttrAccessGroup] != nil &&
                         FFBIsForeignAccessGroup(privAttrs[(__bridge id)kSecAttrAccessGroup]));
    BOOL needsPubFix = (pubAttrs && pubAttrs[(__bridge id)kSecAttrAccessGroup] != nil &&
                        FFBIsForeignAccessGroup(pubAttrs[(__bridge id)kSecAttrAccessGroup]));

    if (!needsTopFix && !needsPrivFix && !needsPubFix && !aggressiveRetry) {
        return src;
    }

    NSMutableDictionary *copy = [src mutableCopy];
    if (needsTopFix || aggressiveRetry) {
        [copy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
    }
    if (aggressiveRetry) {
        [copy removeObjectForKey:(__bridge id)kSecAttrSynchronizable];
    }
    if (needsPrivFix || (aggressiveRetry && privAttrs)) {
        NSMutableDictionary *pCopy = [privAttrs mutableCopy];
        [pCopy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        copy[(__bridge id)kSecPrivateKeyAttrs] = pCopy;
    }
    if (needsPubFix || (aggressiveRetry && pubAttrs)) {
        NSMutableDictionary *pCopy = [pubAttrs mutableCopy];
        [pCopy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];
        copy[(__bridge id)kSecPublicKeyAttrs] = pCopy;
    }
    return copy;
}

static OSStatus FFBHook_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    FFBSecItemAddFn orig = gOrigSecItemAdd ?: &SecItemAdd;
    NSDictionary *clean = FFBSanitizeKeychainDict(attributes, NO);
    OSStatus st = orig((__bridge CFDictionaryRef)clean, result);
    if (st == -34018 || st == errSecNoAccessForItem) {
        NSDictionary *retry = FFBSanitizeKeychainDict(attributes, YES);
        st = orig((__bridge CFDictionaryRef)retry, result);
    }
    return st;
}

static OSStatus FFBHook_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    FFBSecItemCopyMatchingFn orig = gOrigSecItemCopyMatching ?: &SecItemCopyMatching;
    NSDictionary *clean = FFBSanitizeKeychainDict(query, NO);
    OSStatus st = orig((__bridge CFDictionaryRef)clean, result);
    if (st == -34018 || st == errSecNoAccessForItem) {
        NSDictionary *retry = FFBSanitizeKeychainDict(query, YES);
        st = orig((__bridge CFDictionaryRef)retry, result);
    }
    return st;
}

static OSStatus FFBHook_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    FFBSecItemUpdateFn orig = gOrigSecItemUpdate ?: &SecItemUpdate;
    NSDictionary *cleanQuery = FFBSanitizeKeychainDict(query, NO);
    NSDictionary *cleanUpdate = FFBSanitizeKeychainDict(attributesToUpdate, NO);
    OSStatus st = orig((__bridge CFDictionaryRef)cleanQuery, (__bridge CFDictionaryRef)cleanUpdate);
    if (st == -34018 || st == errSecNoAccessForItem) {
        NSDictionary *retryQuery = FFBSanitizeKeychainDict(query, YES);
        NSDictionary *retryUpdate = FFBSanitizeKeychainDict(attributesToUpdate, YES);
        st = orig((__bridge CFDictionaryRef)retryQuery, (__bridge CFDictionaryRef)retryUpdate);
    }
    return st;
}

static OSStatus FFBHook_SecItemDelete(CFDictionaryRef query) {
    FFBSecItemDeleteFn orig = gOrigSecItemDelete ?: &SecItemDelete;
    NSDictionary *clean = FFBSanitizeKeychainDict(query, NO);
    OSStatus st = orig((__bridge CFDictionaryRef)clean);
    if (st == -34018 || st == errSecNoAccessForItem) {
        NSDictionary *retry = FFBSanitizeKeychainDict(query, YES);
        st = orig((__bridge CFDictionaryRef)retry);
    }
    return st;
}

static SecKeyRef FFBHook_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    FFBSecKeyCreateRandomKeyFn orig = gOrigSecKeyCreateRandomKey ?: &SecKeyCreateRandomKey;
    NSDictionary *clean = FFBSanitizeKeychainDict(parameters, NO);
    CFErrorRef localErr = NULL;
    SecKeyRef key = orig((__bridge CFDictionaryRef)clean, &localErr);
    if (!key && localErr) {
        CFIndex code = CFErrorGetCode(localErr);
        if (code == -34018 || code == errSecNoAccessForItem) {
            CFRelease(localErr);
            localErr = NULL;
            NSDictionary *retry = FFBSanitizeKeychainDict(parameters, YES);
            key = orig((__bridge CFDictionaryRef)retry, &localErr);
        }
    }
    if (error) {
        *error = localErr;
    } else if (localErr) {
        CFRelease(localErr);
    }
    return key;
}

static NSURL *FFBHook_containerURLForSecurityApplicationGroupIdentifier(id self, SEL _cmd, NSString *groupIdentifier) {
    if (gOrigContainerURL) {
        NSURL *realURL = gOrigContainerURL(self, _cmd, groupIdentifier);
        if (realURL) {
            return realURL;
        }
    }

    NSString *safeName = (groupIdentifier.length > 0) ? groupIdentifier : @"default.group";
    NSURL *fallback = [gFallbackGroupBaseURL URLByAppendingPathComponent:safeName isDirectory:YES];
    FFBEnsureDirectory(fallback);
    FFBEnsureDirectory([fallback URLByAppendingPathComponent:@"Documents" isDirectory:YES]);
    FFBEnsureDirectory([fallback URLByAppendingPathComponent:@"Library" isDirectory:YES]);
    FFBEnsureDirectory([fallback URLByAppendingPathComponent:@"Library/Caches" isDirectory:YES]);
    FFBEnsureDirectory([fallback URLByAppendingPathComponent:@"Library/Preferences" isDirectory:YES]);
    FFBEnsureDirectory([fallback URLByAppendingPathComponent:@"Library/Application Support" isDirectory:YES]);
    return fallback;
}

static NSString *FFBHook_accessGroup(id self, SEL _cmd) {
    return FFBProbedKeychainAccessGroup();
}

static void FFBNoOpSetVocab(id self, SEL _cmd, id arg1, NSInteger arg2) {
    // Evita crash da mancanza di com.apple.developer.siri in sideloading
}

static void FFBNoOpVoid(id self, SEL _cmd) {
}

static BOOL FFBHasOtherSideloadFixerLoaded(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *raw = _dyld_get_image_name(i);
        if (!raw) continue;
        NSString *name = [[NSString stringWithUTF8String:raw] lastPathComponent].lowercaseString;
        if ([name isEqualToString:@"glow.dylib"] ||
            [name containsString:@"sideloadfix"] ||
            [name containsString:@"sideloadbypass"]) {
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
        @"FXAccountKeychainQuery",
        @"CAAKeychainStore"
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
        FFBReplaceInstanceMethod(NSBundle.class,
                                 @selector(objectForInfoDictionaryKey:),
                                 (IMP)FFBHook_objectForInfoDictionaryKey,
                                 (IMP *)&gOrigObjectForInfoKey);

        if (FFBIsOfficiallySignedFacebook() || FFBHasOtherSideloadFixerLoaded()) {
            return;
        }

        // 0. Rileva subito il vero keychain-access-group del container prima di attivare il rebinding C
        FFBProbedKeychainAccessGroup();

        gPatchedKeychainClasses = [NSMutableSet set];
        NSString *docs = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/FocusFB_AppGroups"];
        gFallbackGroupBaseURL = [NSURL fileURLWithPath:docs isDirectory:YES];
        FFBEnsureDirectory(gFallbackGroupBaseURL);

        // 1. Rebinding C-level Security.framework per tutti i binari/framework di Facebook
        struct ffb_rebinding secRebindings[] = {
            { "SecItemAdd",             (void *)FFBHook_SecItemAdd,             (void **)&gOrigSecItemAdd },
            { "SecItemCopyMatching",    (void *)FFBHook_SecItemCopyMatching,    (void **)&gOrigSecItemCopyMatching },
            { "SecItemUpdate",          (void *)FFBHook_SecItemUpdate,          (void **)&gOrigSecItemUpdate },
            { "SecItemDelete",          (void *)FFBHook_SecItemDelete,          (void **)&gOrigSecItemDelete },
            { "SecKeyCreateRandomKey",  (void *)FFBHook_SecKeyCreateRandomKey,  (void **)&gOrigSecKeyCreateRandomKey },
        };
        ffb_rebind_symbols(secRebindings, sizeof(secRebindings) / sizeof(secRebindings[0]));

        // 2. Container App Group persistente in Documents/ per sopravvivere ai refresh SideStore/Feather
        FFBReplaceInstanceMethod(NSFileManager.class,
                                 @selector(containerURLForSecurityApplicationGroupIdentifier:),
                                 (IMP)FFBHook_containerURLForSecurityApplicationGroupIdentifier,
                                 (IMP *)&gOrigContainerURL);

        // 3. Siri Vocabulary crash guard
        Class vocabCls = NSClassFromString(@"INVocabulary");
        if (vocabCls) {
            FFBReplaceInstanceMethod(vocabCls, NSSelectorFromString(@"setVocabularyStrings:ofType:"), (IMP)FFBNoOpSetVocab, NULL);
            FFBReplaceInstanceMethod(vocabCls, NSSelectorFromString(@"setVocabulary:ofType:"), (IMP)FFBNoOpSetVocab, NULL);
            FFBReplaceInstanceMethod(vocabCls, NSSelectorFromString(@"_THROW_EXCEPTION_FOR_PROCESS_MISSING_ENTITLEMENT_com_apple_developer_siri"), (IMP)FFBNoOpVoid, NULL);
        }

        // 4. Patch anche sui wrapper Objective-C caricati in ritardo
        FFBPatchKeychainClassesNow();
        for (NSNumber *delay in @[@0.4, @1.5, @4.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                FFBPatchKeychainClassesNow();
            });
        }
    });
}
