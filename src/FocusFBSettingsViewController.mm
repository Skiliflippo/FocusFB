#import "FocusFBSettingsViewController.h"
#import "FocusFBPrefs.h"
#import "FocusFBTabManager.h"

typedef NS_ENUM(NSInteger, FFBSectionIndex) {
    FFBSectionMaster = 0,
    FFBSectionPresets,
    FFBSectionTabs,
    FFBSectionShields,
    FFBSectionShortcuts,
    FFBSectionDiscovered,
    FFBSectionCount
};

@interface FFBSettingItem : NSObject
@property (nonatomic, copy) NSString *titleKey;
@property (nonatomic, copy) NSString *subtitleKey;
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, strong) UIColor *symbolColor;
@property (nonatomic, copy, nullable) BOOL (^getter)(FocusFBPrefs *prefs);
@property (nonatomic, copy, nullable) void (^setter)(FocusFBPrefs *prefs, BOOL value);
@property (nonatomic, copy, nullable) void (^action)(FocusFBSettingsViewController *vc);
@end

@implementation FFBSettingItem
@end

@interface FocusFBSettingsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *masterItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *presetItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *tabItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *shieldItems;
@property (nonatomic, strong) NSArray<FFBSettingItem *> *shortcutItems;
@property (nonatomic, strong) NSArray<FocusFBDiscoveredTab *> *discoveredSnapshot;
@end

static BOOL gIsPresentingSettings = NO;

@implementation FocusFBSettingsViewController

+ (void)presentFromTopMostController {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gIsPresentingSettings) return;
        UIViewController *top = FocusFBTopMostViewController();
        if (!top) return;
        if ([top isKindOfClass:FocusFBSettingsViewController.class] ||
            [top.navigationController.viewControllers.firstObject isKindOfClass:FocusFBSettingsViewController.class]) {
            return;
        }

        gIsPresentingSettings = YES;
        FocusFBSettingsViewController *settingsVC = [[FocusFBSettingsViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settingsVC];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet = nav.sheetPresentationController;
            if (sheet) {
                sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
                sheet.prefersGrabberVisible = YES;
            }
        }
        [top presentViewController:nav animated:YES completion:^{
            gIsPresentingSettings = NO;
        }];
    });
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

    NSString *langTitle = FFBIsItalianLocale() ? @"🇮🇹 IT" : @"🇬🇧 EN";
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
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 360, 168)];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 6.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:40.0 weight:UIImageSymbolWeightBold];
    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"storefront.circle.fill" withConfiguration:cfg]];
    logo.tintColor = [UIColor systemBlueColor];
    [stack addArrangedSubview:logo];

    NSString *fbVer = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"-";
    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = [NSString stringWithFormat:@"FocusFB 1.0  •  FB v%@", fbVer];
    titleLbl.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightBold];
    titleLbl.textColor = [UIColor labelColor];
    [stack addArrangedSubview:titleLbl];

    UILabel *subLbl = [[UILabel alloc] init];
    subLbl.text = FFBLoc(@"Subtitle");
    subLbl.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subLbl.textColor = [UIColor secondaryLabelColor];
    subLbl.textAlignment = NSTextAlignmentCenter;
    subLbl.numberOfLines = 0;
    [stack addArrangedSubview:subLbl];

    [stack setCustomSpacing:12.0 afterView:subLbl];

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
        [goBtn.widthAnchor constraintGreaterThanOrEqualToConstant:210.0]
    ]];
    [goBtn addTarget:self action:@selector(openMarketplaceFromHeader) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:goBtn];

    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:16.0],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-10.0],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-20.0]
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
                                     void (^action)(FocusFBSettingsViewController *)) {
    FFBSettingItem *item = [[FFBSettingItem alloc] init];
    item.titleKey = titleKey;
    item.subtitleKey = subtitleKey;
    item.symbolName = symbol;
    item.symbolColor = color;
    item.action = action;
    return item;
}

