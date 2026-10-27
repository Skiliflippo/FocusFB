#import "FocusFBTabManager.h"
#import "FocusFBPrefs.h"
#import "FocusFBSettingsViewController.h"
#import "FocusFBLockManager.h"
#import "FocusFBStoriesManager.h"
#import "FocusFBMediaDownloader.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kFloatingBarClassName      = @"FBFloatingTabBar";
static NSString * const kFloatingItemClassName     = @"FBFloatingTabBar.FBFloatingTabBarItemView";
static NSString * const kNativeGlassBarClassName   = @"FBNativeTabBar";
static NSString * const kLegacyBarClassName        = @"FBTabBar";
static NSString * const kLegacyItemClassName       = @"FBTabBarItemDefaultView";
static NSString * const kTabControllerName         = @"FBTabBarViewController";
static NSString * const kTabAndContentVCName       = @"FBTabBarAndContentViewController";

static const NSInteger kFeedShieldTag  = 0x70C501;
static const NSInteger kReelsShieldTag = 0x70C502;
static const NSInteger kFloatingBtnTag = 0x70C503;
static const NSInteger kTimerPillTag   = 0xFFBF09;

static char kOrigFrameKey;
static char kOrigIndexKey;
static char kContextDelegateKey;
static char kContextInteractionKey;
static char kBarLongPressKey;
static char kWindowTwoFingerKey;
static char kCachedBarPassKey;
static char kCachedVCBarsKey;

typedef void (*FFBLayoutIMP)(id, SEL);
typedef void (*FFBViewDidAppearIMP)(id, SEL, BOOL);
typedef void (*FFBOffsetFractionIMP)(id, SEL, double, NSUInteger);

static FFBLayoutIMP gOrigFloatingBarLayout      = NULL;
static FFBLayoutIMP gOrigNativeGlassBarLayout   = NULL;
static FFBLayoutIMP gOrigLegacyBarLayout        = NULL;
static FFBLayoutIMP gOrigFloatingItemLayout     = NULL;
static FFBLayoutIMP gOrigLegacyItemLayout       = NULL;
static FFBLayoutIMP gOrigUITabBarLayout         = NULL;
static FFBLayoutIMP gOrigTabBarVCLayout         = NULL;
static FFBLayoutIMP gOrigTabAndContentVCLayout  = NULL;
static FFBOffsetFractionIMP gOrigSetOffsetFrac  = NULL;
static FFBViewDidAppearIMP gOrigVCViewDidAppear = NULL;

static BOOL gHooksInstalledFloatingBar      = NO;
static BOOL gHooksInstalledNativeGlassBar   = NO;
static BOOL gHooksInstalledLegacyBar        = NO;
static BOOL gHooksInstalledFloatingItem     = NO;
static BOOL gHooksInstalledLegacyItem       = NO;
static BOOL gHooksInstalledUITabBar         = NO;
static BOOL gHooksInstalledTabBarVC         = NO;
static BOOL gHooksInstalledTabAndContentVC  = NO;
static BOOL gHooksInstalledOffsetFraction   = NO;
static BOOL gHooksInstalledVC               = NO;

static BOOL gIsReflowingNavbar = NO;
static BOOL gForceFullScreenSingleBar = NO;
static BOOL gDidInitialLaunchRedirect = NO;
static BOOL gLastKnownPrimaryTabIsMarketplace = YES;
static CFTimeInterval gLastMarketplaceRedirectAttempt = 0;

static NSHashTable<UIView *> *FFBHiddenBottomChromeViews(void) {
    static NSHashTable<UIView *> *table = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

#pragma mark - Forward Declarations

static void FFBInstallDynamicHooksAvailableNow(void);
static void FFBApplyFilterToTabBar(UIView *bar);
static void FFBAttachContextMenuToTabItem(UIView *item);
static void FFBAttachLongPressToBar(UIView *bar);
static void FFBAttachWindowShortcuts(UIWindow *window);
static void FFBSyncFloatingGearButton(UIWindow *window);
static void FFBReevaluateVisibleControllers(void);

#pragma mark - Context Menu & Gesture Target Helper

@interface FFBTabContextMenuDelegate : NSObject <UIContextMenuInteractionDelegate>
@property (nonatomic, weak) UIView *targetView;
- (void)handleBarLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleWindowTwoFingerLongPress:(UILongPressGestureRecognizer *)gesture;
- (void)handleFloatingButtonTap:(UIButton *)sender;
- (void)handleFloatingButtonPan:(UIPanGestureRecognizer *)pan;
- (void)handleShieldOpenMarketplace:(UIButton *)sender;
- (void)handleShieldOpenSettings:(UIButton *)sender;
- (void)handleShieldGoBack:(UIButton *)sender;
@end

static FFBTabContextMenuDelegate *FFBSharedActionTarget(void) {
    static FFBTabContextMenuDelegate *target = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [[FFBTabContextMenuDelegate alloc] init];
    });
    return target;
}

@implementation FFBTabContextMenuDelegate

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                        configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *openSettings = [UIAction actionWithTitle:FFBLoc(@"Menu.Settings")
                                                     image:[UIImage systemImageNamed:@"slider.horizontal.3"]
                                                identifier:nil
                                                   handler:^(__kindof UIAction *action) {
            [FocusFBSettingsViewController presentFromTopMostController];
        }];

        UIAction *goMarketplace = [UIAction actionWithTitle:FFBLoc(@"Menu.Marketplace")
                                                      image:[UIImage systemImageNamed:@"storefront.fill"]
                                                 identifier:nil
                                                    handler:^(__kindof UIAction *action) {
            FocusFBNavigateToMarketplace(YES);
        }];

        if ([FocusFBLockManager shared].strictLockActive) {
            return [UIMenu menuWithTitle:@"FocusFB" children:@[openSettings, goMarketplace]];
        }

        FocusFBPrefs *prefs = [FocusFBPrefs shared];
        BOOL isSoloNow = prefs.enabled && prefs.showMarketplaceTab &&
                         !prefs.showHomeTab && !prefs.showReelsTab &&
                         !prefs.showFriendsTab && !prefs.showGroupsTab;

        UIAction *quickToggle = [UIAction actionWithTitle:isSoloNow ? FFBLoc(@"Menu.SoloToggleOff") : FFBLoc(@"Menu.SoloToggleOn")
                                                    image:[UIImage systemImageNamed:isSoloNow ? @"square.grid.2x2" : @"scope"]
                                               identifier:nil
                                                  handler:^(__kindof UIAction *action) {
            if (isSoloNow) {
                [prefs applyShowAllTabsPreset];
            } else {
                [prefs applyMarketplaceOnlyPreset];
            }
            FocusFBShowToast(FFBLoc(@"Preset.AppliedToast"), @"checkmark.circle.fill");
        }];

        return [UIMenu menuWithTitle:@"FocusFB" children:@[openSettings, goMarketplace, quickToggle]];
    }];
}

- (void)handleBarLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [gen impactOccurred];
        [FocusFBSettingsViewController presentFromTopMostController];
    }
}

- (void)handleWindowTwoFingerLongPress:(UILongPressGestureRecognizer *)gesture {
    if (![FocusFBPrefs shared].twoFingerLongPressEnabled) return;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
        [gen impactOccurred];
        [FocusFBSettingsViewController presentFromTopMostController];
    }
}

- (void)handleFloatingButtonTap:(UIButton *)sender {
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen impactOccurred];
    [FocusFBSettingsViewController presentFromTopMostController];
}

- (void)handleFloatingButtonPan:(UIPanGestureRecognizer *)pan {
    UIView *btn = pan.view;
    UIView *superview = btn.superview;
    if (!btn || !superview) return;

    CGPoint translation = [pan translationInView:superview];
    CGPoint center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    UIEdgeInsets insets = superview.safeAreaInsets;
    CGFloat halfW = CGRectGetWidth(btn.bounds) * 0.5;
    CGFloat halfH = CGRectGetHeight(btn.bounds) * 0.5;
    center.x = MAX(halfW + 8.0, MIN(CGRectGetWidth(superview.bounds) - halfW - 8.0, center.x));
    center.y = MAX(insets.top + halfH + 8.0, MIN(CGRectGetHeight(superview.bounds) - insets.bottom - halfH - 60.0, center.y));
    btn.center = center;
    [pan setTranslation:CGPointZero inView:superview];

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat targetX = (center.x < CGRectGetMidX(superview.bounds))
            ? (halfW + 12.0)
            : (CGRectGetWidth(superview.bounds) - halfW - 12.0);
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
            btn.center = CGPointMake(targetX, center.y);
        } completion:nil];
    }
}

- (void)handleShieldOpenMarketplace:(UIButton *)sender {
    FocusFBNavigateToMarketplace(YES);
}

- (void)handleShieldOpenSettings:(UIButton *)sender {
    [FocusFBSettingsViewController presentFromTopMostController];
}

- (void)handleShieldGoBack:(UIButton *)sender {
    UIViewController *top = FocusFBTopMostViewController();
    if (top.navigationController && top.navigationController.viewControllers.count > 1) {
        [top.navigationController popViewControllerAnimated:YES];
    } else if (top.presentingViewController) {
        [top dismissViewControllerAnimated:YES completion:nil];
    } else {
        FocusFBNavigateToMarketplace(YES);
    }
}

@end

#pragma mark - Window & Controller Helpers

UIWindow *FocusFBActiveWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *win in ws.windows) {
            if (!win || win.hidden || win.alpha <= 0.01 || !win.rootViewController) continue;
            if (win.windowLevel > UIWindowLevelNormal + 5.0) continue; // Ignora finestra di blocco Foqos
            if (win.isKeyWindow) return win;
            if (!fallback || (win.windowLevel == UIWindowLevelNormal && fallback.windowLevel != UIWindowLevelNormal)) {
                fallback = win;
            }
        }
    }
    return fallback;
}

static BOOL FFBMethodReturnsObjOnClass(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    return (enc != NULL && enc[0] == '@');
}

