#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FocusFBPreferencesDidChangeNotification;

typedef NS_ENUM(NSInteger, FocusFBTabType) {
    FocusFBTabUnknown = 0,
    FocusFBTabHome,
    FocusFBTabReels,
    FocusFBTabMarketplace,
    FocusFBTabFriends,
    FocusFBTabGroups,
    FocusFBTabNotifications,
    FocusFBTabProfile,
    FocusFBTabMenu
};

typedef NS_ENUM(NSInteger, FocusFBOverrideMode) {
    FocusFBOverrideAuto = 0,
    FocusFBOverrideForceShow = 1,
    FocusFBOverrideForceHide = 2
};

@interface FocusFBDiscoveredTab : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *className;
@property (nonatomic, assign) FocusFBTabType tabType;
@end

@interface FocusFBPrefs : NSObject

+ (instancetype)shared;

// Master switch & Onboarding
@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) BOOL hasSeenWelcome;
@property (nonatomic, copy) NSString *languageCode; // "auto", "it", "en"

// Visibilità singoli Tab (Default: SOLO Marketplace attivo)
@property (nonatomic, assign) BOOL showHomeTab;
@property (nonatomic, assign) BOOL showReelsTab;
@property (nonatomic, assign) BOOL showMarketplaceTab;
@property (nonatomic, assign) BOOL showFriendsTab;
@property (nonatomic, assign) BOOL showGroupsTab;
@property (nonatomic, assign) BOOL showNotificationsTab;
@property (nonatomic, assign) BOOL showProfileTab;
@property (nonatomic, assign) BOOL showMenuTab;
@property (nonatomic, assign) BOOL hideUnknownTabs;

// Protezioni Anti-Distrazione, AdBlock & Layout
@property (nonatomic, assign) BOOL blockAllAds;
@property (nonatomic, assign) BOOL hideSuggestedClutter;
@property (nonatomic, assign) BOOL startOnMarketplace;
@property (nonatomic, assign) BOOL shieldHomeFeed;
@property (nonatomic, assign) BOOL blockReelsEverywhere;
@property (nonatomic, assign) BOOL hideStoriesAndInlineReels;
@property (nonatomic, assign) BOOL reflowVisibleTabs;
@property (nonatomic, assign) BOOL hideSingleTabBar;

// Scorciatoie apertura Impostazioni FocusFB
@property (nonatomic, assign) BOOL twoFingerLongPressEnabled;
@property (nonatomic, assign) BOOL showFloatingGearButton;

// Preset rapidi
- (void)applyMarketplaceOnlyPreset;
- (void)applyMarketplaceAndSellerToolsPreset;
- (void)applyShowAllTabsPreset;

// Classificazione e filtro Tab
+ (FocusFBTabType)classifyTabWithIdentifier:(nullable NSString *)identifier
                                      label:(nullable NSString *)label;
+ (NSString *)displayNameForTabType:(FocusFBTabType)tabType;
+ (NSString *)sfSymbolForTabType:(FocusFBTabType)tabType;

- (BOOL)isTabAllowedForType:(FocusFBTabType)tabType
                        key:(nullable NSString *)rawKey;

// Override granulari per i tab scoperti a runtime
- (FocusFBOverrideMode)overrideModeForTabKey:(NSString *)key;
- (void)setOverrideMode:(FocusFBOverrideMode)mode forTabKey:(NSString *)key;
- (void)clearAllOverrides;

// Registro live dei tab trovati nella versione corrente di Facebook
- (void)recordDiscoveredTabWithKey:(NSString *)key
                             label:(NSString *)label
                        identifier:(NSString *)identifier
                         className:(NSString *)className
                           tabType:(FocusFBTabType)tabType;
- (NSArray<FocusFBDiscoveredTab *> *)discoveredTabs;

- (void)notifyChanges;

@end

#ifdef __cplusplus
extern "C" {
#endif
NSString *FFBLoc(NSString *key);
BOOL FFBIsItalianLocale(void);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
