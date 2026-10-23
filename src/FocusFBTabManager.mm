#import "FocusFBTabManager.h"
#import "FocusFBPrefs.h"
#import "FocusFBSettingsViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const kFloatingBarClassName  = @"FBFloatingTabBar";
static NSString * const kFloatingItemClassName = @"FBFloatingTabBar.FBFloatingTabBarItemView";
static NSString * const kLegacyBarClassName    = @"FBTabBar";
static NSString * const kLegacyItemClassName   = @"FBTabBarItemDefaultView";
static NSString * const kTabControllerName     = @"FBTabBarViewController";

static const NSInteger kFeedShieldTag  = 0x70C501;
static const NSInteger kReelsShieldTag = 0x70C502;
static const NSInteger kFloatingBtnTag = 0x70C503;

static char kOrigFrameKey;
static char kOrigIndexKey;
static char kContextDelegateKey;
static char kContextInteractionKey;
static char kBarLongPressKey;
static char kWindowTwoFingerKey;

typedef void (*FFBLayoutIMP)(id, SEL);
typedef void (*FFBViewDidAppearIMP)(id, SEL, BOOL);

static FFBLayoutIMP gOrigFloatingBarLayout  = NULL;
static FFBLayoutIMP gOrigLegacyBarLayout    = NULL;
static FFBLayoutIMP gOrigFloatingItemLayout = NULL;
static FFBLayoutIMP gOrigLegacyItemLayout   = NULL;
static FFBLayoutIMP gOrigUITabBarLayout     = NULL;
static FFBViewDidAppearIMP gOrigVCViewDidAppear = NULL;

static BOOL gHooksInstalledFloatingBar  = NO;
static BOOL gHooksInstalledLegacyBar    = NO;
static BOOL gHooksInstalledFloatingItem = NO;
static BOOL gHooksInstalledLegacyItem   = NO;
static BOOL gHooksInstalledUITabBar     = NO;
static BOOL gHooksInstalledVC           = NO;

static BOOL gIsReflowingNavbar = NO;
static BOOL gDidInitialLaunchRedirect = NO;
static CFTimeInterval gLastMarketplaceRedirectAttempt = 0;

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
            if (win.isKeyWindow) return win;
            if (!fallback || (win.windowLevel == UIWindowLevelNormal && fallback.windowLevel != UIWindowLevelNormal)) {
                fallback = win;
            }
        }
    }
    return fallback;
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
            break;
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

