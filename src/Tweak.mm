#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <os/log.h>

#import "FocusFBConfig.h"
#import "FocusFBPrefs.h"
#import "FocusFBSideloadFix.h"
#import "FocusFBTabManager.h"
#import "FocusFBLockManager.h"
#import "FocusFBAdBlocker.h"
#import "FocusFBStoriesManager.h"
#import "FocusFBMediaDownloader.h"

static BOOL FocusFBShouldActivateInCurrentProcess(void) {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundlePath = mainBundle.bundlePath ?: @"";

    // Ignora sempre eventuali App Extensions (.appex)
    if ([[bundlePath pathExtension].lowercaseString isEqualToString:@"appex"]) {
        return NO;
    }

    NSDictionary *info = mainBundle.infoDictionary ?: @{};
    NSString *executable = info[@"CFBundleExecutable"] ?: @"";
    NSString *bundleID = mainBundle.bundleIdentifier ?: @"";

    if ([executable isEqualToString:@"Facebook"]) return YES;
    if ([bundleID.lowercaseString containsString:@"facebook"] &&
        ![bundleID.lowercaseString containsString:@"messenger"]) {
        return YES;
    }
    if (NSClassFromString(@"FBTabBarViewController") != nil ||
        NSClassFromString(@"FBFloatingTabBar") != nil ||
        NSClassFromString(@"FBAppDelegate") != nil) {
        return YES;
    }
    return NO;
}

static void FocusFBBootstrapAfterLaunch(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FocusFBInstallAdBlocker();
        FocusFBStartEngine();
        [[FocusFBLockManager shared] start];
        FocusFBInstallStoriesManager();
        FocusFBInstallMediaDownloader();
    });
}

__attribute__((constructor))
static void FocusFBConstructor(void) {
    @autoreleasepool {
        if (!FocusFBShouldActivateInCurrentProcess()) {
            return;
        }

        os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO,
                         "[FocusFB %{public}@] Loaded in bundle=%{public}@ iOS=%{public}@",
                         FOCUSFB_VERSION_STRING,
                         NSBundle.mainBundle.bundleIdentifier ?: @"-",
                         UIDevice.currentDevice.systemVersion);

        // 1. Nel constructor dyld esegui SOLO i fix Keychain/AppGroups e le preferenze (100% identico alla v2.4!)
        FocusFBInstallSideloadFixesIfNeeded();
        (void)[FocusFBPrefs shared];

        // 2. Avvia tutti gli altri moduli SOLO dopo l'inizializzazione di UIApplication sul main thread
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            FocusFBBootstrapAfterLaunch();
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            FocusFBBootstrapAfterLaunch();
        });
    }
}
