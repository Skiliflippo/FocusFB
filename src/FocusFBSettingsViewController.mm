#import "FocusFBSettingsViewController.h"
#import "FocusFBConfig.h"
#import "FocusFBPrefs.h"
#import "FocusFBTabManager.h"
#import "FocusFBLockManager.h"
#import "FocusFBAdBlocker.h"

typedef NS_ENUM(NSInteger, FFBSectionIndex) {
    FFBSectionMaster = 0,
    FFBSectionAdBlock,
    FFBSectionFoqosLock,
    FFBSectionPresets,
    FFBSectionTabs,
    FFBSectionShields,
    FFBSectionShortcuts,
    FFBSectionDiscovered,
    FFBSectionAbout,
    FFBSectionCount
};

@interface FFBSettingItem : NSObject
@property (nonatomic, copy) NSString *titleKey;
@property (nonatomic, copy, nullable) NSString *subtitleKey;
@property (nonatomic, copy, nullable) NSString *dynamicSubtitle;
@property (nonatomic, copy, nullable) NSString *valueBadgeText;
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, strong) UIColor *symbolColor;
@property (nonatomic, copy, nullable) BOOL (^getter)(FocusFBPrefs *prefs);
@property (nonatomic, copy, nullable) void (^setter)(FocusFBPrefs *prefs, BOOL value);
@property (nonatomic, copy, nullable) BOOL (^customBoolGetter)(void);
@property (nonatomic, copy, nullable) void (^customBoolSetter)(BOOL value);
@property (nonatomic, copy, nullable) void (^action)(FocusFBSettingsViewController *vc, UITableViewCell * _Nullable sourceCell);
@end

@implementation FFBSettingItem
@end

@interface FocusFBSettingsViewController () <UITableViewDataSource, UITableViewDelegate, UIAdaptivePresentationControllerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, assign) BOOL sessionUnlocked;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *masterItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *adBlockItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *foqosItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *presetItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *tabItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *shieldItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *shortcutItems;
@property (nonatomic, strong) NSArray<FocusFBDiscoveredTab *> *extraDiscoveredTabs;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *aboutItems;
@end

static BOOL gIsPresentingSettings = NO;
static CFTimeInterval gLastSettingsDismissTime = 0;

@implementation FocusFBSettingsViewController

+ (void)presentInternalPreUnlocked:(BOOL)preUnlocked {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!preUnlocked && [FocusFBLockManager shared].isTimeBlockedNow) {
            return;
        }
        if (!preUnlocked && (CACurrentMediaTime() - gLastSettingsDismissTime < 0.70)) {
            return;
        }
        if (gIsPresentingSettings) return;
        UIViewController *top = FocusFBTopMostViewController();
        if (!top || top.isBeingDismissed || top.isBeingPresented) return;
        if ([top isKindOfClass:FocusFBSettingsViewController.class] ||
            [top.navigationController.viewControllers.firstObject isKindOfClass:FocusFBSettingsViewController.class]) {
            if (preUnlocked) {
                FocusFBSettingsViewController *existing = [top isKindOfClass:FocusFBSettingsViewController.class]
                    ? (FocusFBSettingsViewController *)top
                    : (FocusFBSettingsViewController *)top.navigationController.viewControllers.firstObject;
                existing.sessionUnlocked = YES;
                [existing refreshAllDataAnimated];
            }
            return;
        }

        gIsPresentingSettings = YES;
        [FocusFBLockManager shared].pauseCountingForFocusFBUI = YES;

        FocusFBSettingsViewController *settingsVC = [[FocusFBSettingsViewController alloc] init];
        settingsVC.sessionUnlocked = preUnlocked;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settingsVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        nav.presentationController.delegate = settingsVC;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = nav.sheetPresentationController;
            if (sheet) {
                sheet.detents = @[[UISheetPresentationControllerDetent largeDetent]];
                sheet.prefersGrabberVisible = YES;
            }
        }
        [top presentViewController:nav animated:YES completion:^{
            gIsPresentingSettings = NO;
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            gIsPresentingSettings = NO;
        });
    });
}

+ (void)presentFromTopMostController {
    [self presentInternalPreUnlocked:NO];
}

+ (void)presentPreUnlockedFromTopController {
    [self presentInternalPreUnlocked:YES];
}

+ (void)presentWelcomeIfNeeded {
    dispatch_async(dispatch_get_main_queue(), ^{
        FocusFBPrefs *prefs = [FocusFBPrefs shared];
        if (prefs.hasSeenWelcome) return;

        UIViewController *top = FocusFBTopMostViewController();
        if (!top || [top isKindOfClass:UIAlertController.class] ||
            [top isKindOfClass:FocusFBSettingsViewController.class]) {
            return;
        }
        NSString *clsLower = NSStringFromClass(top.class).lowercaseString;
        if ([clsLower containsString:@"login"] || [clsLower containsString:@"auth"] ||
            [clsLower containsString:@"dbl"] || [clsLower containsString:@"checkpoint"]) {
            return;
        }

        prefs.hasSeenWelcome = YES;
        [prefs notifyChanges];

        UIAlertController *welcome = [UIAlertController alertControllerWithTitle:FFBLoc(@"Welcome.Title")
                                                                         message:FFBLoc(@"Welcome.Body")
                                                                  preferredStyle:UIAlertControllerStyleAlert];

        UIAlertAction *startAction = [UIAlertAction actionWithTitle:FFBLoc(@"Welcome.Start")
                                                              style:UIAlertActionStyleDefault
                                                            handler:^(__unused UIAlertAction *action) {
            FocusFBNavigateToMarketplace(YES);
        }];

        UIAlertAction *customizeAction = [UIAlertAction actionWithTitle:FFBLoc(@"Welcome.Customize")
                                                                  style:UIAlertActionStyleCancel
                                                                handler:^(__unused UIAlertAction *action) {
            [FocusFBSettingsViewController presentFromTopMostController];
        }];

        [welcome addAction:customizeAction];
        [welcome addAction:startAction];
        welcome.preferredAction = startAction;
        [top presentViewController:welcome animated:YES completion:nil];
    });
}

#pragma mark - Lock State Helper

- (BOOL)isEditingLocked {
    return ([FocusFBLockManager shared].strictLockActive && !self.sessionUnlocked);
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    [self rebuildDataModel];
    [self configureNavigationBar];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 62.0;
    self.tableView.tableHeaderView = [self buildHeaderView];
    [self.view addSubview:self.tableView];
}

- (void)dealloc {
    [FocusFBLockManager shared].pauseCountingForFocusFBUI = NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [FocusFBLockManager shared].pauseCountingForFocusFBUI = YES;
    [self refreshAllDataAnimated];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed || self.navigationController.isBeingDismissed) {
        self.sessionUnlocked = NO;
        gLastSettingsDismissTime = CACurrentMediaTime();
        [FocusFBLockManager shared].pauseCountingForFocusFBUI = NO;
    }
}