// Scende nei custom container di Meta (FBTabBarViewController, FBTabBarAndContentViewController, ecc.)
// trovando il childViewController realmente montato e visibile nel viewport dello schermo!
static UIViewController *FFBBestVisibleChildOfContainer(UIViewController *vc, UIWindow *win) {
    if (!vc) return nil;
    Class cls = object_getClass(vc);

    static NSArray<NSString *> *selNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        selNames = @[@"selectedViewController", @"currentViewController", @"activeViewController", @"_selectedViewController"];
    });
    for (NSString *name in selNames) {
        SEL sel = NSSelectorFromString(name);
        if (FFBMethodReturnsObjOnClass(cls, sel)) {
            @try {
                id child = ((id (*)(id, SEL))objc_msgSend)(vc, sel);
                if ([child isKindOfClass:UIViewController.class] && child != vc) {
                    return (UIViewController *)child;
                }
            } @catch (__unused NSException *e) {}
        }
    }

    NSArray<UIViewController *> *children = vc.childViewControllers;
    if (children.count == 0) return nil;

    CGRect viewport = win ? win.bounds : UIScreen.mainScreen.bounds;
    UIViewController *bestChild = nil;
    CGFloat bestArea = 0.0;

    for (UIViewController *child in [children reverseObjectEnumerator]) {
        if (!child.isViewLoaded) continue;
        UIView *v = child.view;
        if (!v || v.hidden || v.alpha <= 0.01 || !v.window) continue;

        CGRect rectInWin = [v convertRect:v.bounds toView:v.window];
        CGRect inter = CGRectIntersection(rectInWin, viewport);
        if (CGRectIsNull(inter) || inter.size.width < 80.0 || inter.size.height < 80.0) continue;

        CGFloat area = inter.size.width * inter.size.height;
        if (area > bestArea) {
            bestArea = area;
            bestChild = child;
        }
    }
    return bestChild;
}

UIViewController *FocusFBTopMostViewController(void) {
    UIWindow *win = FocusFBActiveWindow();
    UIViewController *vc = win.rootViewController;
    NSUInteger guard = 0;
    while (vc && guard++ < 32) {
        if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
            vc = vc.presentedViewController;
        } else if ([vc isKindOfClass:UINavigationController.class]) {
            UIViewController *top = ((UINavigationController *)vc).visibleViewController;
            if (!top || top == vc) break;
            vc = top;
        } else if ([vc isKindOfClass:UITabBarController.class]) {
            UIViewController *sel = ((UITabBarController *)vc).selectedViewController;
            if (!sel || sel == vc) break;
            vc = sel;
        } else {
            UIViewController *visChild = FFBBestVisibleChildOfContainer(vc, win);
            if (!visChild || visChild == vc) break;
            vc = visChild;
        }
    }
    return vc;
}

void FocusFBShowToast(NSString *message, NSString *sfSymbolName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = FocusFBActiveWindow();
        if (!window || message.length == 0) return;

        UIVisualEffectView *pill = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial]];
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        pill.layer.cornerRadius = 20.0;
        pill.clipsToBounds = YES;

        UIStackView *stack = [[UIStackView alloc] init];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.spacing = 8.0;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.translatesAutoresizingMaskIntoConstraints = NO;

        if (sfSymbolName.length > 0) {
            UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:sfSymbolName]];
            icon.tintColor = [UIColor systemBlueColor];
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            [NSLayoutConstraint activateConstraints:@[
                [icon.widthAnchor constraintEqualToConstant:20.0],
                [icon.heightAnchor constraintEqualToConstant:20.0]
            ]];
            [stack addArrangedSubview:icon];
        }

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = message;
        lbl.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        lbl.textColor = [UIColor labelColor];
        [stack addArrangedSubview:lbl];

        [pill.contentView addSubview:stack];
        [window addSubview:pill];

        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:pill.contentView.leadingAnchor constant:16.0],
            [stack.trailingAnchor constraintEqualToAnchor:pill.contentView.trailingAnchor constant:-16.0],
            [stack.topAnchor constraintEqualToAnchor:pill.contentView.topAnchor constant:10.0],
            [stack.bottomAnchor constraintEqualToAnchor:pill.contentView.bottomAnchor constant:-10.0],
            [pill.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
            [pill.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:12.0]
        ]];

        pill.alpha = 0.0;
        pill.transform = CGAffineTransformMakeTranslation(0, -12.0);
        [UIView animateWithDuration:0.25 animations:^{
            pill.alpha = 1.0;
            pill.transform = CGAffineTransformIdentity;
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{
                pill.alpha = 0.0;
                pill.transform = CGAffineTransformMakeTranslation(0, -12.0);
            } completion:^(BOOL finished) {
                [pill removeFromSuperview];
            }];
        });
    });
}

#pragma mark - Class & View Inspection Helpers

static BOOL FFBClassInheritsName(Class cls, NSString *targetName) {
    for (Class cur = cls; cur != Nil; cur = class_getSuperclass(cur)) {
        if ([NSStringFromClass(cur) isEqualToString:targetName]) {
            return YES;
        }
    }
    return NO;
}

static BOOL FFBIsTabItemView(UIView *view) {
    if (!view) return NO;
    Class cls = object_getClass(view);
    if (FFBClassInheritsName(cls, kFloatingItemClassName) ||
        FFBClassInheritsName(cls, kLegacyItemClassName)) {
        return YES;
    }
    NSString *clsName = NSStringFromClass(cls);
    return ([clsName isEqualToString:@"UITabBarButton"] ||
            [clsName hasSuffix:@"TabBarItemView"] ||
            [clsName hasSuffix:@"TabBarItemDefaultView"]);
}

static BOOL FFBIsFacebookNavbarView(UIView *view) {
    if (!view) return NO;
    Class cls = object_getClass(view);
    return FFBClassInheritsName(cls, kFloatingBarClassName) ||
           FFBClassInheritsName(cls, kNativeGlassBarClassName) ||
           FFBClassInheritsName(cls, kLegacyBarClassName);
}