- (void)rebuildDataModel {
    self.discoveredSnapshot = [[FocusFBPrefs shared] discoveredTabs];

    self.masterItems = @[
        FFBBoolItem(@"Master.Enable", @"Master.EnableDesc", @"power.circle.fill", [UIColor systemGreenColor],
                    ^BOOL(FocusFBPrefs *p) { return p.enabled; },
                    ^(FocusFBPrefs *p, BOOL v) { p.enabled = v; })
    ];

    self.presetItems = @[
        FFBActionItem(@"Preset.MarketplaceOnly", @"Preset.MarketplaceOnlyDesc", @"scope", [UIColor systemBlueColor],
                      ^(FocusFBSettingsViewController *vc) {
            [[FocusFBPrefs shared] applyMarketplaceOnlyPreset];
            [vc refreshAllDataAnimated];
            FocusFBShowToast(FFBLoc(@"Preset.AppliedToast"), @"storefront.fill");
        }),
        FFBActionItem(@"Preset.SellerMode", @"Preset.SellerModeDesc", @"bag.badge.plus", [UIColor systemIndigoColor],
                      ^(FocusFBSettingsViewController *vc) {
            [[FocusFBPrefs shared] applyMarketplaceAndSellerToolsPreset];
            [vc refreshAllDataAnimated];
            FocusFBShowToast(FFBLoc(@"Preset.AppliedToast"), @"bell.badge.fill");
        }),
        FFBActionItem(@"Preset.ShowAll", @"Preset.ShowAllDesc", @"square.grid.2x2.fill", [UIColor systemGrayColor],
                      ^(FocusFBSettingsViewController *vc) {
            [[FocusFBPrefs shared] applyShowAllTabsPreset];
            [vc refreshAllDataAnimated];
            FocusFBShowToast(FFBLoc(@"Preset.AppliedToast"), @"checkmark.circle.fill");
        })
    ];

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
        FFBBoolItem(@"Tab.HideUnknown", @"Tab.HideUnknownDesc", @"sparkles.rectangle.stack.fill", [UIColor systemBrownColor],
                    ^BOOL(FocusFBPrefs *p) { return p.hideUnknownTabs; },
                    ^(FocusFBPrefs *p, BOOL v) { p.hideUnknownTabs = v; })
    ];

    self.shieldItems = @[
        FFBBoolItem(@"Shield.StartMarketplace", @"Shield.StartMarketplaceDesc", @"bolt.horizontal.circle.fill", [UIColor systemBlueColor],
                    ^BOOL(FocusFBPrefs *p) { return p.startOnMarketplace; },
                    ^(FocusFBPrefs *p, BOOL v) { p.startOnMarketplace = v; }),
        FFBBoolItem(@"Shield.HomeFeed", @"Shield.HomeFeedDesc", @"eye.slash.fill", [UIColor systemIndigoColor],
                    ^BOOL(FocusFBPrefs *p) { return p.shieldHomeFeed; },
                    ^(FocusFBPrefs *p, BOOL v) { p.shieldHomeFeed = v; }),
        FFBBoolItem(@"Shield.BlockReels", @"Shield.BlockReelsDesc", @"hand.raised.fill", [UIColor systemRedColor],
                    ^BOOL(FocusFBPrefs *p) { return p.blockReelsEverywhere; },
                    ^(FocusFBPrefs *p, BOOL v) { p.blockReelsEverywhere = v; }),
        FFBBoolItem(@"Shield.HideStories", @"Shield.HideStoriesDesc", @"rectangle.slash.fill", [UIColor systemOrangeColor],
                    ^BOOL(FocusFBPrefs *p) { return p.hideStoriesAndInlineReels; },
                    ^(FocusFBPrefs *p, BOOL v) { p.hideStoriesAndInlineReels = v; }),
        FFBBoolItem(@"Shield.ReflowTabs", @"Shield.ReflowTabsDesc", @"align.horizontal.center.fill", [UIColor systemTealColor],
                    ^BOOL(FocusFBPrefs *p) { return p.reflowVisibleTabs; },
                    ^(FocusFBPrefs *p, BOOL v) { p.reflowVisibleTabs = v; }),
        FFBBoolItem(@"Shield.HideSingleBar", @"Shield.HideSingleBarDesc", @"dock.arrow.down.rectangle", [UIColor systemPurpleColor],
                    ^BOOL(FocusFBPrefs *p) { return p.hideSingleTabBar; },
                    ^(FocusFBPrefs *p, BOOL v) { p.hideSingleTabBar = v; })
    ];

    self.shortcutItems = @[
        FFBBoolItem(@"Short.TwoFinger", @"Short.TwoFingerDesc", @"hand.tap.fill", [UIColor systemBlueColor],
                    ^BOOL(FocusFBPrefs *p) { return p.twoFingerLongPressEnabled; },
                    ^(FocusFBPrefs *p, BOOL v) { p.twoFingerLongPressEnabled = v; }),
        FFBBoolItem(@"Short.FloatingGear", @"Short.FloatingGearDesc", @"gearshape.circle.fill", [UIColor systemGrayColor],
                    ^BOOL(FocusFBPrefs *p) { return p.showFloatingGearButton; },
                    ^(FocusFBPrefs *p, BOOL v) { p.showFloatingGearButton = v; })
    ];
}

- (void)refreshAllDataAnimated {
    [self rebuildDataModel];
    [self configureNavigationBar];
    self.tableView.tableHeaderView = [self buildHeaderView];
    [self.tableView reloadData];
}