- (void)presentationControllerDidDismiss:(__unused UIPresentationController *)presentationController {
    self.sessionUnlocked = NO;
    gLastSettingsDismissTime = CACurrentMediaTime();
    [FocusFBLockManager shared].pauseCountingForFocusFBUI = NO;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    if (header) {
        CGSize fitting = [header systemLayoutSizeFittingSize:CGSizeMake(CGRectGetWidth(self.tableView.bounds), UILayoutFittingCompressedSize.height)
                               withHorizontalFittingPriority:UILayoutPriorityRequired
                                     verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
        if (fabs(CGRectGetHeight(header.frame) - fitting.height) > 1.0) {
            CGRect f = header.frame;
            f.size.height = fitting.height;
            header.frame = f;
            self.tableView.tableHeaderView = header;
        }
    }
}

- (void)configureNavigationBar {
    self.title = FFBLoc(@"AppTitle");

    NSString *langTitle = FFBIsItalianLocale() ? @"IT" : @"EN";
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:langTitle
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(toggleLanguageTapped)];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:FFBLoc(@"Close")
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(closeTapped)];
}

- (UIView *)buildHeaderView {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 360, 200)];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 8.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:36.0 weight:UIImageSymbolWeightBold];
    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"storefront.circle.fill" withConfiguration:cfg]];
    logo.tintColor = [UIColor systemBlueColor];
    [stack addArrangedSubview:logo];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = [NSString stringWithFormat:@"FocusFB %@", FOCUSFB_VERSION_STRING];
    titleLbl.font = [UIFont systemFontOfSize:19.0 weight:UIFontWeightBold];
    titleLbl.textColor = [UIColor labelColor];
    [stack addArrangedSubview:titleLbl];

    UILabel *subLbl = [[UILabel alloc] init];
    subLbl.text = FFBLoc(@"Subtitle");
    subLbl.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subLbl.textColor = [UIColor secondaryLabelColor];
    subLbl.textAlignment = NSTextAlignmentCenter;
    subLbl.numberOfLines = 0;
    [stack addArrangedSubview:subLbl];

    UIButton *goBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    goBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [goBtn setImage:[UIImage systemImageNamed:@"storefront.fill"] forState:UIControlStateNormal];
    [goBtn setTitle:[NSString stringWithFormat:@"  %@", FFBLoc(@"OpenMarketplaceNow")] forState:UIControlStateNormal];
    goBtn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    goBtn.backgroundColor = [UIColor systemBlueColor];
    [goBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    goBtn.tintColor = [UIColor whiteColor];
    goBtn.layer.cornerRadius = 12.0;
    [NSLayoutConstraint activateConstraints:@[
        [goBtn.heightAnchor constraintEqualToConstant:38.0],
        [goBtn.widthAnchor constraintGreaterThanOrEqualToConstant:200.0]
    ]];
    [goBtn addTarget:self action:@selector(openMarketplaceFromHeader) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:goBtn];

    // Card stato blocco Foqos
    FocusFBLockManager *lockMgr = [FocusFBLockManager shared];
    if (lockMgr.strictLockActive) {
        BOOL locked = [self isEditingLocked];
        UIView *banner = [[UIView alloc] init];
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        banner.layer.cornerRadius = 16.0;
        banner.backgroundColor = locked
            ? [UIColor colorWithRed:0.86 green:0.20 blue:0.18 alpha:0.11]
            : [UIColor colorWithRed:0.16 green:0.72 blue:0.36 alpha:0.12];
        banner.layer.borderWidth = 1.0;
        banner.layer.borderColor = locked
            ? [UIColor colorWithRed:0.86 green:0.20 blue:0.18 alpha:0.35].CGColor
            : [UIColor colorWithRed:0.16 green:0.72 blue:0.36 alpha:0.35].CGColor;

        UIStackView *bStack = [[UIStackView alloc] init];
        bStack.axis = UILayoutConstraintAxisVertical;
        bStack.spacing = 7.0;
        bStack.alignment = UIStackViewAlignmentCenter;
        bStack.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:bStack];

        UIStackView *titleRow = [[UIStackView alloc] init];
        titleRow.axis = UILayoutConstraintAxisHorizontal;
        titleRow.spacing = 6.0;
        titleRow.alignment = UIStackViewAlignmentCenter;

        UIImageView *lockIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:(locked ? @"lock.fill" : @"lock.open.fill")]];
        lockIcon.tintColor = locked ? [UIColor systemRedColor] : [UIColor systemGreenColor];

        UILabel *bTitle = [[UILabel alloc] init];
        bTitle.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightBold];
        bTitle.textColor = locked ? [UIColor systemRedColor] : [UIColor systemGreenColor];
        bTitle.text = locked ? FFBLoc(@"Lock.BannerLockedTitle") : FFBLoc(@"Lock.BannerUnlockedTitle");

        [titleRow addArrangedSubview:lockIcon];
        [titleRow addArrangedSubview:bTitle];
        [bStack addArrangedSubview:titleRow];

        UILabel *bQuota = [[UILabel alloc] init];
        bQuota.font = [UIFont monospacedDigitSystemFontOfSize:12.5 weight:UIFontWeightSemibold];
        bQuota.textColor = [UIColor labelColor];
        bQuota.textAlignment = NSTextAlignmentCenter;
        bQuota.text = [NSString stringWithFormat:@"%@  •  %@",
                       [lockMgr formattedRemainingSummary], [lockMgr registeredKeyDescription]];
        bQuota.numberOfLines = 0;
        [bStack addArrangedSubview:bQuota];

        UILabel *bSub = [[UILabel alloc] init];
        bSub.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        bSub.textColor = [UIColor secondaryLabelColor];
        bSub.textAlignment = NSTextAlignmentCenter;
        bSub.numberOfLines = 0;
        bSub.text = locked ? FFBLoc(@"Lock.BannerLockedSub") : FFBLoc(@"Lock.BannerUnlockedSub");
        [bStack addArrangedSubview:bSub];

        if (locked) {
            UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            NSString *sf = (lockMgr.keyType == FFBPhysicalKeyTypeNFCTag) ? @"wave.3.right.circle.fill" : @"qrcode.viewfinder";
            [scanBtn setImage:[UIImage systemImageNamed:sf] forState:UIControlStateNormal];
            [scanBtn setTitle:[NSString stringWithFormat:@"  %@", FFBLoc(@"Lock.ScanToEditBtn")] forState:UIControlStateNormal];
            scanBtn.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBold];
            scanBtn.backgroundColor = [UIColor systemRedColor];
            [scanBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            scanBtn.tintColor = [UIColor whiteColor];
            scanBtn.layer.cornerRadius = 11.0;
            scanBtn.contentEdgeInsets = UIEdgeInsetsMake(10, 16, 10, 16);
            [scanBtn addTarget:self action:@selector(scanToUnlockEditingTapped) forControlEvents:UIControlEventTouchUpInside];
            [bStack addArrangedSubview:scanBtn];
            [scanBtn.widthAnchor constraintEqualToAnchor:bStack.widthAnchor].active = YES;

            if (lockMgr.emergencyUnlockEnabled) {
                NSInteger rem = lockMgr.emergencyUnlocksRemainingThisMonth;
                NSInteger lim = lockMgr.monthlyEmergencyUnlockLimit;
                UIButton *emergBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                [emergBtn setImage:[UIImage systemImageNamed:@"exclamationmark.shield"] forState:UIControlStateNormal];
                emergBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
                emergBtn.layer.cornerRadius = 10.0;
                emergBtn.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
                if (rem > 0) {
                    NSString *t = [NSString stringWithFormat:FFBLoc(@"Lock.EmergencyBtnFmt"), (long)rem, (long)lim];
                    [emergBtn setTitle:[NSString stringWithFormat:@"  %@", t] forState:UIControlStateNormal];
                    emergBtn.tintColor = [UIColor systemOrangeColor];
                    [emergBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
                    emergBtn.backgroundColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.12 alpha:0.13];
                    [emergBtn addTarget:self action:@selector(emergencyUnlockFromBannerTapped) forControlEvents:UIControlEventTouchUpInside];
                } else {
                    NSString *t = [NSString stringWithFormat:FFBLoc(@"Lock.EmergencyExhaustedFmt"), (long)lim];
                    [emergBtn setTitle:[NSString stringWithFormat:@"  %@", t] forState:UIControlStateDisabled];
                    emergBtn.enabled = NO;
                    emergBtn.tintColor = [UIColor secondaryLabelColor];
                    [emergBtn setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateDisabled];
                }
                [bStack addArrangedSubview:emergBtn];
                [emergBtn.widthAnchor constraintEqualToAnchor:bStack.widthAnchor].active = YES;
            }
        }

        [stack setCustomSpacing:12.0 afterView:goBtn];
        [stack addArrangedSubview:banner];

        [NSLayoutConstraint activateConstraints:@[
            [banner.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [bStack.topAnchor constraintEqualToAnchor:banner.topAnchor constant:12.0],
            [bStack.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-12.0],
            [bStack.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:12.0],
            [bStack.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
        ]];
    }

    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:14.0],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10.0],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:18.0],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-18.0]
    ]];

    return container;
}