static void FFBApplyFilterToTabBar(UIView *bar) {
    if (!bar || gIsReflowingNavbar || !NSThread.isMainThread) return;
    if (CGRectIsEmpty(bar.bounds)) return;

    gIsReflowingNavbar = YES;
    @try {
        FFBAttachLongPressToBar(bar);

        NSMutableArray<UIView *> *items = [NSMutableArray array];
        FFBCollectTabItemViews(bar, bar, 0, items);
        if (items.count == 0) {
            gIsReflowingNavbar = NO;
            return;
        }

        FocusFBPrefs *prefs = [FocusFBPrefs shared];

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

            if ([prefs isTabAllowedForType:type key:key]) {
                [allowedItems addObject:item];
            }
        }

        // Se FocusFB è spento, ripristina tutti gli elementi
        if (!prefs.enabled) {
            bar.hidden = NO;
            bar.alpha = 1.0;
            bar.userInteractionEnabled = YES;
            for (UIView *item in items) {
                item.hidden = NO;
                item.alpha = 1.0;
                item.userInteractionEnabled = YES;
                NSValue *origVal = objc_getAssociatedObject(item, &kOrigFrameKey);
                if (origVal) item.frame = origVal.CGRectValue;
            }
            gIsReflowingNavbar = NO;
            return;
        }

        // Guardia di sicurezza: se tutti i tab presenti sulla barra risultano nascosti
        // (es. Marketplace non è tra i 5 tab fissati dall'account), mantieni almeno l'ultimo tab (Menu)
        if (allowedItems.count == 0 && items.count > 0 && !prefs.hideSingleTabBar) {
            [allowedItems addObject:items.lastObject];
        }

        // Opzione: nascondi l'intera barra inferiore quando resta <= 1 tab
        if (allowedItems.count <= 1 && prefs.hideSingleTabBar) {
            bar.hidden = YES;
            bar.alpha = 0.0;
            bar.userInteractionEnabled = NO;
            gIsReflowingNavbar = NO;
            return;
        } else {
            bar.hidden = NO;
            bar.alpha = 1.0;
            bar.userInteractionEnabled = YES;
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

static BOOL FFBIsMarketplaceCurrentlySelectedOrVisible(UIView **outMarketplaceItem) {
    UIWindow *win = FocusFBActiveWindow();
    if (!win || !win.rootViewController.isViewLoaded) return NO;

    UIViewController *top = FocusFBTopMostViewController();
    if (top) {
        NSString *topCls = NSStringFromClass(top.class).lowercaseString;
        NSString *topTitle = (top.navigationItem.title ?: top.title ?: @"").lowercaseString;
        if ([topCls containsString:@"marketplace"] ||
            [topCls containsString:@"b2c"] ||
            [topTitle containsString:@"marketplace"]) {
            return YES;
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

        CFTimeInterval now = CACurrentMediaTime();
        if (now - gLastMarketplaceRedirectAttempt < 0.25) return;
        gLastMarketplaceRedirectAttempt = now;

        UIView *marketplaceItem = nil;
        if (FFBIsMarketplaceCurrentlySelectedOrVisible(&marketplaceItem)) {
            return;
        }

        BOOL tappedItem = NO;
        if (marketplaceItem) {
            tappedItem = FFBTryInvokeGestureRecognizersOnView(marketplaceItem, 0);
        }

        if (!tappedItem && allowDeepLinkFallback) {
            FFBOpenInternalFacebookURL(@"fb://marketplace");
        } else if (tappedItem && allowDeepLinkFallback) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!FFBIsMarketplaceCurrentlySelectedOrVisible(NULL) && !FFBIsAuthOrLoginScreenVisible()) {
                    FFBOpenInternalFacebookURL(@"fb://marketplace");
                }
            });
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
    BOOL shouldShieldFeed = prefs.enabled && !prefs.showHomeTab && prefs.shieldHomeFeed && FFBIsHomeFeedControllerName(clsName);
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
        if (prefs.startOnMarketplace) {
            FocusFBNavigateToMarketplace(YES);
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

    // 3. Storie e caroselli Reels inline
    if (prefs.enabled && prefs.hideStoriesAndInlineReels && [clsName hasPrefix:@"FB"]) {
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

static void FFBHook_VC_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (gOrigVCViewDidAppear) gOrigVCViewDidAppear(self, _cmd, animated);

    UIViewController *vc = (UIViewController *)self;
    NSString *clsName = NSStringFromClass(vc.class);

    // Installa hook su classi caricate pigramente da Facebook
    FFBInstallDynamicHooksAvailableNow();

    if ([clsName hasPrefix:@"FB"] || [clsName hasPrefix:@"META"] ||
        [clsName hasPrefix:@"MDS"] || [clsName hasPrefix:@"CDS"]) {
        FFBApplyControllerProtection(vc);

        if (FFBClassInheritsName(vc.class, kTabControllerName)) {
            FocusFBRefreshUIImmediately();
            if ([FocusFBPrefs shared].enabled && [FocusFBPrefs shared].startOnMarketplace && !gDidInitialLaunchRedirect) {
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
                FFBApplyFilterToTabBar(bar);
                [bar setNeedsLayout];
            }
        }
        FFBReevaluateVisibleControllers();
    });
}

static void FFBScheduleStartupPass(void) {
    NSArray<NSNumber *> *delays = @[@0.15, @0.50, @1.20, @2.50, @4.50];
    for (NSNumber *d in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
            FocusFBRefreshUIImmediately();
            FocusFBPrefs *prefs = [FocusFBPrefs shared];
            if (prefs.enabled && prefs.startOnMarketplace) {
                UIView *marketItem = nil;
                if (!FFBIsMarketplaceCurrentlySelectedOrVisible(&marketItem)) {
                    FocusFBNavigateToMarketplace(d.doubleValue >= 1.0);
                } else {
                    gDidInitialLaunchRedirect = YES;
                }
            }
            if (d.doubleValue >= 1.20) {
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
            FocusFBPrefs *prefs = [FocusFBPrefs shared];
            if (prefs.enabled && prefs.showMarketplaceTab && !prefs.showHomeTab && prefs.startOnMarketplace) {
                FocusFBNavigateToMarketplace(NO);
            }
        }];

        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            FFBScheduleStartupPass();
        }];

        [nc addObserverForName:UIWindowDidBecomeKeyNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:UIWindow.class]) {
                FFBAttachWindowShortcuts((UIWindow *)note.object);
            }
            FocusFBRefreshUIImmediately();
        }];

        dispatch_async(dispatch_get_main_queue(), ^{
            FFBScheduleStartupPass();
        });
    });
}