#pragma mark - Actions

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)openMarketplaceFromHeader {
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

- (void)switchValueChanged:(UISwitch *)sender {
    NSInteger section = sender.tag >> 16;
    NSInteger row = sender.tag & 0xFFFF;
    NSArray<FFBSettingItem *> *list = [self itemsForStandardSection:section];
    if (row < 0 || (NSUInteger)row >= list.count) return;

    FFBSettingItem *item = list[(NSUInteger)row];
    if (item.setter) {
        FocusFBPrefs *prefs = [FocusFBPrefs shared];
        item.setter(prefs, sender.isOn);
        [prefs notifyChanges];
    }
}

#pragma mark - TableView Helpers

- (NSArray<FFBSettingItem *> *)itemsForStandardSection:(NSInteger)section {
    switch (section) {
        case FFBSectionMaster:    return self.masterItems;
        case FFBSectionPresets:   return self.presetItems;
        case FFBSectionTabs:      return self.tabItems;
        case FFBSectionShields:   return self.shieldItems;
        case FFBSectionShortcuts: return self.shortcutItems;
        default:                  return @[];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return FFBSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == FFBSectionDiscovered) {
        return MAX((NSInteger)1, (NSInteger)self.discoveredSnapshot.count);
    }
    return (NSInteger)[self itemsForStandardSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case FFBSectionMaster:     return FFBLoc(@"Sec.Master");
        case FFBSectionPresets:    return FFBLoc(@"Sec.Presets");
        case FFBSectionTabs:       return FFBLoc(@"Sec.Tabs");
        case FFBSectionShields:    return FFBLoc(@"Sec.Shields");
        case FFBSectionShortcuts:  return FFBLoc(@"Sec.Shortcuts");
        case FFBSectionDiscovered: return FFBLoc(@"Sec.Discovered");
        default:                   return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
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

    FFBSettingItem *item = [self itemsForStandardSection:indexPath.section][(NSUInteger)indexPath.row];
    cell.textLabel.text = FFBLoc(item.titleKey);
    cell.detailTextLabel.text = item.subtitleKey ? FFBLoc(item.subtitleKey) : nil;

    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:19.0 weight:UIImageSymbolWeightSemibold];
    cell.imageView.image = [UIImage systemImageNamed:item.symbolName withConfiguration:symCfg];
    cell.imageView.tintColor = item.symbolColor ?: [UIColor systemBlueColor];

    if (item.getter) {
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = item.getter([FocusFBPrefs shared]);
        sw.onTintColor = [UIColor systemBlueColor];
        sw.tag = (indexPath.section << 16) | (indexPath.row & 0xFFFF);
        [sw addTarget:self action:@selector(switchValueChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }

    return cell;
}

- (UITableViewCell *)discoveredCellForTableView:(UITableView *)tableView atRow:(NSInteger)row {
    static NSString * const kDiscCellID = @"FFBDiscoveredCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kDiscCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kDiscCellID];
        cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightMedium];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 0;
    }

    if (self.discoveredSnapshot.count == 0) {
        cell.textLabel.text = FFBLoc(@"Override.NoneYet");
        cell.detailTextLabel.text = nil;
        cell.imageView.image = [UIImage systemImageNamed:@"magnifyingglass"];
        cell.imageView.tintColor = [UIColor secondaryLabelColor];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    FocusFBDiscoveredTab *tab = self.discoveredSnapshot[(NSUInteger)row];
    FocusFBPrefs *prefs = [FocusFBPrefs shared];
    FocusFBOverrideMode mode = [prefs overrideModeForTabKey:tab.key];
    BOOL currentlyAllowed = [prefs isTabAllowedForType:tab.tabType key:tab.key];

    NSString *modeLabel = FFBLoc(@"Override.Auto");
    if (mode == FocusFBOverrideForceShow) modeLabel = FFBLoc(@"Override.Show");
    else if (mode == FocusFBOverrideForceHide) modeLabel = FFBLoc(@"Override.Hide");

    NSString *categoryName = [FocusFBPrefs displayNameForTabType:tab.tabType];
    NSString *rawTitle = (tab.label.length > 0) ? tab.label : categoryName;
    cell.textLabel.text = [NSString stringWithFormat:@"%@  (%@)", rawTitle, currentlyAllowed ? @"ON" : @"OFF"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Categoria: %@ • ID: %@ • Stato: %@",
                                 categoryName,
                                 tab.identifier ?: @"-",
                                 modeLabel];

    cell.imageView.image = [UIImage systemImageNamed:[FocusFBPrefs sfSymbolForTabType:tab.tabType]];
    cell.imageView.tintColor = currentlyAllowed ? [UIColor systemBlueColor] : [UIColor systemGrayColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == FFBSectionDiscovered) {
        if (self.discoveredSnapshot.count == 0) return;
        FocusFBDiscoveredTab *tab = self.discoveredSnapshot[(NSUInteger)indexPath.row];
        [self promptOverrideForDiscoveredTab:tab sourceCell:[tableView cellForRowAtIndexPath:indexPath]];
        return;
    }

    FFBSettingItem *item = [self itemsForStandardSection:indexPath.section][(NSUInteger)indexPath.row];
    if (item.action) {
        item.action(self);
    } else if (item.getter && item.setter) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        if ([cell.accessoryView isKindOfClass:UISwitch.class]) {
            UISwitch *sw = (UISwitch *)cell.accessoryView;
            [sw setOn:!sw.isOn animated:YES];
            [self switchValueChanged:sw];
        }
    }
}

- (void)promptOverrideForDiscoveredTab:(FocusFBDiscoveredTab *)tab sourceCell:(UITableViewCell *)sourceCell {
    NSString *title = tab.label.length > 0 ? tab.label : [FocusFBPrefs displayNameForTabType:tab.tabType];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:tab.key
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
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