#pragma mark - Data Model Builder

static FFBSettingItem *FFBBoolItem(NSString *titleKey,
                                   NSString *subtitleKey,
                                   NSString *symbol,
                                   UIColor *color,
                                   BOOL (^getter)(FocusFBPrefs *),
                                   void (^setter)(FocusFBPrefs *, BOOL)) {
    FFBSettingItem *item = [[FFBSettingItem alloc] init];
    item.titleKey = titleKey;
    item.subtitleKey = subtitleKey;
    item.symbolName = symbol;
    item.symbolColor = color;
    item.getter = getter;
    item.setter = setter;
    return item;
}

static FFBSettingItem *FFBActionItem(NSString *titleKey,
                                     NSString *subtitleKey,
                                     NSString *symbol,
                                     UIColor *color,
                                     void (^action)(FocusFBSettingsViewController *, UITableViewCell * _Nullable)) {
    FFBSettingItem *item = [[FFBSettingItem alloc] init];
    item.titleKey = titleKey;
    item.subtitleKey = subtitleKey;
    item.symbolName = symbol;
    item.symbolColor = color;
    item.action = action;
    return item;
}

static NSString *FFBFormatMinutesBadge(NSInteger mins) {
    if (mins == -1) return FFBLoc(@"Lock.AlwaysBlockedBadge");
    if (mins <= 0) return FFBLoc(@"Lock.Off");
    if (mins >= 60 && (mins % 60 == 0)) {
        NSInteger hrs = mins / 60;
        return [NSString stringWithFormat:@"%ld h", (long)hrs];
    }
    return [NSString stringWithFormat:@"%ld min", (long)mins];
}