static void FFBExtractStringsFromSubtree(UIView *view,
                                         NSUInteger depth,
                                         NSMutableArray<NSString *> *identifiers,
                                         NSMutableArray<NSString *> *labels) {
    if (!view || depth > 4) return;
    if ([view respondsToSelector:@selector(accessibilityIdentifier)]) {
        NSString *ident = view.accessibilityIdentifier;
        if ([ident isKindOfClass:NSString.class] && ident.length > 0) {
            [identifiers addObject:ident];
        }
    }
    if ([view respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *lbl = view.accessibilityLabel;
        if ([lbl isKindOfClass:NSString.class] && lbl.length > 0) {
            [labels addObject:lbl];
        }
    }
    if ([view isKindOfClass:UILabel.class]) {
        NSString *txt = ((UILabel *)view).text;
        if ([txt isKindOfClass:NSString.class] && txt.length > 0) {
            [labels addObject:txt];
        }
    }
    for (UIView *sub in view.subviews) {
        FFBExtractStringsFromSubtree(sub, depth + 1, identifiers, labels);
    }
}

static void FFBDescribeTabItem(UIView *item,
                               NSUInteger slotIndex,
                               NSString **outKey,
                               NSString **outIdentifier,
                               NSString **outLabel,
                               FocusFBTabType *outType) {
    NSMutableArray<NSString *> *idents = [NSMutableArray array];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    FFBExtractStringsFromSubtree(item, 0, idents, labels);

    NSString *primaryIdent = idents.firstObject ?: @"";
    NSString *primaryLabel = labels.firstObject ?: @"";
    NSString *joinedIdents = [idents componentsJoinedByString:@" "];
    NSString *joinedLabels = [labels componentsJoinedByString:@" "];

    FocusFBTabType type = [FocusFBPrefs classifyTabWithIdentifier:joinedIdents label:joinedLabels];

    NSString *stableKey = nil;
    if (primaryIdent.length > 0) {
        stableKey = [NSString stringWithFormat:@"id:%@", primaryIdent.lowercaseString];
    } else if (type != FocusFBTabUnknown) {
        stableKey = [NSString stringWithFormat:@"type:%ld", (long)type];
    } else if (primaryLabel.length > 0) {
        // Rimuovi eventuali badge numerici variabili dal label ("Notifiche, 3 non lette")
        NSString *baseLbl = [[primaryLabel componentsSeparatedByString:@","] firstObject] ?: primaryLabel;
        stableKey = [NSString stringWithFormat:@"lbl:%@", baseLbl.lowercaseString];
    } else {
        stableKey = [NSString stringWithFormat:@"slot:%lu", (unsigned long)slotIndex];
    }

    if (outKey) *outKey = stableKey;
    if (outIdentifier) *outIdentifier = primaryIdent.length > 0 ? primaryIdent : @"-";
    if (outLabel) *outLabel = primaryLabel.length > 0 ? primaryLabel : @"-";
    if (outType) *outType = type;
}

static BOOL FFBIsItemMarkedSelected(UIView *item, NSUInteger depth) {
    if (!item || depth > 4) return NO;
    if ([item isKindOfClass:UIControl.class] && ((UIControl *)item).isSelected) {
        return YES;
    }
    if ((item.accessibilityTraits & UIAccessibilityTraitSelected) != 0) {
        return YES;
    }
    for (UIView *sub in item.subviews) {
        if (FFBIsItemMarkedSelected(sub, depth + 1)) return YES;
    }
    return NO;
}

static void FFBCollectTabItemViews(UIView *node,
                                   UIView *rootBar,
                                   NSUInteger depth,
                                   NSMutableArray<UIView *> *results) {
    if (!node || depth > 8) return;
    if (node != rootBar && FFBIsTabItemView(node)) {
        [results addObject:node];
        return; // Non scendere dentro i figli di un item già trovato
    }
    for (UIView *child in node.subviews) {
        FFBCollectTabItemViews(child, rootBar, depth + 1, results);
    }
}

static void FFBFindAllTabBarsInView(UIView *root,
                                    NSUInteger depth,
                                    NSMutableArray<UIView *> *bars) {
    if (!root || depth > 16) return;
    if (FFBIsFacebookNavbarView(root)) {
        [bars addObject:root];
        return;
    }
    if ([root isKindOfClass:UITabBar.class]) {
        UIResponder *resp = root.nextResponder;
        while (resp && ![resp isKindOfClass:UIViewController.class]) {
            resp = resp.nextResponder;
        }
        if (resp && [NSStringFromClass(resp.class) hasPrefix:@"FB"]) {
            [bars addObject:root];
            return;
        }
    }
    for (UIView *child in root.subviews) {
        FFBFindAllTabBarsInView(child, depth + 1, bars);
    }
}

#pragma mark - Core Tab Bar Filter & Layout Reflow

static void FFBAttachContextMenuToTabItem(UIView *item) {
    if (!item) return;
    UIContextMenuInteraction *existingOwned = objc_getAssociatedObject(item, &kContextInteractionKey);
    if (existingOwned && [item.interactions containsObject:existingOwned]) {
        return;
    }
    for (id inter in item.interactions) {
        if ([inter isKindOfClass:UIContextMenuInteraction.class]) {
            return; // Rispetta eventuali context menu nativi (es. switch profilo)
        }
    }
    FFBTabContextMenuDelegate *del = [[FFBTabContextMenuDelegate alloc] init];
    del.targetView = item;
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:del];
    if (interaction) {
        objc_setAssociatedObject(item, &kContextDelegateKey, del, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(item, &kContextInteractionKey, interaction, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [item addInteraction:interaction];
    }
}

static void FFBAttachLongPressToBar(UIView *bar) {
    if (!bar) return;
    UILongPressGestureRecognizer *existing = objc_getAssociatedObject(bar, &kBarLongPressKey);
    if (existing && [bar.gestureRecognizers containsObject:existing]) return;

    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:FFBSharedActionTarget()
                                                                                     action:@selector(handleBarLongPress:)];
    lp.minimumPressDuration = 0.55;
    lp.cancelsTouchesInView = NO;
    [bar addGestureRecognizer:lp];
    objc_setAssociatedObject(bar, &kBarLongPressKey, lp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void FFBAttachWindowShortcuts(UIWindow *window) {
    if (!window) return;
    UILongPressGestureRecognizer *existing = objc_getAssociatedObject(window, &kWindowTwoFingerKey);
    if (!existing || ![window.gestureRecognizers containsObject:existing]) {
        UILongPressGestureRecognizer *twoFinger = [[UILongPressGestureRecognizer alloc]
            initWithTarget:FFBSharedActionTarget()
                    action:@selector(handleWindowTwoFingerLongPress:)];
        twoFinger.numberOfTouchesRequired = 2;
        twoFinger.minimumPressDuration = 0.60;
        twoFinger.cancelsTouchesInView = NO;
        [window addGestureRecognizer:twoFinger];
        objc_setAssociatedObject(window, &kWindowTwoFingerKey, twoFinger, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    FFBSyncFloatingGearButton(window);
}

static void FFBSyncFloatingGearButton(UIWindow *window) {
    if (!window) return;
    UIView *existing = [window viewWithTag:kFloatingBtnTag];
    BOOL shouldShow = [FocusFBPrefs shared].showFloatingGearButton;
    if (!shouldShow) {
        [existing removeFromSuperview];
        return;
    }
    if (existing) {
        [window bringSubviewToFront:existing];
        return;
    }

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial]];
    blur.tag = kFloatingBtnTag;
    CGFloat size = 40.0;
    CGFloat startY = MAX(120.0, CGRectGetHeight(window.bounds) * 0.72);
    blur.frame = CGRectMake(CGRectGetWidth(window.bounds) - size - 12.0, startY, size, size);
    blur.layer.cornerRadius = size * 0.5;
    blur.layer.borderWidth = 0.5;
    blur.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.4].CGColor;
    blur.clipsToBounds = YES;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = blur.bounds;
    btn.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [btn setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
    btn.tintColor = [UIColor systemBlueColor];
    [btn addTarget:FFBSharedActionTarget() action:@selector(handleFloatingButtonTap:) forControlEvents:UIControlEventTouchUpInside];
    [blur.contentView addSubview:btn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:FFBSharedActionTarget()
                                                                          action:@selector(handleFloatingButtonPan:)];
    [blur addGestureRecognizer:pan];
    [window addSubview:blur];
}

@interface FFBCachedNavbarPass : NSObject
@property (nonatomic, assign) uint64_t prefsGeneration;
@property (nonatomic, assign) BOOL forceMPOnly;
@property (nonatomic, assign) NSInteger barWidthRounded;
@property (nonatomic, assign) NSUInteger directSubviewCount;
@property (nonatomic, assign) BOOL singleBarHidden;
@end

@implementation FFBCachedNavbarPass
@end

// Clamping pre-super sul container principale (zero oscillazioni 769pt <-> 852pt e zero saltelli scroll!)
static void FFBFullScreenContainer_setFrame(UIView *self, SEL _cmd, CGRect frame) {
    if (gForceFullScreenSingleBar) {
        UIView *superview = self.superview;
        if (superview) {
            CGFloat parentH = CGRectGetHeight(superview.bounds);
            CGFloat parentW = CGRectGetWidth(superview.bounds);
            if (parentH > 320.0 &&
                CGRectGetMinY(frame) <= 24.0 &&
                fabs(CGRectGetWidth(frame) - parentW) <= 6.0) {
                CGFloat missingBottom = parentH - CGRectGetMaxY(frame);
                if (missingBottom >= 34.0 && missingBottom <= 145.0) {
                    frame.size.height = parentH - CGRectGetMinY(frame);
                }
            }
        }
    }
    struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
    ((void (*)(struct objc_super *, SEL, CGRect))objc_msgSendSuper)(&sup, _cmd, frame);
}

static void FFBEnsureFullScreenContainerSubclass(UIView *node) {
    if (!node || [node isKindOfClass:UIScrollView.class]) return;
    Class origCls = object_getClass(node);
    NSString *origName = NSStringFromClass(origCls) ?: @"";
    if (origName.length == 0 ||
        [origName hasPrefix:@"FFBFullScreenContainer_"] ||
        [origName hasPrefix:@"NSKVONotifying_"] ||
        FFBIsFacebookNavbarView(node) ||
        [node isKindOfClass:UITabBar.class]) {
        return;
    }

    NSString *subName = [@"FFBFullScreenContainer_" stringByAppendingString:origName];
    Class subCls = objc_getClass(subName.UTF8String);
    if (!subCls) {
        subCls = objc_allocateClassPair(origCls, subName.UTF8String, 0);
        if (subCls) {
            class_addMethod(subCls,
                            @selector(setFrame:),
                            (IMP)FFBFullScreenContainer_setFrame,
                            "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
            objc_registerClassPair(subCls);
        }
    }
    if (subCls) {
        object_setClass(node, subCls);
    }
}

// Espande i container strutturali fino alla UIScrollView SENZA MAI toccare contentInset durante lo scroll!
static void FFBExpandClippedContentTree(UIView *node,
                                        CGFloat targetBottomHeight,
                                        CGFloat screenH,
                                        __unused CGFloat safeBottom,
                                        NSUInteger depth) {
    if (!node || depth > 5) return;
    if (node.tag == kFloatingBtnTag || node.tag == kTimerPillTag ||
        node.tag == kFeedShieldTag || node.tag == kReelsShieldTag) {
        return;
    }

    // NON mutare mai UIScrollView / RCTScrollView: toccare contentInset o frame durante lo scroll
    // causa saltelli di contentOffset su Marketplace!
    if ([node isKindOfClass:UIScrollView.class]) {
        return;
    }

    CGFloat minY = CGRectGetMinY(node.frame);
    CGFloat curH = CGRectGetHeight(node.frame);
    if (minY <= 24.0 && curH > screenH * 0.48) {
        FFBEnsureFullScreenContainerSubclass(node);
        CGFloat desiredH = targetBottomHeight - minY;
        if (curH < desiredH - 0.5 && (desiredH - curH) <= 145.0) {
            CGRect f = node.frame;
            f.size.height = desiredH;
            node.frame = f;
        }
    }

    CGFloat nextTargetH = CGRectGetHeight(node.bounds);
    for (UIView *sub in node.subviews) {
        FFBExpandClippedContentTree(sub, nextTargetH, screenH, safeBottom, depth + 1);
    }
}

// Nasconde o ripristina l'INTERO contenitore bianco inferiore della barra (FBTabBarContainerView,
// sfondi safe-area, separatori) ed espande il contenitore di Marketplace a tutto schermo.
static void FFBSetEntireBottomBarHidden(UIView *bar, BOOL hideEntirely) {
    if (!bar) return;
    gForceFullScreenSingleBar = hideEntirely;

    if (!hideEntirely) {
        bar.hidden = NO;
        bar.alpha = 1.0;
        bar.userInteractionEnabled = YES;
        for (UIView *v in [FFBHiddenBottomChromeViews() allObjects]) {
            v.hidden = NO;
            v.alpha = 1.0;
            v.userInteractionEnabled = YES;
        }
        [FFBHiddenBottomChromeViews() removeAllObjects];
        return;
    }

    UIWindow *win = bar.window ?: FocusFBActiveWindow();
    CGFloat screenH = win ? CGRectGetHeight(win.bounds) : CGRectGetHeight([UIScreen mainScreen].bounds);
    CGFloat safeBottom = win ? win.safeAreaInsets.bottom : 34.0;
    if (screenH < 200.0) screenH = 852.0;

    // 1. Risali da `bar` fino al contenitore più esterno della barra inferiore (altezza <= 30% dello schermo)
    UIView *topBarWrapper = bar;
    while (topBarWrapper.superview && topBarWrapper.superview != win) {
        UIView *parent = topBarWrapper.superview;
        CGFloat parentH = CGRectGetHeight(parent.bounds);
        if (parentH > 0.0 && parentH <= screenH * 0.30) {
            topBarWrapper = parent;
        } else {
            break;
        }
    }

    // 2. Nascondi sia la barra sia tutti i suoi wrapper bianchi / blur / safe-area
    for (UIView *cur = bar; cur != nil; cur = cur.superview) {
        cur.hidden = YES;
        cur.alpha = 0.0;
        cur.userInteractionEnabled = NO;
        [FFBHiddenBottomChromeViews() addObject:cur];
        if (cur == topBarWrapper) break;
    }

    // 3. Nel contenitore full-screen padre (FBTabBarViewController.view):
    //    - nascondi eventuali fratelli sottili ancorati sul fondo (backdrop bianchi / linee / filler safe-area)
    //    - espandi il contenitore del contenuto principale fino al bordo inferiore dello schermo
    UIView *hostView = topBarWrapper.superview;
    if (hostView && CGRectGetHeight(hostView.bounds) > screenH * 0.60) {
        CGFloat hostH = CGRectGetHeight(hostView.bounds);

        UIResponder *resp = hostView.nextResponder;
        while (resp && ![resp isKindOfClass:UIViewController.class]) {
            resp = resp.nextResponder;
        }
        if ([resp isKindOfClass:UIViewController.class]) {
            UIViewController *ownerVC = (UIViewController *)resp;
            if (ownerVC.additionalSafeAreaInsets.bottom > 0.5) {
                UIEdgeInsets ins = ownerVC.additionalSafeAreaInsets;
                ins.bottom = 0.0;
                ownerVC.additionalSafeAreaInsets = ins;
            }
            for (UIViewController *childVC in ownerVC.childViewControllers) {
                if (childVC.additionalSafeAreaInsets.bottom > 0.5) {
                    UIEdgeInsets ins = childVC.additionalSafeAreaInsets;
                    ins.bottom = 0.0;
                    childVC.additionalSafeAreaInsets = ins;
                }
            }
        }

        for (UIView *sib in hostView.subviews) {
            if (sib == topBarWrapper) continue;
            if (sib.tag == kFloatingBtnTag || sib.tag == kTimerPillTag ||
                sib.tag == kFeedShieldTag || sib.tag == kReelsShieldTag) {
                continue;
            }
            CGFloat sibH = CGRectGetHeight(sib.frame);
            CGFloat sibMinY = CGRectGetMinY(sib.frame);

            // Striscia bianca / ombra / safe-area ancorata sul fondo come fratello
            if (sibH <= 140.0 && sibMinY >= hostH - 145.0) {
                sib.hidden = YES;
                sib.alpha = 0.0;
                sib.userInteractionEnabled = NO;
                [FFBHiddenBottomChromeViews() addObject:sib];
                continue;
            }

            // Contenitore principale della schermata attiva (es. Marketplace)
            if (sibH > screenH * 0.48 && sibMinY <= 24.0) {
                FFBExpandClippedContentTree(sib, hostH, screenH, safeBottom, 0);
            }
        }
    }
}

static void FFBApplyFilterToTabBar(UIView *bar) {
    if (!bar || gIsReflowingNavbar || !NSThread.isMainThread) return;

    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    BOOL forceMPOnly = [FocusFBLockManager shared].shouldForceMarketplaceOnlyNow;
    uint64_t currentGen = prefs.prefsGeneration;
    NSInteger currentW = (NSInteger)llround(CGRectGetWidth(bar.bounds));
    NSUInteger subCount = bar.subviews.count;

    // Fast-path 120Hz: quando la barra è già nascosta e né preferenze né larghezza sono cambiate,
    // non scansionare MAI subview o accessibilityLabel ad ogni frame di scroll!
    FFBCachedNavbarPass *cachedPass = objc_getAssociatedObject(bar, &kCachedBarPassKey);
    if (cachedPass &&
        cachedPass.prefsGeneration == currentGen &&
        cachedPass.forceMPOnly == forceMPOnly &&
        cachedPass.barWidthRounded == currentW &&
        cachedPass.directSubviewCount == subCount) {
        if (cachedPass.singleBarHidden) {
            if (!bar.hidden) bar.hidden = YES;
            if (bar.alpha > 0.01) bar.alpha = 0.0;
            bar.userInteractionEnabled = NO;
            return;
        }
    }

    gIsReflowingNavbar = YES;
    @try {
        FFBAttachLongPressToBar(bar);

        NSMutableArray<UIView *> *items = [NSMutableArray array];
        FFBCollectTabItemViews(bar, bar, 0, items);
        if (items.count == 0) {
            gIsReflowingNavbar = NO;
            return;
        }

        // Salva indice canonico e frame nativo di ciascun tab prima del reflow
        for (NSUInteger idx = 0; idx < items.count; idx++) {
            UIView *item = items[idx];
            if (!objc_getAssociatedObject(item, &kOrigIndexKey)) {
                objc_setAssociatedObject(item, &kOrigIndexKey, @(idx), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (!CGRectIsEmpty(item.frame) && !objc_getAssociatedObject(item, &kOrigFrameKey)) {
                objc_setAssociatedObject(item, &kOrigFrameKey, [NSValue valueWithCGRect:item.frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            FFBAttachContextMenuToTabItem(item);
        }

        // Ordina secondo l'indice nativo per non invertire mai l'ordine dei tab
        [items sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            NSUInteger ia = [objc_getAssociatedObject(a, &kOrigIndexKey) unsignedIntegerValue];
            NSUInteger ib = [objc_getAssociatedObject(b, &kOrigIndexKey) unsignedIntegerValue];
            if (ia < ib) return NSOrderedAscending;
            if (ia > ib) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        NSMutableArray<UIView *> *allowedItems = [NSMutableArray array];
        for (NSUInteger idx = 0; idx < items.count; idx++) {
            UIView *item = items[idx];
            NSString *key = nil;
            NSString *ident = nil;
            NSString *label = nil;
            FocusFBTabType type = FocusFBTabUnknown;
            FFBDescribeTabItem(item, idx, &key, &ident, &label, &type);

            [prefs recordDiscoveredTabWithKey:key
                                        label:label
                                   identifier:ident
                                    className:NSStringFromClass(object_getClass(item))
                                      tabType:type];

            if (forceMPOnly) {
                if (type == FocusFBTabMarketplace) {
                    [allowedItems addObject:item];
                }
            } else if ([prefs isTabAllowedForType:type key:key]) {
                [allowedItems addObject:item];
            }
        }

        void (^saveNavbarCache)(BOOL) = ^(BOOL singleHidden) {
            FFBCachedNavbarPass *pass = [[FFBCachedNavbarPass alloc] init];
            pass.prefsGeneration = currentGen;
            pass.forceMPOnly = forceMPOnly;
            pass.barWidthRounded = (NSInteger)llround(CGRectGetWidth(bar.bounds));
            pass.directSubviewCount = bar.subviews.count;
            pass.singleBarHidden = singleHidden;
            objc_setAssociatedObject(bar, &kCachedBarPassKey, pass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        };

        // Se FocusFB è spento, ripristina tutti gli elementi e l'intera barra
        if (!prefs.enabled) {
            FFBSetEntireBottomBarHidden(bar, NO);
            for (UIView *item in items) {
                item.hidden = NO;
                item.alpha = 1.0;
                item.userInteractionEnabled = YES;
                NSValue *origVal = objc_getAssociatedObject(item, &kOrigFrameKey);
                if (origVal) item.frame = origVal.CGRectValue;
            }
            saveNavbarCache(NO);
            gIsReflowingNavbar = NO;
            return;
        }

        // Guardia di sicurezza: se tutti i tab presenti sulla barra risultano nascosti
        // (es. Marketplace non è tra i 5 tab fissati dall'account), mantieni almeno l'ultimo tab (Menu)
        if (allowedItems.count == 0 && items.count > 0 && !prefs.hideSingleTabBar) {
            [allowedItems addObject:items.lastObject];
        }

        // Opzione: nascondi COMPLETAMENTE l'intera barra bianca inferiore ed espandi a tutto schermo quando resta <= 1 tab
        if (allowedItems.count <= 1 && prefs.hideSingleTabBar) {
            FFBSetEntireBottomBarHidden(bar, YES);
            saveNavbarCache(YES);
            gIsReflowingNavbar = NO;
            return;
        } else {
            FFBSetEntireBottomBarHidden(bar, NO);
            saveNavbarCache(NO);
        }

        NSSet<UIView *> *allowedSet = [NSSet setWithArray:allowedItems];
        for (UIView *item in items) {
            BOOL show = [allowedSet containsObject:item];
            item.hidden = !show;
            item.alpha = show ? 1.0 : 0.0;
            item.userInteractionEnabled = show;
        }

        // Centra e ridistribuisce orizzontalmente i tab rimasti all'interno della rispettiva superview
        if (prefs.reflowVisibleTabs && allowedItems.count > 0) {
            NSMapTable<UIView *, NSMutableArray<UIView *> *> *byParent = [NSMapTable weakToStrongObjectsMapTable];
            for (UIView *item in allowedItems) {
                UIView *parent = item.superview;
                if (!parent) continue;
                NSMutableArray<UIView *> *group = [byParent objectForKey:parent];
                if (!group) {
                    group = [NSMutableArray array];
                    [byParent setObject:group forKey:parent];
                }
                [group addObject:item];
            }

            for (UIView *parent in byParent.keyEnumerator) {
                NSMutableArray<UIView *> *group = [byParent objectForKey:parent];
                CGFloat parentW = CGRectGetWidth(parent.bounds);
                if (parentW < 30.0 || group.count == 0) continue;

                CGFloat maxSlotW = 92.0;
                CGFloat slotW = MIN(parentW / (CGFloat)group.count, maxSlotW);
                CGFloat totalW = slotW * (CGFloat)group.count;
                CGFloat startX = floor((parentW - totalW) * 0.5);

                for (NSUInteger i = 0; i < group.count; i++) {
                    UIView *item = group[i];
                    CGRect frame = item.frame;
                    frame.origin.x = startX + (CGFloat)i * slotW;
                    frame.size.width = slotW;
                    item.frame = frame;
                }
            }
        } else {
            for (UIView *item in allowedItems) {
                NSValue *origVal = objc_getAssociatedObject(item, &kOrigFrameKey);
                if (origVal) item.frame = origVal.CGRectValue;
            }
        }
    } @catch (__unused NSException *e) {
    }
    gIsReflowingNavbar = NO;
}

#pragma mark - Marketplace Auto-Navigation

static BOOL FFBTryInvokeGestureRecognizersOnView(UIView *view, NSUInteger depth) {
    if (!view || depth > 3) return NO;
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *ctrl = (UIControl *)view;
        if (ctrl.allTargets.count > 0) {
            [ctrl sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }
    for (UIGestureRecognizer *gr in view.gestureRecognizers) {
        if ([gr isKindOfClass:UITapGestureRecognizer.class] && gr.isEnabled) {
            UITapGestureRecognizer *tap = (UITapGestureRecognizer *)gr;
            if (tap.numberOfTapsRequired == 1 && tap.numberOfTouchesRequired == 1) {
                @try {
                    Ivar targetsIvar = class_getInstanceVariable(UIGestureRecognizer.class, "_targets");
                    if (targetsIvar) {
                        NSArray *targets = object_getIvar(tap, targetsIvar);
                        if ([targets isKindOfClass:NSArray.class] && targets.count > 0) {
                            BOOL invoked = NO;
                            for (id pair in targets) {
                                Ivar targetIvar = class_getInstanceVariable([pair class], "_target");
                                Ivar actionIvar = class_getInstanceVariable([pair class], "_action");
                                if (targetIvar && actionIvar) {
                                    id targetObj = object_getIvar(pair, targetIvar);
                                    const uint8_t *basePtr = (const uint8_t *)(__bridge const void *)pair;
                                    SEL actionSel = *(const SEL *)(basePtr + ivar_getOffset(actionIvar));
                                    if (targetObj && actionSel && [targetObj respondsToSelector:actionSel]) {
                                        ((void (*)(id, SEL, id))objc_msgSend)(targetObj, actionSel, tap);
                                        invoked = YES;
                                    }
                                }
                            }
                            if (invoked) return YES;
                        }
                    }
                } @catch (__unused NSException *e) {
                }
            }
        }
    }
    for (UIView *sub in view.subviews) {
        if (FFBTryInvokeGestureRecognizersOnView(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL FFBOpenInternalFacebookURL(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;
    @try {
        id<UIApplicationDelegate> appDel = UIApplication.sharedApplication.delegate;
        if (appDel && [appDel respondsToSelector:@selector(application:openURL:options:)]) {
            BOOL handled = [appDel application:UIApplication.sharedApplication
                                       openURL:url
                                       options:@{}];
            if (handled) return YES;
        }
        SEL legacySel = @selector(application:openURL:sourceApplication:annotation:);
        if (appDel && [appDel respondsToSelector:legacySel]) {
            BOOL handled = ((BOOL (*)(id, SEL, UIApplication *, NSURL *, NSString *, id))objc_msgSend)(
                appDel, legacySel, UIApplication.sharedApplication, url,
                NSBundle.mainBundle.bundleIdentifier ?: @"com.facebook.Facebook", nil);
            if (handled) return YES;
        }
    } @catch (__unused NSException *e) {
    }
    return NO;
}

static BOOL FFBIsAuthOrLoginScreenVisible(void) {
    UIViewController *top = FocusFBTopMostViewController();
    if (!top) return NO;
    NSString *cls = NSStringFromClass(top.class).lowercaseString;
    return ([cls containsString:@"login"] ||
            [cls containsString:@"auth"] ||
            [cls containsString:@"dbl"] ||
            [cls containsString:@"checkpoint"] ||
            [cls containsString:@"registration"] ||
            [cls containsString:@"twofactor"]);
}

static BOOL FFBIsHomeFeedControllerName(NSString *clsName);
static BOOL FFBIsReelsOrWatchControllerName(NSString *clsName);

static NSString *FFBReadSurfaceModuleName(UIViewController *vc) {
    if (!vc) return nil;
    static NSArray<NSString *> *propNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        propNames = @[@"moduleName", @"surfaceName", @"analyticsModule", @"fb_analyticsModule"];
    });

    Class vcCls = object_getClass(vc);
    for (NSString *p in propNames) {
        SEL sel = NSSelectorFromString(p);
        if (FFBMethodReturnsObjOnClass(vcCls, sel)) {
            @try {
                id val = ((id (*)(id, SEL))objc_msgSend)(vc, sel);
                if ([val isKindOfClass:NSString.class] && ((NSString *)val).length > 0) {
                    return (NSString *)val;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    if (vc.isViewLoaded && vc.view) {
        Class vCls = object_getClass(vc.view);
        for (NSString *p in propNames) {
            SEL sel = NSSelectorFromString(p);
            if (FFBMethodReturnsObjOnClass(vCls, sel)) {
                @try {
                    id val = ((id (*)(id, SEL))objc_msgSend)(vc.view, sel);
                    if ([val isKindOfClass:NSString.class] && ((NSString *)val).length > 0) {
                        return (NSString *)val;
                    }
                } @catch (__unused NSException *e) {}
            }
        }
    }
    return nil;
}

static BOOL FFBControllerLooksLikeMarketplaceContext(UIViewController *vc) {
    if (!vc) return NO;
    NSString *cls = NSStringFromClass(vc.class).lowercaseString;
    NSString *title = (vc.navigationItem.title ?: vc.title ?: vc.tabBarItem.title ?: @"").lowercaseString;
    if ([cls containsString:@"marketplace"] ||
        [cls containsString:@"b2c"] ||
        [cls containsString:@"commerce"] ||
        [cls containsString:@"buysell"] ||
        [title containsString:@"marketplace"]) {
        return YES;
    }

    NSString *mod = FFBReadSurfaceModuleName(vc).lowercaseString;
    if (mod.length > 0) {
        if ([mod containsString:@"marketplace"] ||
            [mod containsString:@"commerce"] ||
            [mod containsString:@"product_details"] ||
            [mod containsString:@"buy_sell"]) {
            return YES;
        }
        if ([mod containsString:@"newsfeed"] ||
            [mod containsString:@"friending"] ||
            [mod containsString:@"notifications"] ||
            [mod containsString:@"bookmarks"] ||
            [mod containsString:@"groups"] ||
            [mod containsString:@"timeline"] ||
            [mod containsString:@"shorts"] ||
            [mod containsString:@"reels"]) {
            return NO;
        }
    }

    if ([cls containsString:@"fbreact"] || [cls containsString:@"rct"]) {
        return YES;
    }
    return NO;
}

static BOOL FFBControllerLooksExplicitlyNonMarketplaceRoot(UIViewController *vc) {
    if (!vc) return NO;
    NSString *clsName = NSStringFromClass(vc.class);
    if (FFBIsHomeFeedControllerName(clsName) || FFBIsReelsOrWatchControllerName(clsName)) {
        return YES;
    }
    NSString *lower = clsName.lowercaseString;
    if ([lower containsString:@"marketplace"] || [lower containsString:@"commerce"]) {
        return NO;
    }
    if ([lower containsString:@"snacks"] ||
        [lower containsString:@"storyviewer"] ||
        [lower containsString:@"storiesviewer"] ||
        [lower containsString:@"notificationsview"] ||
        [lower containsString:@"notificationtab"] ||
        [lower containsString:@"bookmarksview"] ||
        [lower containsString:@"menutab"] ||
        [lower containsString:@"friending"] ||
        [lower containsString:@"friendcenter"] ||
        [lower containsString:@"groupstab"] ||
        [lower containsString:@"groupslanding"] ||
        [lower containsString:@"profileviewcontroller"] ||
        [lower containsString:@"timelineviewcontroller"] ||
        [lower containsString:@"gaming"]) {
        return YES;
    }

    NSString *mod = FFBReadSurfaceModuleName(vc).lowercaseString;
    if (mod.length > 0 &&
        ([mod containsString:@"newsfeed"] ||
         [mod containsString:@"friending"] ||
         [mod containsString:@"notifications"] ||
         [mod containsString:@"bookmarks"] ||
         [mod containsString:@"groups_tab"] ||
         [mod containsString:@"timeline"] ||
         [mod containsString:@"shorts"] ||
         [mod containsString:@"reels"] ||
         [mod containsString:@"stories"])) {
        return YES;
    }
    return NO;
}

// Restituisce +1 se la catena appartiene a Marketplace, -1 se appartiene a Feed/Reels/Social, 0 se neutro (es. modal foto/sheet)
static NSInteger FFBClassifyControllerChainForMarketplace(UIViewController *leafVC) {
    UIViewController *cur = leafVC;
    NSUInteger guard = 0;

    while (cur && guard++ < 24) {
        if ([cur isKindOfClass:FocusFBSettingsViewController.class] ||
            [cur isKindOfClass:UIAlertController.class]) {
            cur = cur.presentingViewController ?: cur.parentViewController;
            continue;
        }

        NSString *clsName = NSStringFromClass(cur.class);
        if (FFBIsHomeFeedControllerName(clsName) || FFBIsReelsOrWatchControllerName(clsName)) {
            return -1;
        }

        if (cur.navigationController && cur.navigationController.viewControllers.count > 0) {
            UIViewController *rootStackVC = cur.navigationController.viewControllers.firstObject;
            if (FFBControllerLooksLikeMarketplaceContext(rootStackVC)) {
                return 1;
            }
            if (FFBControllerLooksExplicitlyNonMarketplaceRoot(rootStackVC)) {
                return -1;
            }
            for (UIViewController *stackVC in [cur.navigationController.viewControllers reverseObjectEnumerator]) {
                if (FFBControllerLooksLikeMarketplaceContext(stackVC)) {
                    return 1;
                }
                if (FFBControllerLooksExplicitlyNonMarketplaceRoot(stackVC)) {
                    return -1;
                }
            }
        }

        if (FFBControllerLooksLikeMarketplaceContext(cur)) {
            return 1;
        }
        if (FFBControllerLooksExplicitlyNonMarketplaceRoot(cur)) {
            return -1;
        }

        if (cur.parentViewController) {
            cur = cur.parentViewController;
        } else if (cur.presentingViewController) {
            cur = cur.presentingViewController;
        } else {
            break;
        }
    }
    return 0;
}

BOOL FocusFBIsUserCurrentlyInMarketplace(void) {
    UIWindow *win = FocusFBActiveWindow();
    if (!win || !win.rootViewController || !win.rootViewController.isViewLoaded) {
        return YES; // Durante l'avvio iniziale non bloccare mai prematuramente
    }
    if (FFBIsAuthOrLoginScreenVisible()) {
        return YES;
    }

    // Viewer Storie a tutto schermo -> superficie distraente (NON Marketplace)
    if (FocusFBIsStoryViewerVisibleNow()) {
        gLastKnownPrimaryTabIsMarketplace = NO;
        return NO;
    }

    // 1. Ispeziona il ViewController visibile (ora scende anche dentro FBTabBarViewController / FBTabBarAndContentViewController!)
    UIViewController *top = FocusFBTopMostViewController();
    NSInteger topVerdict = FFBClassifyControllerChainForMarketplace(top);
    if (topVerdict > 0) {
        gLastKnownPrimaryTabIsMarketplace = YES;
        return YES;
    }
    if (topVerdict < 0) {
        gLastKnownPrimaryTabIsMarketplace = NO;
        return NO;
    }

    // 2. Se il topVC è neutro (es. FBPhotoViewController su una foto di un annuncio, ActionSheet, Impostazioni),
    //    ispeziona la tab primaria attiva sotto eventuali modal!
    UIViewController *primaryLeaf = win.rootViewController;
    NSUInteger guard = 0;
    while (primaryLeaf && guard++ < 16) {
        if ([primaryLeaf isKindOfClass:UINavigationController.class]) {
            UIViewController *vis = ((UINavigationController *)primaryLeaf).topViewController;
            if (!vis || vis == primaryLeaf) break;
            primaryLeaf = vis;
        } else if ([primaryLeaf isKindOfClass:UITabBarController.class]) {
            UIViewController *sel = ((UITabBarController *)primaryLeaf).selectedViewController;
            if (!sel || sel == primaryLeaf) break;
            primaryLeaf = sel;
        } else {
            UIViewController *visChild = FFBBestVisibleChildOfContainer(primaryLeaf, win);
            if (!visChild || visChild == primaryLeaf) break;
            primaryLeaf = visChild;
        }
    }
    NSInteger primaryVerdict = FFBClassifyControllerChainForMarketplace(primaryLeaf);
    if (primaryVerdict > 0) {
        gLastKnownPrimaryTabIsMarketplace = YES;
        return YES;
    }
    if (primaryVerdict < 0) {
        gLastKnownPrimaryTabIsMarketplace = NO;
        return NO;
    }

    // 3. Controlla quale tab risulta selezionato sulla barra di Facebook
    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    FFBFindAllTabBarsInView(win.rootViewController.viewIfLoaded, 0, bars);
    for (UIView *bar in bars) {
        if ([bar isKindOfClass:UITabBar.class]) {
            UITabBarItem *selItem = ((UITabBar *)bar).selectedItem;
            if (selItem) {
                NSString *ident = selItem.accessibilityIdentifier ?: @"";
                NSString *lbl = selItem.title ?: selItem.accessibilityLabel ?: @"";
                FocusFBTabType selType = [FocusFBPrefs classifyTabWithIdentifier:ident label:lbl];
                if (selType == FocusFBTabMarketplace) {
                    gLastKnownPrimaryTabIsMarketplace = YES;
                    return YES;
                }
                if (selType != FocusFBTabUnknown) {
                    gLastKnownPrimaryTabIsMarketplace = NO;
                    return NO;
                }
            }
        }
        NSMutableArray<UIView *> *items = [NSMutableArray array];
        FFBCollectTabItemViews(bar, bar, 0, items);
        for (NSUInteger idx = 0; idx < items.count; idx++) {
            UIView *item = items[idx];
            if (FFBIsItemMarkedSelected(item, 0)) {
                FocusFBTabType type = FocusFBTabUnknown;
                FFBDescribeTabItem(item, idx, NULL, NULL, NULL, &type);
                if (type == FocusFBTabMarketplace) {
                    gLastKnownPrimaryTabIsMarketplace = YES;
                    return YES;
                }
                if (type != FocusFBTabUnknown) {
                    gLastKnownPrimaryTabIsMarketplace = NO;
                    return NO;
                }
            }
        }
    }

    // 4. Se l'utente è in modalità Solo Marketplace (nessuna tab distraente attiva) e nessuna schermata
    //    distraente è aperta, mantieni sempre Marketplace sbloccato!
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    if (prefs.enabled && prefs.showMarketplaceTab &&
        !prefs.showHomeTab && !prefs.showReelsTab &&
        !prefs.showFriendsTab && !prefs.showGroupsTab &&
        gDidInitialLaunchRedirect) {
        gLastKnownPrimaryTabIsMarketplace = YES;
        return YES;
    }

    return gLastKnownPrimaryTabIsMarketplace;
}

void FocusFBForceSwitchToMarketplaceNow(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = FocusFBActiveWindow();
        if (win.rootViewController.presentedViewController &&
            ![win.rootViewController.presentedViewController isBeingDismissed]) {
            NSString *pCls = NSStringFromClass(win.rootViewController.presentedViewController.class);
            if (![pCls hasPrefix:@"FocusFB"] && ![pCls hasPrefix:@"FFB"]) {
                [win.rootViewController dismissViewControllerAnimated:NO completion:nil];
            }
        }

        UIView *marketplaceItem = nil;
        if (win && win.rootViewController.isViewLoaded) {
            NSMutableArray<UIView *> *bars = [NSMutableArray array];
            FFBFindAllTabBarsInView(win.rootViewController.viewIfLoaded, 0, bars);
            for (UIView *bar in bars) {
                NSMutableArray<UIView *> *items = [NSMutableArray array];
                FFBCollectTabItemViews(bar, bar, 0, items);
                for (NSUInteger idx = 0; idx < items.count; idx++) {
                    UIView *item = items[idx];
                    FocusFBTabType type = FocusFBTabUnknown;
                    FFBDescribeTabItem(item, idx, NULL, NULL, NULL, &type);
                    if (type == FocusFBTabMarketplace) {
                        marketplaceItem = item;
                        break;
                    }
                }
                if (marketplaceItem) break;
            }
        }

        BOOL tapped = NO;
        if (marketplaceItem) {
            tapped = FFBTryInvokeGestureRecognizersOnView(marketplaceItem, 0);
        }
        if (!tapped) {
            FFBOpenInternalFacebookURL(@"fb://marketplace");
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!FocusFBIsUserCurrentlyInMarketplace()) {
                    FFBOpenInternalFacebookURL(@"fb://marketplace");
                }
            });
        }
        gDidInitialLaunchRedirect = YES;
        FocusFBRefreshUIImmediately();
    });
}

static BOOL FFBIsMarketplaceCurrentlySelectedOrVisible(UIView **outMarketplaceItem) {
    UIWindow *win = FocusFBActiveWindow();
    if (!win || !win.rootViewController.isViewLoaded) return NO;

    UIViewController *top = FocusFBTopMostViewController();
    if (top) {
        if (FFBControllerLooksLikeMarketplaceContext(top)) return YES;
        if (top.navigationController) {
            for (UIViewController *stackVC in top.navigationController.viewControllers) {
                if (FFBControllerLooksLikeMarketplaceContext(stackVC)) {
                    return YES;
                }
            }
        }
    }

    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    FFBFindAllTabBarsInView(win.rootViewController.viewIfLoaded, 0, bars);
    for (UIView *bar in bars) {
        NSMutableArray<UIView *> *items = [NSMutableArray array];
        FFBCollectTabItemViews(bar, bar, 0, items);
        for (NSUInteger idx = 0; idx < items.count; idx++) {
            UIView *item = items[idx];
            FocusFBTabType type = FocusFBTabUnknown;
            FFBDescribeTabItem(item, idx, NULL, NULL, NULL, &type);
            if (type == FocusFBTabMarketplace) {
                if (outMarketplaceItem) *outMarketplaceItem = item;
                if (FFBIsItemMarkedSelected(item, 0)) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

void FocusFBNavigateToMarketplace(BOOL allowDeepLinkFallback) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (FFBIsAuthOrLoginScreenVisible()) return;
        if ([FocusFBLockManager shared].isLockWallVisible ||
            [FocusFBLockManager shared].pauseCountingForFocusFBUI) {
            return;
        }

        UIWindow *win = FocusFBActiveWindow();
        if (win.rootViewController.presentedViewController != nil) {
            // Non interrompere mai schermate modali aperte (Impostazioni, Scanner, Schede, Alert)
            return;
        }

        CFTimeInterval now = CACurrentMediaTime();
        if (now - gLastMarketplaceRedirectAttempt < 0.40) return;
        gLastMarketplaceRedirectAttempt = now;

        UIView *marketplaceItem = nil;
        if (FFBIsMarketplaceCurrentlySelectedOrVisible(&marketplaceItem)) {
            gDidInitialLaunchRedirect = YES;
            return;
        }

        BOOL tappedItem = NO;
        if (marketplaceItem) {
            tappedItem = FFBTryInvokeGestureRecognizersOnView(marketplaceItem, 0);
        }

        if (tappedItem) {
            gDidInitialLaunchRedirect = YES;
        } else if (allowDeepLinkFallback) {
            if (FFBOpenInternalFacebookURL(@"fb://marketplace")) {
                gDidInitialLaunchRedirect = YES;
            }
        }
    });
}

#pragma mark - Anti-Distraction Shields (Feed & Reels) & Audio Pause

static void FFBPauseAVPlayersInSubtree(UIView *view, NSUInteger depth) {
    if (!view || depth > 14) return;
    @try {
        if ([view.layer isKindOfClass:AVPlayerLayer.class]) {
            AVPlayer *player = ((AVPlayerLayer *)view.layer).player;
            if (player && player.rate != 0.0f) {
                [player pause];
            }
        }
        SEL playerSel = NSSelectorFromString(@"player");
        if ([view respondsToSelector:playerSel]) {
            Method m = class_getInstanceMethod(object_getClass(view), playerSel);
            if (m && method_getNumberOfArguments(m) == 2) {
                char *ret = method_copyReturnType(m);
                BOOL isObj = (ret && ret[0] == '@');
                free(ret);
                if (isObj) {
                    id obj = ((id (*)(id, SEL))objc_msgSend)(view, playerSel);
                    if ([obj isKindOfClass:AVPlayer.class]) {
                        [(AVPlayer *)obj pause];
                    }
                }
            }
        }
    } @catch (__unused NSException *e) {
    }
    for (UIView *sub in view.subviews) {
        FFBPauseAVPlayersInSubtree(sub, depth + 1);
    }
}

static UIView *FFBBuildShieldView(NSInteger tag,
                                  NSString *symbolName,
                                  NSString *titleText,
                                  NSString *bodyText,
                                  BOOL includeBackButton) {
    UIVisualEffectView *shield = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    shield.tag = tag;
    shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:44.0 weight:UIImageSymbolWeightSemibold];
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbolName withConfiguration:symCfg]];
    iconView.tintColor = [UIColor systemBlueColor];
    [stack addArrangedSubview:iconView];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = titleText;
    titleLbl.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    titleLbl.textColor = [UIColor labelColor];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    titleLbl.numberOfLines = 0;
    [stack addArrangedSubview:titleLbl];

    UILabel *bodyLbl = [[UILabel alloc] init];
    bodyLbl.text = bodyText;
    bodyLbl.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightRegular];
    bodyLbl.textColor = [UIColor secondaryLabelColor];
    bodyLbl.textAlignment = NSTextAlignmentCenter;
    bodyLbl.numberOfLines = 0;
    [stack addArrangedSubview:bodyLbl];

    [stack setCustomSpacing:22.0 afterView:bodyLbl];

    UIButton *marketBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    marketBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [marketBtn setTitle:[NSString stringWithFormat:@"  %@", FFBLoc(@"Overlay.GoMarketplace")] forState:UIControlStateNormal];
    [marketBtn setImage:[UIImage systemImageNamed:@"storefront.fill"] forState:UIControlStateNormal];
    marketBtn.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    marketBtn.backgroundColor = [UIColor systemBlueColor];
    [marketBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    marketBtn.tintColor = [UIColor whiteColor];
    marketBtn.layer.cornerRadius = 14.0;
    [NSLayoutConstraint activateConstraints:@[
        [marketBtn.heightAnchor constraintEqualToConstant:48.0],
        [marketBtn.widthAnchor constraintGreaterThanOrEqualToConstant:230.0]
    ]];
    [marketBtn addTarget:FFBSharedActionTarget() action:@selector(handleShieldOpenMarketplace:) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:marketBtn];

    if (includeBackButton) {
        UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        backBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [backBtn setTitle:FFBLoc(@"Overlay.GoBack") forState:UIControlStateNormal];
        backBtn.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
        [backBtn addTarget:FFBSharedActionTarget() action:@selector(handleShieldGoBack:) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:backBtn];
    }

    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [settingsBtn setTitle:FFBLoc(@"Overlay.OpenSettings") forState:UIControlStateNormal];
    settingsBtn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
    [settingsBtn setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [settingsBtn addTarget:FFBSharedActionTarget() action:@selector(handleShieldOpenSettings:) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:settingsBtn];

    [shield.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:shield.contentView.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:shield.contentView.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:shield.contentView.leadingAnchor constant:28.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:shield.contentView.trailingAnchor constant:-28.0]
    ]];

    return shield;
}

static BOOL FFBIsHomeFeedControllerName(NSString *clsName) {
    NSString *lower = clsName.lowercaseString;
    if ([lower containsString:@"marketplace"] || [lower containsString:@"group"] ||
        [lower containsString:@"profile"] || [lower containsString:@"search"] ||
        [lower containsString:@"comment"] || [lower containsString:@"notification"]) {
        return NO;
    }
    return ([clsName isEqualToString:@"FBFeedViewController"] ||
            [clsName isEqualToString:@"FBNewsFeedViewController"] ||
            [clsName isEqualToString:@"FBMainFeedViewController"] ||
            [clsName isEqualToString:@"FBCompositeFeedViewController"] ||
            [clsName isEqualToString:@"FBMostRecentFeedViewController"] ||
            [lower hasPrefix:@"fbnewsfeed"] ||
            [lower hasPrefix:@"fbmainfeed"]);
}

static BOOL FFBIsReelsOrWatchControllerName(NSString *clsName) {
    NSString *lower = clsName.lowercaseString;
    if ([lower containsString:@"marketplace"]) return NO;
    return ([lower containsString:@"reelsviewer"] ||
            [lower containsString:@"reelsfeed"] ||
            [lower containsString:@"inspirationreels"] ||
            [lower containsString:@"shortformvideo"] ||
            [lower containsString:@"fbvideohome"] ||
            [lower containsString:@"fbwatchfeed"] ||
            [lower containsString:@"fbtahoe"]);
}

static void FFBHideInlineStoriesAndReelsViews(UIView *root, NSUInteger depth) {
    if (!root || depth > 8) return;
    NSString *cls = NSStringFromClass(object_getClass(root)).lowercaseString;
    if ([cls containsString:@"storiestray"] ||
        [cls containsString:@"inlinesnacks"] ||
        [cls containsString:@"reelshscroll"] ||
        [cls containsString:@"reelsunit"]) {
        root.hidden = YES;
        root.alpha = 0.0;
        return;
    }
    for (UIView *sub in root.subviews) {
        FFBHideInlineStoriesAndReelsViews(sub, depth + 1);
    }
}

static void FFBApplyControllerProtection(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded || [vc isKindOfClass:FocusFBSettingsViewController.class] ||
        [vc isKindOfClass:UIAlertController.class]) {
        return;
    }

    NSString *clsName = NSStringFromClass(vc.class);
    UIView *v = vc.viewIfLoaded;
    if (!v) return;

    FocusFBPrefs *prefs = [FocusFBPrefs shared];

    // 1. Scudo Feed Home
    BOOL forceMPOnly = [FocusFBLockManager shared].shouldForceMarketplaceOnlyNow;
    BOOL shouldShieldFeed = prefs.enabled && (!prefs.showHomeTab || forceMPOnly) && prefs.shieldHomeFeed && FFBIsHomeFeedControllerName(clsName);
    UIView *existingFeedShield = [v viewWithTag:kFeedShieldTag];
    if (shouldShieldFeed) {
        FFBPauseAVPlayersInSubtree(v, 0);
        if (!existingFeedShield) {
            UIView *shield = FFBBuildShieldView(kFeedShieldTag,
                                                @"eye.slash.circle.fill",
                                                FFBLoc(@"Overlay.FeedTitle"),
                                                FFBLoc(@"Overlay.FeedBody"),
                                                NO);
            shield.frame = v.bounds;
            [v addSubview:shield];
        } else {
            existingFeedShield.frame = v.bounds;
            [v bringSubviewToFront:existingFeedShield];
        }
    } else if (existingFeedShield) {
        [existingFeedShield removeFromSuperview];
    }

    // 2. Blocco Player Reels / Watch
    BOOL shouldBlockReels = prefs.enabled && prefs.blockReelsEverywhere && FFBIsReelsOrWatchControllerName(clsName);
    UIView *existingReelsShield = [v viewWithTag:kReelsShieldTag];
    if (shouldBlockReels) {
        FFBPauseAVPlayersInSubtree(v, 0);
        if (!existingReelsShield) {
            UIView *shield = FFBBuildShieldView(kReelsShieldTag,
                                                @"hand.raised.circle.fill",
                                                FFBLoc(@"Overlay.ReelsTitle"),
                                                FFBLoc(@"Overlay.ReelsBody"),
                                                YES);
            shield.frame = v.bounds;
            [v addSubview:shield];
        } else {
            existingReelsShield.frame = v.bounds;
            [v bringSubviewToFront:existingReelsShield];
        }
    } else if (existingReelsShield) {
        [existingReelsShield removeFromSuperview];
    }

    // 3. Storie e caroselli Reels inline (solo sul Feed Home, mai su Marketplace!)
    if (prefs.enabled && (prefs.hideStoriesTray || prefs.hideReelsCarousel) && FFBIsHomeFeedControllerName(clsName)) {
        FFBHideInlineStoriesAndReelsViews(v, 0);
    }
}

static void FFBWalkAndProtectControllers(UIViewController *vc, NSUInteger depth) {
    if (!vc || depth > 14) return;
    FFBApplyControllerProtection(vc);
    for (UIViewController *child in vc.childViewControllers) {
        FFBWalkAndProtectControllers(child, depth + 1);
    }
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        FFBWalkAndProtectControllers(vc.presentedViewController, depth + 1);
    }
}

static void FFBReevaluateVisibleControllers(void) {
    UIWindow *win = FocusFBActiveWindow();
    if (!win || !win.rootViewController) return;
    FFBWalkAndProtectControllers(win.rootViewController, 0);
}

#pragma mark - Swizzled Methods

static void FFBHook_FloatingBar_layoutSubviews(id self, SEL _cmd) {
    if (gOrigFloatingBarLayout) gOrigFloatingBarLayout(self, _cmd);
    FFBApplyFilterToTabBar((UIView *)self);
}

static void FFBHook_NativeGlassBar_layoutSubviews(id self, SEL _cmd) {
    if (gOrigNativeGlassBarLayout) gOrigNativeGlassBarLayout(self, _cmd);
    FFBApplyFilterToTabBar((UIView *)self);
}

static void FFBHook_LegacyBar_layoutSubviews(id self, SEL _cmd) {
    if (gOrigLegacyBarLayout) gOrigLegacyBarLayout(self, _cmd);
    FFBApplyFilterToTabBar((UIView *)self);
}

static void FFBHook_UITabBar_layoutSubviews(id self, SEL _cmd) {
    if (gOrigUITabBarLayout) gOrigUITabBarLayout(self, _cmd);
    UIView *view = (UIView *)self;
    UIResponder *resp = view.nextResponder;
    while (resp && ![resp isKindOfClass:UIViewController.class]) {
        resp = resp.nextResponder;
    }
    if (resp && [NSStringFromClass(resp.class) hasPrefix:@"FB"]) {
        FFBApplyFilterToTabBar(view);
    }
}

static void FFBHook_FloatingItem_layoutSubviews(id self, SEL _cmd) {
    if (gOrigFloatingItemLayout) gOrigFloatingItemLayout(self, _cmd);
    FFBAttachContextMenuToTabItem((UIView *)self);
}

static void FFBHook_LegacyItem_layoutSubviews(id self, SEL _cmd) {
    if (gOrigLegacyItemLayout) gOrigLegacyItemLayout(self, _cmd);
    FFBAttachContextMenuToTabItem((UIView *)self);
}

static NSArray<UIView *> *FFBCachedOrDiscoveredBarsForVC(UIViewController *vc, BOOL forceRescan) {
    if (!vc.isViewLoaded || !vc.view) return @[];
    NSHashTable<UIView *> *table = objc_getAssociatedObject(vc, &kCachedVCBarsKey);
    if (!forceRescan && table && table.allObjects.count > 0) {
        return table.allObjects;
    }
    NSMutableArray<UIView *> *bars = [NSMutableArray array];
    FFBFindAllTabBarsInView(vc.view, 0, bars);
    if (bars.count > 0) {
        NSHashTable<UIView *> *weakSet = [NSHashTable weakObjectsHashTable];
        for (UIView *b in bars) {
            [weakSet addObject:b];
        }
        objc_setAssociatedObject(vc, &kCachedVCBarsKey, weakSet, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return bars;
}

static void FFBHook_TabBarVC_viewDidLayoutSubviews(id self, SEL _cmd) {
    if (gOrigTabBarVCLayout) gOrigTabBarVCLayout(self, _cmd);
    UIViewController *vc = (UIViewController *)self;
    if (!vc.isViewLoaded || !vc.view) return;
    for (UIView *bar in FFBCachedOrDiscoveredBarsForVC(vc, NO)) {
        FFBApplyFilterToTabBar(bar);
    }
}

static void FFBHook_TabAndContentVC_viewDidLayoutSubviews(id self, SEL _cmd) {
    if (gOrigTabAndContentVCLayout) gOrigTabAndContentVCLayout(self, _cmd);
    UIViewController *vc = (UIViewController *)self;
    if (!vc.isViewLoaded || !vc.view) return;
    if (gForceFullScreenSingleBar && gOrigSetOffsetFrac) {
        SEL offSel = NSSelectorFromString(@"setTabBarViewOffsetFraction:animationKind:");
        if ([vc respondsToSelector:offSel]) {
            gOrigSetOffsetFrac(vc, offSel, 1.0, 0);
        }
    }
    for (UIView *bar in FFBCachedOrDiscoveredBarsForVC(vc, NO)) {
        FFBApplyFilterToTabBar(bar);
    }
}

static void FFBHook_setTabBarViewOffsetFraction(id self, SEL _cmd, double fraction, NSUInteger kind) {
    if (gForceFullScreenSingleBar) {
        fraction = 1.0; // Mantiene la barra nativa spinta fuori schermo (100% full-screen)
    }
    if (gOrigSetOffsetFrac) {
        gOrigSetOffsetFrac(self, _cmd, fraction, kind);
    }
}

static void FFBHook_VC_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigVCViewDidAppear) gOrigVCViewDidAppear(self, _cmd, animated);

    UIViewController *vc = (UIViewController *)self;
    NSString *clsName = NSStringFromClass(vc.class);

    // Installa hook su classi caricate pigramente da Facebook
    FFBInstallDynamicHooksAvailableNow();

    if ([clsName hasPrefix:@"FB"] || [clsName hasPrefix:@"META"] ||
        [clsName hasPrefix:@"MDS"] || [clsName hasPrefix:@"CDS"] ||
        [clsName hasPrefix:@"RCT"]) {
        FFBApplyControllerProtection(vc);
        [[FocusFBLockManager shared] refreshEnforcementUI];
        FocusFBMediaDownloaderSyncUI();

        if (FFBClassInheritsName(vc.class, kTabControllerName)) {
            FocusFBRefreshUIImmediately();
            BOOL forceMPStart = [FocusFBLockManager shared].shouldForceMarketplaceOnlyNow;
            if ([FocusFBPrefs shared].enabled && ([FocusFBPrefs shared].startOnMarketplace || forceMPStart) && !gDidInitialLaunchRedirect) {
                gDidInitialLaunchRedirect = YES;
                FocusFBNavigateToMarketplace(YES);
            }
            [FocusFBSettingsViewController presentWelcomeIfNeeded];
        }
    }
}

#pragma mark - Safe Method Hook Installer

static BOOL FFBHookSpecificClassMethod(Class cls, SEL sel, IMP newIMP, IMP *origOut) {
    if (!cls || !sel || !newIMP) return NO;
    Method resolved = class_getInstanceMethod(cls, sel);
    if (!resolved) return NO;
    IMP orig = method_getImplementation(resolved);
    const char *types = method_getTypeEncoding(resolved);
    if (!orig || !types || orig == newIMP) return NO;

    if (origOut && *origOut == NULL) {
        *origOut = orig;
    }

    // Controlla se il metodo è già diretto sulla classe o ereditato dalla superclasse
    unsigned int count = 0;
    Method *directList = class_copyMethodList(cls, &count);
    BOOL hasDirect = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(directList[i]) == sel) {
            hasDirect = YES;
            break;
        }
    }
    free(directList);

    if (hasDirect) {
        class_replaceMethod(cls, sel, newIMP, types);
    } else {
        if (!class_addMethod(cls, sel, newIMP, types)) {
            return NO;
        }
    }
    return YES;
}

static void FFBInstallDynamicHooksAvailableNow(void) {
    if (!gHooksInstalledVC) {
        gHooksInstalledVC = FFBHookSpecificClassMethod(UIViewController.class,
                                                       @selector(viewDidAppear:),
                                                       (IMP)FFBHook_VC_viewDidAppear,
                                                       (IMP *)&gOrigVCViewDidAppear);
    }
    if (!gHooksInstalledFloatingBar) {
        Class cls = NSClassFromString(kFloatingBarClassName);
        if (cls) {
            gHooksInstalledFloatingBar = FFBHookSpecificClassMethod(cls,
                                                                    @selector(layoutSubviews),
                                                                    (IMP)FFBHook_FloatingBar_layoutSubviews,
                                                                    (IMP *)&gOrigFloatingBarLayout);
        }
    }
    if (!gHooksInstalledNativeGlassBar) {
        Class cls = NSClassFromString(kNativeGlassBarClassName);
        if (cls) {
            gHooksInstalledNativeGlassBar = FFBHookSpecificClassMethod(cls,
                                                                       @selector(layoutSubviews),
                                                                       (IMP)FFBHook_NativeGlassBar_layoutSubviews,
                                                                       (IMP *)&gOrigNativeGlassBarLayout);
        }
    }
    if (!gHooksInstalledFloatingItem) {
        Class cls = NSClassFromString(kFloatingItemClassName);
        if (cls) {
            gHooksInstalledFloatingItem = FFBHookSpecificClassMethod(cls,
                                                                     @selector(layoutSubviews),
                                                                     (IMP)FFBHook_FloatingItem_layoutSubviews,
                                                                     (IMP *)&gOrigFloatingItemLayout);
        }
    }
    if (!gHooksInstalledLegacyBar) {
        Class cls = NSClassFromString(kLegacyBarClassName);
        if (cls) {
            gHooksInstalledLegacyBar = FFBHookSpecificClassMethod(cls,
                                                                  @selector(layoutSubviews),
                                                                  (IMP)FFBHook_LegacyBar_layoutSubviews,
                                                                  (IMP *)&gOrigLegacyBarLayout);
        }
    }
    if (!gHooksInstalledLegacyItem) {
        Class cls = NSClassFromString(kLegacyItemClassName);
        if (cls) {
            gHooksInstalledLegacyItem = FFBHookSpecificClassMethod(cls,
                                                                   @selector(layoutSubviews),
                                                                   (IMP)FFBHook_LegacyItem_layoutSubviews,
                                                                   (IMP *)&gOrigLegacyItemLayout);
        }
    }
    if (!gHooksInstalledUITabBar) {
        gHooksInstalledUITabBar = FFBHookSpecificClassMethod(UITabBar.class,
                                                             @selector(layoutSubviews),
                                                             (IMP)FFBHook_UITabBar_layoutSubviews,
                                                             (IMP *)&gOrigUITabBarLayout);
    }
    if (!gHooksInstalledTabBarVC) {
        Class cls = NSClassFromString(kTabControllerName);
        if (cls) {
            gHooksInstalledTabBarVC = FFBHookSpecificClassMethod(cls,
                                                                 @selector(viewDidLayoutSubviews),
                                                                 (IMP)FFBHook_TabBarVC_viewDidLayoutSubviews,
                                                                 (IMP *)&gOrigTabBarVCLayout);
        }
    }
    if (!gHooksInstalledTabAndContentVC) {
        Class cls = NSClassFromString(kTabAndContentVCName);
        if (cls) {
            gHooksInstalledTabAndContentVC = FFBHookSpecificClassMethod(cls,
                                                                        @selector(viewDidLayoutSubviews),
                                                                        (IMP)FFBHook_TabAndContentVC_viewDidLayoutSubviews,
                                                                        (IMP *)&gOrigTabAndContentVCLayout);
        }
    }
    if (!gHooksInstalledOffsetFraction) {
        Class cls = NSClassFromString(kTabAndContentVCName);
        SEL offSel = NSSelectorFromString(@"setTabBarViewOffsetFraction:animationKind:");
        if (cls && [cls instancesRespondToSelector:offSel]) {
            gHooksInstalledOffsetFraction = FFBHookSpecificClassMethod(cls,
                                                                       offSel,
                                                                       (IMP)FFBHook_setTabBarViewOffsetFraction,
                                                                       (IMP *)&gOrigSetOffsetFrac);
        }
    }
}

#pragma mark - Public Engine Lifecycle

void FocusFBRefreshUIImmediately(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        FFBInstallDynamicHooksAvailableNow();
        UIWindow *win = FocusFBActiveWindow();
        if (!win) return;

        FFBAttachWindowShortcuts(win);

        if (win.rootViewController.isViewLoaded) {
            NSMutableArray<UIView *> *bars = [NSMutableArray array];
            FFBFindAllTabBarsInView(win.rootViewController.viewIfLoaded, 0, bars);
            for (UIView *bar in bars) {
                objc_setAssociatedObject(bar, &kCachedBarPassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                FFBApplyFilterToTabBar(bar);
                [bar setNeedsLayout];
            }
        }
        FFBReevaluateVisibleControllers();
        FocusFBMediaDownloaderSyncUI();
    });
}

static void FFBScheduleStartupPass(void) {
    NSArray<NSNumber *> *delays = @[@0.20, @0.65, @1.40, @2.80];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
            FocusFBRefreshUIImmediately();
            FocusFBPrefs *prefs = [FocusFBPrefs shared];
            BOOL forceMPStart = [FocusFBLockManager shared].shouldForceMarketplaceOnlyNow;
            if (!gDidInitialLaunchRedirect && prefs.enabled && (prefs.startOnMarketplace || forceMPStart)) {
                UIView *marketItem = nil;
                if (!FFBIsMarketplaceCurrentlySelectedOrVisible(&marketItem)) {
                    FocusFBNavigateToMarketplace(d.doubleValue >= 0.65);
                } else {
                    gDidInitialLaunchRedirect = YES;
                }
            }
            if (d.doubleValue >= 1.40) {
                [FocusFBSettingsViewController presentWelcomeIfNeeded];
            }
        });
    }
}

void FocusFBStartEngine(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        FFBInstallDynamicHooksAvailableNow();

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:FocusFBPreferencesDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            FocusFBRefreshUIImmediately();
        }];

        [nc addObserverForName:FocusFBLockStateDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            FocusFBRefreshUIImmediately();
        }];

        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            // Al ritorno in primo piano aggiorna SOLO il filtro tab/barra, MAI forzare navigazione!
            FocusFBRefreshUIImmediately();
        }];

        [nc addObserverForName:UIWindowDidBecomeKeyNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:UIWindow.class]) {
                UIWindow *w = (UIWindow *)note.object;
                if (w.windowLevel != UIWindowLevelNormal) {
                    return; // Ignora finestre alert, action sheet e blocco Foqos
                }
                NSString *rootCls = w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"";
                if ([rootCls hasPrefix:@"FFB"] || [rootCls hasPrefix:@"FocusFB"]) {
                    return;
                }
                FFBAttachWindowShortcuts(w);
            }
            FocusFBRefreshUIImmediately();
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            FFBScheduleStartupPass();
        });
    });
}