- (void)rebuildDataModel {
    // Mostra solo eventuali schede sconosciute extra aggiunte da Facebook (nascondendo quelle standard già presenti sopra)
    NSMutableArray<FocusFBDiscoveredTab *> *extras = [NSMutableArray array];
    for (FocusFBDiscoveredTab *t in [[FocusFBPrefs shared] discoveredTabs]) {
        if (t.tabType == FocusFBTabUnknown) {
            [extras addObject:t];
        }
    }
    self.extraDiscoveredTabs = [extras copy];

    FocusFBLockManager *lockMgr = [FocusFBLockManager shared];

    self.masterItems = @[
        FFBBoolItem(@"Master.Enable", @"Master.EnableDesc", @"power.circle.fill", [UIColor systemGreenColor],
                    ^BOOL(FocusFBPrefs *p) { return p.enabled; },
                    ^(FocusFBPrefs *p, BOOL v) { p.enabled = v; })
    ];

    // ── Pubblicità ──
    FFBSettingItem *adBlockItem = FFBBoolItem(@"AdBlock.EnableAll", @"AdBlock.EnableAllDesc", @"shield.lefthalf.filled", [UIColor systemGreenColor],
                                              ^BOOL(FocusFBPrefs *p) { return p.blockAllAds; },
                                              ^(FocusFBPrefs *p, BOOL v) { p.blockAllAds = v; });
    NSUInteger blockedNow = FocusFBBlockedAdsCount();
    if (blockedNow > 0) {
        adBlockItem.dynamicSubtitle = [NSString stringWithFormat:@"%@ (%lu %@)",
                                       FFBLoc(@"AdBlock.EnableAllDesc"),
                                       (unsigned long)blockedNow,
                                       FFBIsItalianLocale() ? @"bloccate" : @"blocked"];
    }

    FFBSettingItem *suggestedItem = FFBBoolItem(@"AdBlock.HideSuggested", @"AdBlock.HideSuggestedDesc", @"rectangle.on.rectangle.slash", [UIColor systemMintColor],
                                                ^BOOL(FocusFBPrefs *p) { return p.hideSuggestedClutter; },
                                                ^(FocusFBPrefs *p, BOOL v) { p.hideSuggestedClutter = v; });

    self.adBlockItems = @[ adBlockItem, suggestedItem ];

    // ── Blocco con chiave fisica (Foqos) ──
    FFBSettingItem *keyStatus = [[FFBSettingItem alloc] init];
    keyStatus.titleKey = @"Lock.KeyStatusRow";
    keyStatus.dynamicSubtitle = [NSString stringWithFormat:@"%@  •  %@",
                                 [lockMgr registeredKeyDescription],
                                 [lockMgr formattedRemainingSummary]];
    keyStatus.symbolName = lockMgr.hasRegisteredKey ? @"key.fill" : @"key.slash.fill";
    keyStatus.symbolColor = lockMgr.hasRegisteredKey ? [UIColor systemGreenColor] : [UIColor systemGrayColor];

    FFBSettingItem *regCamera = FFBActionItem(@"Lock.RegisterQRBarcode", @"Lock.RegisterQRBarcodeDesc",
                                              @"qrcode.viewfinder", [UIColor systemBlueColor],
                                              ^(FocusFBSettingsViewController *vc, __unused UITableViewCell *cell) {
        [[FocusFBLockManager shared] presentRegisterBarcodeOrQRFrom:vc completion:^(__unused BOOL ok) {
            [vc refreshAllDataAnimated];
        }];
    });

    FFBSettingItem *genQR = FFBActionItem(@"Lock.GenerateSecretQR", @"Lock.GenerateSecretQRDesc",
                                          @"printer.fill", [UIColor systemIndigoColor],
                                          ^(FocusFBSettingsViewController *vc, __unused UITableViewCell *cell) {
        [[FocusFBLockManager shared] presentGenerateSecretQRFrom:vc completion:^(__unused BOOL ok) {
            [vc refreshAllDataAnimated];
        }];
    });

    FFBSettingItem *regNFC = FFBActionItem(@"Lock.RegisterNFC", @"Lock.RegisterNFCDesc",
                                           @"wave.3.right.circle.fill", [UIColor systemTealColor],
                                           ^(FocusFBSettingsViewController *vc, __unused UITableViewCell *cell) {
        [[FocusFBLockManager shared] presentRegisterNFCTagFrom:vc completion:^(__unused BOOL ok) {
            [vc refreshAllDataAnimated];
        }];
    });

    BOOL isExceptMP = (lockMgr.lockScope == FFBLockScopeExceptMarketplace);
    FFBSettingItem *scopeItem = FFBActionItem(@"Lock.ScopeRow",
                                              isExceptMP ? @"Lock.ScopeExceptMPDesc" : @"Lock.ScopeEntireAppDesc",
                                              isExceptMP ? @"bag.fill" : @"iphone",
                                              isExceptMP ? [UIColor systemGreenColor] : [UIColor systemOrangeColor],
                                              ^(FocusFBSettingsViewController *vc, UITableViewCell *cell) {
        [vc promptLockScopePickerFromCell:cell];
    });
    scopeItem.valueBadgeText = isExceptMP ? FFBLoc(@"Lock.ScopeExceptMPBadge") : FFBLoc(@"Lock.ScopeEntireAppBadge");

    FFBSettingItem *sessionLim = FFBActionItem(@"Lock.SessionLimit", @"Lock.SessionLimitDesc",
                                               @"timer", [UIColor systemOrangeColor],
                                               ^(FocusFBSettingsViewController *vc, UITableViewCell *cell) {
        [vc promptMinutesPickerWithTitle:FFBLoc(@"Lock.SessionLimit")
                                 options:@[@0, @(-1), @2, @5, @10, @15, @20, @30, @45, @60]
                              sourceCell:cell
                                onSelect:^(NSInteger mins) {
            [FocusFBLockManager shared].sessionLimitMinutes = mins;
            [vc refreshAllDataAnimated];
        }];
    });
    sessionLim.valueBadgeText = FFBFormatMinutesBadge(lockMgr.sessionLimitMinutes);

    FFBSettingItem *cooldownLim = FFBActionItem(@"Lock.Cooldown", @"Lock.CooldownDesc",
                                                @"hourglass", [UIColor systemPurpleColor],
                                                ^(FocusFBSettingsViewController *vc, UITableViewCell *cell) {
        [vc promptMinutesPickerWithTitle:FFBLoc(@"Lock.Cooldown")
                                 options:@[@5, @15, @30, @60, @120, @240]
                              sourceCell:cell
                                onSelect:^(NSInteger mins) {
            [FocusFBLockManager shared].cooldownMinutes = mins;
            [vc refreshAllDataAnimated];
        }];
    });
    cooldownLim.valueBadgeText = FFBFormatMinutesBadge(lockMgr.cooldownMinutes);

    FFBSettingItem *dailyLim = FFBActionItem(@"Lock.DailyLimit", @"Lock.DailyLimitDesc",
                                             @"calendar.badge.clock", [UIColor systemRedColor],
                                             ^(FocusFBSettingsViewController *vc, UITableViewCell *cell) {
        [vc promptMinutesPickerWithTitle:FFBLoc(@"Lock.DailyLimit")
                                 options:@[@0, @5, @10, @15, @20, @30, @45, @60, @90, @120]
                              sourceCell:cell
                                onSelect:^(NSInteger mins) {
            [FocusFBLockManager shared].dailyLimitMinutes = mins;
            [vc refreshAllDataAnimated];
        }];
    });
    dailyLim.valueBadgeText = FFBFormatMinutesBadge(lockMgr.dailyLimitMinutes);

    FFBSettingItem *pillToggle = [[FFBSettingItem alloc] init];
    pillToggle.titleKey = @"Lock.ShowTimerPill";
    pillToggle.subtitleKey = @"Lock.ShowTimerPillDesc";
    pillToggle.symbolName = @"clock.badge";
    pillToggle.symbolColor = [UIColor systemCyanColor];
    pillToggle.customBoolGetter = ^BOOL { return [FocusFBLockManager shared].showRemainingTimerPill; };
    pillToggle.customBoolSetter = ^(BOOL v) { [FocusFBLockManager shared].showRemainingTimerPill = v; };

    FFBSettingItem *emergencyToggle = [[FFBSettingItem alloc] init];
    emergencyToggle.titleKey = @"Lock.EmergencyRow";
    emergencyToggle.dynamicSubtitle = [NSString stringWithFormat:FFBLoc(@"Lock.EmergencyDescFmt"),
                                       (long)lockMgr.emergencyUnlocksRemainingThisMonth,
                                       (long)lockMgr.monthlyEmergencyUnlockLimit];
    emergencyToggle.symbolName = @"exclamationmark.shield.fill";
    emergencyToggle.symbolColor = [UIColor systemOrangeColor];
    emergencyToggle.customBoolGetter = ^BOOL { return [FocusFBLockManager shared].emergencyUnlockEnabled; };
    __weak FocusFBSettingsViewController *weakSelf = self;
    emergencyToggle.customBoolSetter = ^(BOOL v) {
        if (v) {
            [FocusFBLockManager shared].emergencyUnlockEnabled = YES;
            [weakSelf refreshAllDataAnimated];
        } else {
            [weakSelf confirmDisableEmergencyUnlock];
        }
    };

    FFBSettingItem *resetTimersItem = FFBActionItem(@"Lock.ResetTimersRow", @"Lock.ResetTimersDesc",
                                                    @"arrow.counterclockwise", [UIColor systemMintColor],
                                                    ^(FocusFBSettingsViewController *vc, __unused UITableViewCell *cell) {
        [[FocusFBLockManager shared] resetTodayUsageAndCooldown];
        [vc refreshAllDataAnimated];
        FocusFBShowToast(FFBLoc(@"Lock.TimersResetToast"), @"checkmark.circle.fill");
    });

    FFBSettingItem *strictBtn = FFBActionItem(
        lockMgr.strictLockActive ? @"Lock.StrictToggleOff" : @"Lock.StrictToggleOn",
        lockMgr.strictLockActive ? @"Lock.StrictToggleOffDesc" : @"Lock.StrictToggleOnDesc",
        lockMgr.strictLockActive ? @"lock.open.fill" : @"lock.fill",
        lockMgr.strictLockActive ? [UIColor systemGreenColor] : [UIColor systemRedColor],
        ^(FocusFBSettingsViewController *vc, __unused UITableViewCell *cell) {
            [vc toggleStrictLockTapped];
        }
    );

    self.foqosItems = @[
        keyStatus, regCamera, genQR, regNFC,
        scopeItem, sessionLim, cooldownLim, dailyLim,
        pillToggle, emergencyToggle, resetTimersItem, strictBtn
    ];

    // ── Configurazioni rapide ──
    self.presetItems = @[
        FFBActionItem(@"Preset.MarketplaceOnly", @"Preset.MarketplaceOnlyDesc", @"scope", [UIColor systemBlueColor],
                      ^(FocusFBSettingsViewController *vc, __unused UITableViewCell *c) {
            [[FocusFBPrefs shared] applyMarketplaceOnlyPreset];
            [vc refreshAllDataAnimated];
            FocusFBShowToast(FFBLoc(@"Preset.AppliedToast"), @"storefront.fill");
        }),
        FFBActionItem(@"Preset.SellerMode", @"Preset.SellerModeDesc", @"bag.badge.plus", [UIColor systemIndigoColor],
                      ^(FocusFBSettingsViewController *vc, __unused UITableViewCell *c) {
            [[FocusFBPrefs shared] applyMarketplaceAndSellerToolsPreset];
            [vc refreshAllDataAnimated];
            FocusFBShowToast(FFBLoc(@"Preset.AppliedToast"), @"bell.badge.fill");
        }),
        FFBActionItem(@"Preset.ShowAll", @"Preset.ShowAllDesc", @"square.grid.2x2.fill", [UIColor systemGrayColor],
                      ^(FocusFBSettingsViewController *vc, __unused UITableViewCell *c) {
            [[FocusFBPrefs shared] applyShowAllTabsPreset];
            [vc refreshAllDataAnimated];
            FocusFBShowToast(FFBLoc(@"Preset.AppliedToast"), @"checkmark.circle.fill");
        })
    ];

    // ── Schede visibili ──
    self.tabItems = @[
        FFBBoolItem(@"Tab.Marketplace", @"Tab.MarketplaceDesc", @"storefront.fill", [UIColor systemBlueColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showMarketplaceTab; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showMarketplaceTab = v; }),
        FFBBoolItem(@"Tab.Home", @"Tab.HomeDesc", @"house.fill", [UIColor systemOrangeColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showHomeTab; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showHomeTab = v; }),
        FFBBoolItem(@"Tab.Reels", @"Tab.ReelsDesc", @"play.rectangle.on.rectangle.fill", [UIColor systemPinkColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showReelsTab; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showReelsTab = v; }),
        FFBBoolItem(@"Tab.Friends", @"Tab.FriendsDesc", @"person.2.fill", [UIColor systemTealColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showFriendsTab; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showFriendsTab = v; }),
        FFBBoolItem(@"Tab.Groups", @"Tab.GroupsDesc", @"person.3.fill", [UIColor systemCyanColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showGroupsTab; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showGroupsTab = v; }),
        FFBBoolItem(@"Tab.Notifications", @"Tab.NotificationsDesc", @"bell.fill", [UIColor systemRedColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showNotificationsTab; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showNotificationsTab = v; }),
        FFBBoolItem(@"Tab.Profile", @"Tab.ProfileDesc", @"person.crop.circle.fill", [UIColor systemPurpleColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showProfileTab; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showProfileTab = v; }),
        FFBBoolItem(@"Tab.Menu", @"Tab.MenuDesc", @"line.3.horizontal", [UIColor systemGrayColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showMenuTab; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showMenuTab = v; }),
        FFBBoolItem(@"Tab.HideUnknown", @"Tab.HideUnknownDesc", @"eye.slash", [UIColor systemBrownColor],
                    ^BOOL(FocusFBPrefs *p) { return p.hideUnknownTabs; },
                    ^(FocusFBPrefs *p, BOOL v) { p.hideUnknownTabs = v; })
    ];

    // ── Aspetto e filtri ──
    self.shieldItems = @[
        FFBBoolItem(@"Shield.StartMarketplace", @"Shield.StartMarketplaceDesc", @"arrow.right.circle.fill", [UIColor systemBlueColor],
                    ^BOOL(FocusFBPrefs *p) { return p.startOnMarketplace; },
                    ^(FocusFBPrefs *p, BOOL v) { p.startOnMarketplace = v; }),
        FFBBoolItem(@"Shield.HideSingleBar", @"Shield.HideSingleBarDesc", @"dock.arrow.down.rectangle", [UIColor systemPurpleColor],
                    ^BOOL(FocusFBPrefs *p) { return p.hideSingleTabBar; },
                    ^(FocusFBPrefs *p, BOOL v) { p.hideSingleTabBar = v; }),
        FFBBoolItem(@"Shield.ReflowTabs", @"Shield.ReflowTabsDesc", @"align.horizontal.center.fill", [UIColor systemTealColor],
                    ^BOOL(FocusFBPrefs *p) { return p.reflowVisibleTabs; },
                    ^(FocusFBPrefs *p, BOOL v) { p.reflowVisibleTabs = v; }),
        FFBBoolItem(@"Shield.HomeFeed", @"Shield.HomeFeedDesc", @"rectangle.portrait.slash", [UIColor systemIndigoColor],
                    ^BOOL(FocusFBPrefs *p) { return p.shieldHomeFeed; },
                    ^(FocusFBPrefs *p, BOOL v) { p.shieldHomeFeed = v; }),
        FFBBoolItem(@"Shield.BlockReels", @"Shield.BlockReelsDesc", @"hand.raised.fill", [UIColor systemRedColor],
                    ^BOOL(FocusFBPrefs *p) { return p.blockReelsEverywhere; },
                    ^(FocusFBPrefs *p, BOOL v) { p.blockReelsEverywhere = v; }),
        FFBBoolItem(@"Shield.HideStories", @"Shield.HideStoriesDesc", @"rectangle.slash.fill", [UIColor systemOrangeColor],
                    ^BOOL(FocusFBPrefs *p) { return p.hideStoriesAndInlineReels; },
                    ^(FocusFBPrefs *p, BOOL v) { p.hideStoriesAndInlineReels = v; })
    ];

    // ── Accesso impostazioni ──
    self.shortcutItems = @[
        FFBBoolItem(@"Short.TwoFinger", @"Short.TwoFingerDesc", @"hand.tap.fill", [UIColor systemBlueColor],
                    ^BOOL(FocusFBPrefs *p) { return p.twoFingerLongPressEnabled; },
                    ^(FocusFBPrefs *p, BOOL v) { p.twoFingerLongPressEnabled = v; }),
        FFBBoolItem(@"Short.FloatingGear", @"Short.FloatingGearDesc", @"gearshape.circle.fill", [UIColor systemGrayColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showFloatingGearButton; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showFloatingGearButton = v; })
    ];

    // ── Info e supporto ──
    NSMutableArray<FFBSettingItem *> *about = [NSMutableArray array];
    NSString *paypalURL = FOCUSFB_PAYPAL_URL;
    if (paypalURL.length > 0) {
        [about addObject:FFBActionItem(@"About.Donate", @"About.DonateDesc", @"heart.fill", [UIColor systemPinkColor],
                                       ^(__unused FocusFBSettingsViewController *vc, __unused UITableViewCell *c) {
            NSURL *url = [NSURL URLWithString:paypalURL];
            if (url) {
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            }
        })];
    }
    NSString *ghURL = FOCUSFB_GITHUB_URL;
    if (ghURL.length > 0) {
        [about addObject:FFBActionItem(@"About.GitHub", @"About.GitHubDesc", @"chevron.left.forwardslash.chevron.right", [UIColor labelColor],
                                       ^(__unused FocusFBSettingsViewController *vc, __unused UITableViewCell *c) {
            NSURL *url = [NSURL URLWithString:ghURL];
            if (url) {
                [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            }
        })];
    }
    self.aboutItems = [about copy];
}

- (void)refreshAllDataAnimated {
    [self rebuildDataModel];
    [self configureNavigationBar];
    self.tableView.tableHeaderView = [self buildHeaderView];
    [self.tableView reloadData];
}

#pragma mark - Actions

- (void)closeTapped {
    self.sessionUnlocked = NO;
    gLastSettingsDismissTime = CACurrentMediaTime();
    [FocusFBLockManager shared].pauseCountingForFocusFBUI = NO;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)openMarketplaceFromHeader {
    self.sessionUnlocked = NO;
    gLastSettingsDismissTime = CACurrentMediaTime();
    [FocusFBLockManager shared].pauseCountingForFocusFBUI = NO;
    [self dismissViewControllerAnimated:YES completion:^{
        FocusFBNavigateToMarketplace(YES);
    }];
}

- (void)toggleLanguageTapped {
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    prefs.languageCode = FFBIsItalianLocale() ? @"en" : @"it";
    [prefs notifyChanges];
    [self refreshAllDataAnimated];
}

- (void)scanToUnlockEditingTapped {
    __weak FocusFBSettingsViewController *weakSelf = self;
    [[FocusFBLockManager shared] presentVerifyPhysicalKeyFrom:self
                                                       reason:FFBLoc(@"Lock.ScanUnlockPrompt")
                                                   completion:^(BOOL verified) {
        if (!verified) return;
        FocusFBSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.sessionUnlocked = YES;
        [strongSelf refreshAllDataAnimated];
    }];
}

- (void)emergencyUnlockFromBannerTapped {
    __weak FocusFBSettingsViewController *weakSelf = self;
    [[FocusFBLockManager shared] presentEmergencyUnlockPromptFrom:self onUnlocked:^{
        FocusFBSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.sessionUnlocked = NO;
        [strongSelf refreshAllDataAnimated];
    }];
}

- (void)confirmDisableEmergencyUnlock {
    UIAlertController *warn = [UIAlertController alertControllerWithTitle:FFBLoc(@"Lock.EmergencyDisableWarnTitle")
                                                                  message:FFBLoc(@"Lock.EmergencyDisableWarnBody")
                                                           preferredStyle:UIAlertControllerStyleAlert];
    __weak FocusFBSettingsViewController *weakSelf = self;
    [warn addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:^(__unused UIAlertAction *a) {
        [weakSelf refreshAllDataAnimated];
    }]];
    [warn addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Lock.EmergencyDisableConfirm")
                                             style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *a) {
        [FocusFBLockManager shared].emergencyUnlockEnabled = NO;
        [weakSelf refreshAllDataAnimated];
    }]];
    [self presentViewController:warn animated:YES completion:nil];
}

- (void)toggleStrictLockTapped {
    FocusFBLockManager *mgr = [FocusFBLockManager shared];
    if (mgr.strictLockActive) {
        [mgr disableStrictLockAfterVerifiedScan];
        self.sessionUnlocked = NO;
        [self refreshAllDataAnimated];
        return;
    }

    if (!mgr.hasRegisteredKey) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:FFBLoc(@"Lock.NeedKeyAlertTitle")
                                                                       message:FFBLoc(@"Lock.NeedKeyAlertBody")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *scopeName = (mgr.lockScope == FFBLockScopeExceptMarketplace)
        ? FFBLoc(@"Lock.ScopeExceptMPTitle")
        : FFBLoc(@"Lock.ScopeEntireAppTitle");

    NSString *msg = FFBIsItalianLocale()
        ? [NSString stringWithFormat:@"Ambito: %@\nChiave: %@\nSessione: %@ • Pausa: %@ • Giorno: %@",
           scopeName,
           [mgr registeredKeyDescription],
           FFBFormatMinutesBadge(mgr.sessionLimitMinutes),
           FFBFormatMinutesBadge(mgr.cooldownMinutes),
           FFBFormatMinutesBadge(mgr.dailyLimitMinutes)]
        : [NSString stringWithFormat:@"Scope: %@\nKey: %@\nSession: %@ • Break: %@ • Daily: %@",
           scopeName,
           [mgr registeredKeyDescription],
           FFBFormatMinutesBadge(mgr.sessionLimitMinutes),
           FFBFormatMinutesBadge(mgr.cooldownMinutes),
           FFBFormatMinutesBadge(mgr.dailyLimitMinutes)];

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:FFBLoc(@"Lock.StrictToggleOn")
                                                                     message:msg
                                                              preferredStyle:UIAlertControllerStyleAlert];
    __weak FocusFBSettingsViewController *weakSelf = self;
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    BOOL allExtraTabsHidden = (!prefs.showHomeTab && !prefs.showGroupsTab && !prefs.showNotificationsTab && !prefs.showFriendsTab && !prefs.showProfileTab);
    BOOL hasAllowanceForExtra = (mgr.lockScope == FFBLockScopeExceptMarketplace && (mgr.sessionLimitMinutes > 0 || mgr.dailyLimitMinutes > 0));

    if (hasAllowanceForExtra && allExtraTabsHidden) {
        NSString *enableAndLockTitle = FFBIsItalianLocale()
            ? @"Attiva e mostra schede nei minuti concessi"
            : @"Enable and show tabs during allowed time";
        [confirm addAction:[UIAlertAction actionWithTitle:enableAndLockTitle style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            FocusFBSettingsViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            FocusFBPrefs *p = [FocusFBPrefs shared];
            p.showMarketplaceTab = YES;
            p.showHomeTab = YES;
            p.showGroupsTab = YES;
            p.showNotificationsTab = YES;
            p.showMenuTab = YES;
            NSString *err = nil;
            if ([[FocusFBLockManager shared] enableStrictLockError:&err]) {
                strongSelf.sessionUnlocked = NO;
                [strongSelf refreshAllDataAnimated];
                [strongSelf.tableView setContentOffset:CGPointZero animated:YES];
            }
        }]];

        NSString *keepCurrentTitle = FFBIsItalianLocale()
            ? @"Attiva mantenendo solo le schede attuali"
            : @"Enable keeping current tabs only";
        [confirm addAction:[UIAlertAction actionWithTitle:keepCurrentTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            FocusFBSettingsViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *err = nil;
            if ([[FocusFBLockManager shared] enableStrictLockError:&err]) {
                strongSelf.sessionUnlocked = NO;
                [strongSelf refreshAllDataAnimated];
                [strongSelf.tableView setContentOffset:CGPointZero animated:YES];
            }
        }]];
    } else {
        [confirm addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Lock.StrictToggleOn")
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(__unused UIAlertAction *a) {
            FocusFBSettingsViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *err = nil;
            if ([[FocusFBLockManager shared] enableStrictLockError:&err]) {
                strongSelf.sessionUnlocked = NO;
                [strongSelf refreshAllDataAnimated];
                [strongSelf.tableView setContentOffset:CGPointZero animated:YES];
            }
        }]];
    }
    [confirm addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)promptLockScopePickerFromCell:(nullable UITableViewCell *)sourceCell {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:FFBLoc(@"Lock.ScopeRow")
                                                                   message:FFBLoc(@"Lock.ScopeExceptMPDesc")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak FocusFBSettingsViewController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Lock.ScopeExceptMPTitle")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [FocusFBLockManager shared].lockScope = FFBLockScopeExceptMarketplace;
        [weakSelf refreshAllDataAnimated];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Lock.ScopeEntireAppTitle")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [FocusFBLockManager shared].lockScope = FFBLockScopeEntireApp;
        [weakSelf refreshAllDataAnimated];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = sourceCell ?: self.view;
        sheet.popoverPresentationController.sourceRect = sourceCell ? sourceCell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)promptMinutesPickerWithTitle:(NSString *)title
                             options:(NSArray<NSNumber *> *)options
                          sourceCell:(nullable UITableViewCell *)sourceCell
                            onSelect:(void (^)(NSInteger mins))onSelect {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *num in options) {
        NSInteger m = num.integerValue;
        NSString *label = (m == -1) ? FFBLoc(@"Lock.AlwaysBlockedOption") : FFBFormatMinutesBadge(m);
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *a) {
            if (onSelect) onSelect(m);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = sourceCell ?: self.view;
        sheet.popoverPresentationController.sourceRect = sourceCell ? sourceCell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)notifyEditingBlocked {
    UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
    [gen notificationOccurred:UINotificationFeedbackTypeWarning];
    FocusFBShowToast(FFBLoc(@"Lock.LockedToast"), @"lock.fill");
    [self.tableView setContentOffset:CGPointZero animated:YES];
}

- (void)switchValueChanged:(UISwitch *)sender {
    if ([self isEditingLocked]) {
        BOOL cur = !sender.isOn;
        [sender setOn:cur animated:YES];
        [self notifyEditingBlocked];
        return;
    }

    NSInteger section = sender.tag >> 16;
    NSInteger row = sender.tag & 0xFFFF;
    NSArray<FFBSettingItem *> *list = [self itemsForStandardSection:section];
    if (row < 0 || (NSUInteger)row >= list.count) return;

    FFBSettingItem *item = list[(NSUInteger)row];
    if (item.customBoolSetter) {
        item.customBoolSetter(sender.isOn);
    } else if (item.setter) {
        FocusFBPrefs *prefs = [FocusFBPrefs shared];
        item.setter(prefs, sender.isOn);
        [prefs notifyChanges];
    }
    if (section == FFBSectionMaster) {
        self.tableView.tableHeaderView = [self buildHeaderView];
    }
}

#pragma mark - TableView Helpers

- (NSArray<FFBSettingItem *> *)itemsForStandardSection:(NSInteger)section {
    switch (section) {
        case FFBSectionMaster:    return self.masterItems;
        case FFBSectionAdBlock:   return self.adBlockItems;
        case FFBSectionFoqosLock: return self.foqosItems;
        case FFBSectionPresets:   return self.presetItems;
        case FFBSectionTabs:      return self.tabItems;
        case FFBSectionShields:   return self.shieldItems;
        case FFBSectionShortcuts: return self.shortcutItems;
        case FFBSectionAbout:     return self.aboutItems;
        default:                  return @[];
    }
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return FFBSectionCount;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == FFBSectionDiscovered) {
        return (NSInteger)self.extraDiscoveredTabs.count;
    }
    return (NSInteger)[self itemsForStandardSection:section].count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == FFBSectionDiscovered && self.extraDiscoveredTabs.count == 0) {
        return nil;
    }
    if (section == FFBSectionAbout && self.aboutItems.count == 0) {
        return nil;
    }
    switch (section) {
        case FFBSectionMaster:     return FFBLoc(@"Sec.Master");
        case FFBSectionAdBlock:    return FFBLoc(@"Sec.AdBlock");
        case FFBSectionFoqosLock:  return FFBLoc(@"Sec.FoqosLock");
        case FFBSectionPresets:    return FFBLoc(@"Sec.Presets");
        case FFBSectionTabs:       return FFBLoc(@"Sec.Tabs");
        case FFBSectionShields:    return FFBLoc(@"Sec.Shields");
        case FFBSectionShortcuts:  return FFBLoc(@"Sec.Shortcuts");
        case FFBSectionDiscovered: return FFBLoc(@"Sec.Discovered");
        case FFBSectionAbout:      return FFBLoc(@"Sec.About");
        default:                   return nil;
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == FFBSectionDiscovered && self.extraDiscoveredTabs.count == 0) {
        return nil;
    }
    switch (section) {
        case FFBSectionAdBlock:    return FFBLoc(@"Sec.AdBlockFooter");
        case FFBSectionFoqosLock:  return FFBLoc(@"Sec.FoqosLockFooter");
        case FFBSectionTabs:       return FFBLoc(@"Sec.TabsFooter");
        case FFBSectionShields:    return FFBLoc(@"Sec.ShieldsFooter");
        case FFBSectionShortcuts:  return FFBLoc(@"Sec.ShortcutsFooter");
        case FFBSectionDiscovered: return FFBLoc(@"Sec.DiscoveredFooter");
        default:                   return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == FFBSectionDiscovered) {
        return [self discoveredCellForTableView:tableView atRow:indexPath.row];
    }

    static NSString * const kStdCellID = @"FFBStandardCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kStdCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kStdCellID];
        cell.textLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
        cell.textLabel.numberOfLines = 2;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 0;
    }

    BOOL isAboutSection = (indexPath.section == FFBSectionAbout);
    BOOL locked = isAboutSection ? NO : [self isEditingLocked];
    FFBSettingItem *item = [self itemsForStandardSection:indexPath.section][(NSUInteger)indexPath.row];
    cell.textLabel.text = FFBLoc(item.titleKey);
    cell.textLabel.textColor = locked ? [UIColor secondaryLabelColor] : [UIColor labelColor];
    cell.detailTextLabel.text = item.dynamicSubtitle ?: (item.subtitleKey ? FFBLoc(item.subtitleKey) : nil);

    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:18.5 weight:UIImageSymbolWeightSemibold];
    cell.imageView.image = [UIImage systemImageNamed:item.symbolName withConfiguration:symCfg];
    cell.imageView.tintColor = item.symbolColor ?: [UIColor systemBlueColor];

    if (item.getter || item.customBoolGetter) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = item.customBoolGetter ? item.customBoolGetter() : item.getter([FocusFBPrefs shared]);
        sw.enabled = !locked;
        sw.onTintColor = [UIColor systemBlueColor];
        sw.tag = (indexPath.section << 16) | (indexPath.row & 0xFFFF);
        [sw addTarget:self action:@selector(switchValueChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (item.valueBadgeText.length > 0) {
        UILabel *badge = [[UILabel alloc] init];
        badge.text = [NSString stringWithFormat:@"  %@  ", item.valueBadgeText];
        badge.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        badge.textColor = [UIColor systemBlueColor];
        badge.backgroundColor = [UIColor secondarySystemFillColor];
        badge.layer.cornerRadius = 8.0;
        badge.layer.masksToBounds = YES;
        [badge sizeToFit];
        CGRect bf = badge.frame;
        bf.size.height = 26.0;
        badge.frame = bf;
        cell.accessoryView = badge;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else if (item.action) {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }

    return cell;
}

- (UITableViewCell *)discoveredCellForTableView:(UITableView *)tableView atRow:(NSInteger)row {
    static NSString * const kDiscCellID = @"FFBDiscoveredCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kDiscCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kDiscCellID];
        cell.textLabel.font = [UIFont systemFontOfSize:15.5 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 1;
    }

    FocusFBDiscoveredTab *tab = self.extraDiscoveredTabs[(NSUInteger)row];
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    FocusFBOverrideMode mode = [prefs overrideModeForTabKey:tab.key];
    BOOL currentlyAllowed = [prefs isTabAllowedForType:tab.tabType key:tab.key];

    NSString *modeLabel = FFBLoc(@"Override.Auto");
    if (mode == FocusFBOverrideForceShow) modeLabel = FFBLoc(@"Override.Show");
    else if (mode == FocusFBOverrideForceHide) modeLabel = FFBLoc(@"Override.Hide");

    NSString *rawTitle = (tab.label.length > 0) ? tab.label : FFBLoc(@"Tab.UnknownLabel");
    cell.textLabel.text = rawTitle;
    cell.detailTextLabel.text = modeLabel;

    cell.imageView.image = [UIImage systemImageNamed:[FocusFBPrefs sfSymbolForTabType:tab.tabType]];
    cell.imageView.tintColor = currentlyAllowed ? [UIColor systemBlueColor] : [UIColor systemGrayColor];
    cell.accessoryType = [self isEditingLocked] ? UITableViewCellAccessoryNone : UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section != FFBSectionAbout && [self isEditingLocked]) {
        [self notifyEditingBlocked];
        return;
    }

    if (indexPath.section == FFBSectionDiscovered) {
        if ((NSUInteger)indexPath.row >= self.extraDiscoveredTabs.count) return;
        FocusFBDiscoveredTab *tab = self.extraDiscoveredTabs[(NSUInteger)indexPath.row];
        [self promptOverrideForDiscoveredTab:tab sourceCell:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }

    FFBSettingItem *item = [self itemsForStandardSection:indexPath.section][(NSUInteger)indexPath.row];
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (item.action) {
        item.action(self, cell);
    } else if (item.getter || item.customBoolGetter) {
        if ([cell.accessoryView isKindOfClass:UISwitch.class]) {
            UISwitch *sw = (UISwitch *)cell.accessoryView;
            [sw setOn:!sw.isOn animated:YES];
            [self switchValueChanged:sw];
        }
    }
}

- (void)promptOverrideForDiscoveredTab:(FocusFBDiscoveredTab *)tab sourceCell:(UITableViewCell *)sourceCell {
    NSString *title = tab.label.length > 0 ? tab.label : FFBLoc(@"Tab.UnknownLabel");
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    __weak FocusFBSettingsViewController *weakSelf = self;
    void (^applyMode)(FocusFBOverrideMode) = ^(FocusFBOverrideMode mode) {
        [[FocusFBPrefs shared] setOverrideMode:mode forTabKey:tab.key];
        [weakSelf refreshAllDataAnimated];
    };

    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Override.Auto")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) { applyMode(FocusFBOverrideAuto); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Override.Show")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) { applyMode(FocusFBOverrideForceShow); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Override.Hide")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *a) { applyMode(FocusFBOverrideForceHide); }]];
    [sheet addAction:[UIAlertAction actionWithTitle:FFBLoc(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *pop = sheet.popoverPresentationController;
    if (pop) {
        pop.sourceView = sourceCell ?: self.view;
        pop.sourceRect = sourceCell ? sourceCell.bounds : CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    }

    [self presentViewController:sheet animated:YES completion:nil];
}

@end
