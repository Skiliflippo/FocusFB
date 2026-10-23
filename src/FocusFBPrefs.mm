#import "FocusFBPrefs.h"

NSString * const FocusFBPreferencesDidChangeNotification = @"com.focusfb.preferencesDidChange";

static NSString * const kKeyEnabled                 = @"FocusFB_Enabled";
static NSString * const kKeyHasSeenWelcome          = @"FocusFB_HasSeenWelcome";
static NSString * const kKeyLanguageCode            = @"FocusFB_LanguageCode";

static NSString * const kKeyShowHome                = @"FocusFB_ShowTab_Home";
static NSString * const kKeyShowReels               = @"FocusFB_ShowTab_Reels";
static NSString * const kKeyShowMarketplace         = @"FocusFB_ShowTab_Marketplace";
static NSString * const kKeyShowFriends             = @"FocusFB_ShowTab_Friends";
static NSString * const kKeyShowGroups              = @"FocusFB_ShowTab_Groups";
static NSString * const kKeyShowNotifications       = @"FocusFB_ShowTab_Notifications";
static NSString * const kKeyShowProfile             = @"FocusFB_ShowTab_Profile";
static NSString * const kKeyShowMenu                = @"FocusFB_ShowTab_Menu";
static NSString * const kKeyHideUnknown             = @"FocusFB_HideUnknownTabs";

static NSString * const kKeyStartOnMarketplace      = @"FocusFB_StartOnMarketplace";
static NSString * const kKeyShieldHomeFeed          = @"FocusFB_ShieldHomeFeed";
static NSString * const kKeyBlockReelsEverywhere    = @"FocusFB_BlockReelsEverywhere";
static NSString * const kKeyHideStoriesAndReels     = @"FocusFB_HideStoriesAndInlineReels";
static NSString * const kKeyReflowVisibleTabs       = @"FocusFB_ReflowVisibleTabs";
static NSString * const kKeyHideSingleTabBar        = @"FocusFB_HideSingleTabBar";

static NSString * const kKeyTwoFingerLongPress      = @"FocusFB_TwoFingerLongPress";
static NSString * const kKeyShowFloatingGear        = @"FocusFB_ShowFloatingGear";
static NSString * const kKeyCustomOverrides         = @"FocusFB_CustomTabOverrides";

@implementation FocusFBDiscoveredTab
@end

static NSDictionary<NSString *, NSString *> *FFBItalianStrings(void) {
    static NSDictionary<NSString *, NSString *> *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dict = @{
            @"AppTitle": @"FocusFB",
            @"Subtitle": @"Facebook senza distrazioni • Modalità su misura",
            @"Close": @"Chiudi",
            @"Cancel": @"Annulla",
            @"OpenMarketplaceNow": @"Apri Marketplace Ora",

            // Sezioni
            @"Sec.Master": @"Stato Generale",
            @"Sec.Presets": @"Preset Rapidi (1-Tap)",
            @"Sec.Tabs": @"Tab Visibili sulla Barra",
            @"Sec.TabsFooter": @"Attiva solo le sezioni che ti servono davvero. Le modifiche si applicano in tempo reale alla barra di Facebook.",
            @"Sec.Shields": @"Protezione Anti-Distrazione & Avvio",
            @"Sec.ShieldsFooter": @"Impedisce a Facebook di catturarti con il News Feed o con i Reels appena apri l'app o quando premi indietro.",
            @"Sec.Shortcuts": @"Come Aprire Queste Impostazioni",
            @"Sec.ShortcutsFooter": @"Suggerimento: puoi sempre aprire FocusFB tenendo premuto su qualsiasi tab visibile (es. Marketplace), sulla barra inferiore oppure tenendo premuto con 2 dita ovunque.",
            @"Sec.Discovered": @"Tab Rilevati in Questa Versione (Live)",
            @"Sec.DiscoveredFooter": @"Elenco live dei tab individuati nell'app Facebook attuale. Tocca una riga se vuoi forzare Mostra/Nascondi su uno specifico elemento.",

            // Master
            @"Master.Enable": @"Attiva Filtro FocusFB",
            @"Master.EnableDesc": @"Disattiva temporaneamente se vuoi usare Facebook standard senza perdere la tua configurazione.",
            @"Lang.Switch": @"Lingua Interfaccia",

            // Presets
            @"Preset.MarketplaceOnly": @"Solo Marketplace (Focus Totale)",
            @"Preset.MarketplaceOnlyDesc": @"Mostra esclusivamente il Marketplace, salta il Feed all'avvio e blocca tutti i Reels.",
            @"Preset.SellerMode": @"Marketplace + Notifiche + Menu",
            @"Preset.SellerModeDesc": @"Ideale se vendi annunci: mantiene Marketplace, Notifiche e Menu nascondendo Feed, Reels, Amici e Gruppi.",
            @"Preset.ShowAll": @"Mostra tutti i Tab di Facebook",
            @"Preset.ShowAllDesc": @"Ripristina tutti i tab nella barra inferiore.",
            @"Preset.AppliedToast": @"Preset applicato",

            // Tab names
            @"Tab.Marketplace": @"Marketplace",
            @"Tab.MarketplaceDesc": @"Compra e vendi annunci locali.",
            @"Tab.Home": @"Home / Sezione Notizie",
            @"Tab.HomeDesc": @"Il feed infinito principale di Facebook.",
            @"Tab.Reels": @"Video / Reels / Watch",
            @"Tab.ReelsDesc": @"Feed verticale di video brevi algoritmici.",
            @"Tab.Friends": @"Amici",
            @"Tab.FriendsDesc": @"Richieste di amicizia e persone che potresti conoscere.",
            @"Tab.Groups": @"Gruppi",
            @"Tab.GroupsDesc": @"Feed e discussioni dei gruppi.",
            @"Tab.Notifications": @"Notifiche",
            @"Tab.NotificationsDesc": @"Avvisi su risposte, annunci e attività.",
            @"Tab.Profile": @"Profilo",
            @"Tab.ProfileDesc": @"Il tuo profilo personale.",
            @"Tab.Menu": @"Menu / Altro",
            @"Tab.MenuDesc": @"Scorciatoie e impostazioni account Facebook.",
            @"Tab.HideUnknown": @"Nascondi altri tab extra",
            @"Tab.HideUnknownDesc": @"Nasconde eventuali nuovi tab aggiunti da Meta (es. Gaming, Dating, Eventi, Meta AI).",
            @"Tab.UnknownLabel": @"Altro Tab",

            // Shields
            @"Shield.StartMarketplace": @"Avvia sempre su Marketplace",
            @"Shield.StartMarketplaceDesc": @"All'apertura salta subito il News Feed e porta direttamente sul Marketplace.",
            @"Shield.HomeFeed": @"Oscura il Feed Home",
            @"Shield.HomeFeedDesc": @"Se Home è nascosto, copre il feed con uno schermo pulito anti-doomscrolling e ferma i video.",
            @"Shield.BlockReels": @"Blocca Player Reels ovunque",
            @"Shield.BlockReelsDesc": @"Blocca l'apertura a schermo intero dei Reels anche da link esterni o suggerimenti.",
            @"Shield.HideStories": @"Nascondi Storie e caroselli Reels",
            @"Shield.HideStoriesDesc": @"Rimuove la barra delle Storie in alto e i rulli di video brevi.",
            @"Shield.ReflowTabs": @"Centra i tab rimasti nella barra",
            @"Shield.ReflowTabsDesc": @"Distribuisce e centra in modo pulito le icone visibili nella barra inferiore.",
            @"Shield.HideSingleBar": @"Nascondi barra se c'è 1 solo tab",
            @"Shield.HideSingleBarDesc": @"Nasconde anche la barra inferiore quando resta attivo solo Marketplace (usa 2 dita per riaprire FocusFB).",

            // Shortcuts
            @"Short.TwoFinger": @"Pressione prolungata con 2 dita",
            @"Short.TwoFingerDesc": @"Tieni premuto con 2 dita per 0,6s ovunque per aprire le Impostazioni FocusFB.",
            @"Short.FloatingGear": @"Pulsante flottante FocusFB",
            @"Short.FloatingGearDesc": @"Mostra un piccolo bottone trascinabile sul bordo dello schermo.",

            // Overrides
            @"Override.Auto": @"Automatico",
            @"Override.Show": @"Forza Mostra",
            @"Override.Hide": @"Forza Nascondi",
            @"Override.ResetAll": @"Azzera override manuali",
            @"Override.NoneYet": @"Nessun tab ancora rilevato (apri la schermata principale di Facebook).",

            // Shield Overlay UI
            @"Overlay.FeedTitle": @"Feed Disattivato",
            @"Overlay.FeedBody": @"Hai nascosto il News Feed per concentrarti su ciò che ti serve davvero, senza perderti tra post e video.",
            @"Overlay.ReelsTitle": @"Reels Bloccati",
            @"Overlay.ReelsBody": @"Il player dei Reels è bloccato da FocusFB per proteggere il tuo tempo.",
            @"Overlay.GoMarketplace": @"Vai a Marketplace",
            @"Overlay.GoBack": @"Torna Indietro",
            @"Overlay.OpenSettings": @"Impostazioni FocusFB",

            // Context Menu
            @"Menu.Settings": @"Impostazioni FocusFB",
            @"Menu.Marketplace": @"Vai a Marketplace",
            @"Menu.SoloToggleOn": @"Attiva Solo Marketplace",
            @"Menu.SoloToggleOff": @"Mostra Tutti i Tab",

            // Welcome
            @"Welcome.Title": @"Benvenuto in FocusFB",
            @"Welcome.Body": @"La modalità \"Solo Marketplace\" è già attiva per evitarti qualsiasi distrazione da Feed e Reels.\n\nCome aprire le Impostazioni FocusFB in qualsiasi momento:\n• Tieni premuto sul tab Marketplace o sulla barra in basso\n• Oppure tieni premuto con 2 dita in qualunque punto dello schermo",
            @"Welcome.Start": @"Inizia su Marketplace",
            @"Welcome.Customize": @"Personalizza i Tab"
        };
    });
    return dict;
}

static NSDictionary<NSString *, NSString *> *FFBEnglishStrings(void) {
    static NSDictionary<NSString *, NSString *> *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dict = @{
            @"AppTitle": @"FocusFB",
            @"Subtitle": @"Distraction-free Facebook • Custom Tab Filter",
            @"Close": @"Done",
            @"Cancel": @"Cancel",
            @"OpenMarketplaceNow": @"Open Marketplace Now",

            @"Sec.Master": @"General Status",
            @"Sec.Presets": @"Quick Presets (1-Tap)",
            @"Sec.Tabs": @"Visible Navigation Tabs",
            @"Sec.TabsFooter": @"Keep only the tabs you actually need. Changes apply live to Facebook's navigation bar.",
            @"Sec.Shields": @"Anti-Distraction & Startup",
            @"Sec.ShieldsFooter": @"Stops Facebook from dropping you into the News Feed or Reels when opening the app.",
            @"Sec.Shortcuts": @"How to Open FocusFB Settings",
            @"Sec.ShortcutsFooter": @"Tip: Long-press any visible tab (e.g. Marketplace), long-press the bottom bar, or hold 2 fingers anywhere on screen.",
            @"Sec.Discovered": @"Detected Tabs in This Version (Live)",
            @"Sec.DiscoveredFooter": @"Live list of tab items found in your Facebook version. Tap a row to force Show/Hide.",

            @"Master.Enable": @"Enable FocusFB Filter",
            @"Master.EnableDesc": @"Temporarily disable to use stock Facebook without losing your saved setup.",
            @"Lang.Switch": @"Interface Language",

            @"Preset.MarketplaceOnly": @"Marketplace Only (Maximum Focus)",
            @"Preset.MarketplaceOnlyDesc": @"Shows only Marketplace, launches straight into Marketplace, and blocks Reels & Feed.",
            @"Preset.SellerMode": @"Marketplace + Notifications + Menu",
            @"Preset.SellerModeDesc": @"Great for sellers: keeps Marketplace, Notifications, and Menu while hiding Feed & Reels.",
            @"Preset.ShowAll": @"Show All Stock Tabs",
            @"Preset.ShowAllDesc": @"Restores all tabs on the bottom navigation bar.",
            @"Preset.AppliedToast": @"Preset applied",

            @"Tab.Marketplace": @"Marketplace",
            @"Tab.MarketplaceDesc": @"Buy and sell local listings.",
            @"Tab.Home": @"Home / News Feed",
            @"Tab.HomeDesc": @"Main algorithmic scrolling feed.",
            @"Tab.Reels": @"Video / Reels / Watch",
            @"Tab.ReelsDesc": @"Short-form vertical video feed.",
            @"Tab.Friends": @"Friends",
            @"Tab.FriendsDesc": @"Friend requests and People You May Know.",
            @"Tab.Groups": @"Groups",
            @"Tab.GroupsDesc": @"Groups feed and discussions.",
            @"Tab.Notifications": @"Notifications",
            @"Tab.NotificationsDesc": @"Activity and listing reply alerts.",
            @"Tab.Profile": @"Profile",
            @"Tab.ProfileDesc": @"Your personal profile tab.",
            @"Tab.Menu": @"Menu / More",
            @"Tab.MenuDesc": @"Bookmarks and Facebook account settings.",
            @"Tab.HideUnknown": @"Hide Extra Dynamic Tabs",
            @"Tab.HideUnknownDesc": @"Hides extra tabs added by Meta (Gaming, Dating, Events, Meta AI).",
            @"Tab.UnknownLabel": @"Other Tab",

            @"Shield.StartMarketplace": @"Always Launch on Marketplace",
            @"Shield.StartMarketplaceDesc": @"Skips the News Feed on startup and switches directly to Marketplace.",
            @"Shield.HomeFeed": @"Shield Home Feed",
            @"Shield.HomeFeedDesc": @"Covers the Home Feed with a clean focus screen and pauses autoplay videos when Home is hidden.",
            @"Shield.BlockReels": @"Block Reels Player Everywhere",
            @"Shield.BlockReelsDesc": @"Blocks full-screen Reels players even when opened from links or carousels.",
            @"Shield.HideStories": @"Hide Stories & Reels Carousels",
            @"Shield.HideStoriesDesc": @"Hides the top Stories tray and inline short-video units.",
            @"Shield.ReflowTabs": @"Center Remaining Tabs",
            @"Shield.ReflowTabsDesc": @"Cleanly centers visible tab icons inside the bottom bar.",
            @"Shield.HideSingleBar": @"Hide Entire Bar When Single Tab",
            @"Shield.HideSingleBarDesc": @"Hides the bottom bar completely when only Marketplace is active (use 2-finger hold for settings).",

            @"Short.TwoFinger": @"2-Finger Long Press Gesture",
            @"Short.TwoFingerDesc": @"Hold 2 fingers anywhere for 0.6s to open FocusFB Settings.",
            @"Short.FloatingGear": @"Floating FocusFB Button",
            @"Short.FloatingGearDesc": @"Shows a small draggable gear button on the screen edge.",

            @"Override.Auto": @"Automatic",
            @"Override.Show": @"Force Show",
            @"Override.Hide": @"Force Hide",
            @"Override.ResetAll": @"Reset Manual Overrides",
            @"Override.NoneYet": @"No tabs detected yet (open Facebook's main screen first).",

            @"Overlay.FeedTitle": @"News Feed Hidden",
            @"Overlay.FeedBody": @"You hid the News Feed to stay focused on what matters without getting pulled into posts and Reels.",
            @"Overlay.ReelsTitle": @"Reels Blocked",
            @"Overlay.ReelsBody": @"The Reels player is blocked by FocusFB to protect your attention.",
            @"Overlay.GoMarketplace": @"Open Marketplace",
            @"Overlay.GoBack": @"Go Back",
            @"Overlay.OpenSettings": @"FocusFB Settings",

            @"Menu.Settings": @"FocusFB Settings",
            @"Menu.Marketplace": @"Go to Marketplace",
            @"Menu.SoloToggleOn": @"Enable Marketplace Only",
            @"Menu.SoloToggleOff": @"Show All Tabs",

            @"Welcome.Title": @"Welcome to FocusFB",
            @"Welcome.Body": @"\"Marketplace Only\" mode is active by default so you won't be distracted by the Feed or Reels.\n\nHow to open FocusFB Settings anytime:\n• Long-press the Marketplace tab or bottom bar\n• Or hold 2 fingers anywhere on the screen",
            @"Welcome.Start": @"Start on Marketplace",
            @"Welcome.Customize": @"Customize Tabs"
        };
    });
    return dict;
}

BOOL FFBIsItalianLocale(void) {
    NSString *code = [FocusFBPrefs shared].languageCode;
    if ([code isEqualToString:@"it"]) return YES;
    if ([code isEqualToString:@"en"]) return NO;
    NSString *preferred = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"it";
    return [preferred hasPrefix:@"it"];
}

NSString *FFBLoc(NSString *key) {
    if (!key) return @"";
    NSDictionary<NSString *, NSString *> *primary = FFBIsItalianLocale() ? FFBItalianStrings() : FFBEnglishStrings();
    NSString *val = primary[key];
    if (val) return val;
    return FFBEnglishStrings()[key] ?: key;
}

@implementation FocusFBPrefs {
    NSUserDefaults *_defaults;
    NSMutableDictionary<NSString *, FocusFBDiscoveredTab *> *_discoveredMap;
    NSMutableArray<NSString *> *_discoveredOrder;
}

+ (instancetype)shared {
    static FocusFBPrefs *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FocusFBPrefs alloc] initPrivate];
    });
    return instance;
}

- (instancetype)initPrivate {
    self = [super init];
    if (self) {
        _defaults = [NSUserDefaults standardUserDefaults];
        _discoveredMap = [NSMutableDictionary dictionary];
        _discoveredOrder = [NSMutableArray array];

        // Default al primo avvio: SOLO Marketplace attivo e protezioni ON
        [_defaults registerDefaults:@{
            kKeyEnabled:               @YES,
            kKeyHasSeenWelcome:        @NO,
            kKeyLanguageCode:          @"auto",

            kKeyShowMarketplace:       @YES,
            kKeyShowHome:              @NO,
            kKeyShowReels:             @NO,
            kKeyShowFriends:           @NO,
            kKeyShowGroups:            @NO,
            kKeyShowNotifications:     @NO,
            kKeyShowProfile:           @NO,
            kKeyShowMenu:              @NO,
            kKeyHideUnknown:           @YES,

            kKeyStartOnMarketplace:    @YES,
            kKeyShieldHomeFeed:        @YES,
            kKeyBlockReelsEverywhere:  @YES,
            kKeyHideStoriesAndReels:   @YES,
            kKeyReflowVisibleTabs:     @YES,
            kKeyHideSingleTabBar:      @NO,

            kKeyTwoFingerLongPress:    @YES,
            kKeyShowFloatingGear:      @NO
        }];
    }
    return self;
}

#pragma mark - Properties

#define FFB_BOOL_PROP(getter, setter, keyConst) \
- (BOOL)getter { return [_defaults boolForKey:keyConst]; } \
- (void)setter:(BOOL)val { [_defaults setBool:val forKey:keyConst]; }

FFB_BOOL_PROP(enabled, setEnabled, kKeyEnabled)
FFB_BOOL_PROP(hasSeenWelcome, setHasSeenWelcome, kKeyHasSeenWelcome)

FFB_BOOL_PROP(showHomeTab, setShowHomeTab, kKeyShowHome)
FFB_BOOL_PROP(showReelsTab, setShowReelsTab, kKeyShowReels)
FFB_BOOL_PROP(showMarketplaceTab, setShowMarketplaceTab, kKeyShowMarketplace)
FFB_BOOL_PROP(showFriendsTab, setShowFriendsTab, kKeyShowFriends)
FFB_BOOL_PROP(showGroupsTab, setShowGroupsTab, kKeyShowGroups)
FFB_BOOL_PROP(showNotificationsTab, setShowNotificationsTab, kKeyShowNotifications)
FFB_BOOL_PROP(showProfileTab, setShowProfileTab, kKeyShowProfile)
FFB_BOOL_PROP(showMenuTab, setShowMenuTab, kKeyShowMenu)
FFB_BOOL_PROP(hideUnknownTabs, setHideUnknownTabs, kKeyHideUnknown)

FFB_BOOL_PROP(startOnMarketplace, setStartOnMarketplace, kKeyStartOnMarketplace)
FFB_BOOL_PROP(shieldHomeFeed, setShieldHomeFeed, kKeyShieldHomeFeed)
FFB_BOOL_PROP(blockReelsEverywhere, setBlockReelsEverywhere, kKeyBlockReelsEverywhere)
FFB_BOOL_PROP(hideStoriesAndInlineReels, setHideStoriesAndInlineReels, kKeyHideStoriesAndReels)
FFB_BOOL_PROP(reflowVisibleTabs, setReflowVisibleTabs, kKeyReflowVisibleTabs)
FFB_BOOL_PROP(hideSingleTabBar, setHideSingleTabBar, kKeyHideSingleTabBar)

FFB_BOOL_PROP(twoFingerLongPressEnabled, setTwoFingerLongPressEnabled, kKeyTwoFingerLongPress)
FFB_BOOL_PROP(showFloatingGearButton, setShowFloatingGearButton, kKeyShowFloatingGear)

- (NSString *)languageCode {
    return [_defaults stringForKey:kKeyLanguageCode] ?: @"auto";
}

- (void)setLanguageCode:(NSString *)languageCode {
    [_defaults setObject:(languageCode ?: @"auto") forKey:kKeyLanguageCode];
}

#pragma mark - Presets

- (void)applyMarketplaceOnlyPreset {
    self.enabled = YES;
    self.showMarketplaceTab = YES;
    self.showHomeTab = NO;
    self.showReelsTab = NO;
    self.showFriendsTab = NO;
    self.showGroupsTab = NO;
    self.showNotificationsTab = NO;
    self.showProfileTab = NO;
    self.showMenuTab = NO;
    self.hideUnknownTabs = YES;

    self.startOnMarketplace = YES;
    self.shieldHomeFeed = YES;
    self.blockReelsEverywhere = YES;
    self.hideStoriesAndInlineReels = YES;
    [self clearAllOverrides];
    [self notifyChanges];
}

- (void)applyMarketplaceAndSellerToolsPreset {
    self.enabled = YES;
    self.showMarketplaceTab = YES;
    self.showNotificationsTab = YES;
    self.showMenuTab = YES;

    self.showHomeTab = NO;
    self.showReelsTab = NO;
    self.showFriendsTab = NO;
    self.showGroupsTab = NO;
    self.showProfileTab = NO;
    self.hideUnknownTabs = YES;

    self.startOnMarketplace = YES;
    self.shieldHomeFeed = YES;
    self.blockReelsEverywhere = YES;
    self.hideStoriesAndInlineReels = YES;
    [self clearAllOverrides];
    [self notifyChanges];
}

- (void)applyShowAllTabsPreset {
    self.enabled = YES;
    self.showMarketplaceTab = YES;
    self.showHomeTab = YES;
    self.showReelsTab = YES;
    self.showFriendsTab = YES;
    self.showGroupsTab = YES;
    self.showNotificationsTab = YES;
    self.showProfileTab = YES;
    self.showMenuTab = YES;
    self.hideUnknownTabs = NO;

    self.startOnMarketplace = NO;
    self.shieldHomeFeed = NO;
    self.blockReelsEverywhere = NO;
    [self clearAllOverrides];
    [self notifyChanges];
}

#pragma mark - Tab Classification

static BOOL FFBContainsAny(NSString *haystack, NSArray<NSString *> *needles) {
    if (haystack.length == 0) return NO;
    for (NSString *needle in needles) {
        if ([haystack rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

+ (FocusFBTabType)classifyTabWithIdentifier:(NSString *)identifier label:(NSString *)label {
    NSString *ident = (identifier ?: @"").lowercaseString;
    NSString *lbl   = (label ?: @"").lowercaseString;
    NSString *combined = [NSString stringWithFormat:@"%@ | %@", ident, lbl];

    // 1. Marketplace ha priorità massima (evita falsi match con "marketplace_home")
    if (FFBContainsAny(combined, @[@"marketplace", @"1606854132932955", @"localsell", @"b2c_commerce"])) {
        return FocusFBTabMarketplace;
    }

    // 2. Video / Reels / Watch
    if (FFBContainsAny(combined, @[@"reels", @"reel", @"watch", @"video", @"tahoe", @"2392950137", @"short_form"])) {
        return FocusFBTabReels;
    }

    // 3. Notifiche
    if (FFBContainsAny(combined, @[@"notification", @"notifiche", @"notificaciones", @"benachrichtigung", @"jewel", @"1603421209951282"])) {
        return FocusFBTabNotifications;
    }

    // 4. Amici
    if (FFBContainsAny(combined, @[@"friend", @"friending", @"amici", @"amicizia", @"2356318349", @"amis", @"amigos", @"freunde"])) {
        return FocusFBTabFriends;
    }

    // 5. Gruppi
    if (FFBContainsAny(combined, @[@"group", @"gruppi", @"targeted_tab", @"2361831622", @"grupos", @"gruppen"])) {
        return FocusFBTabGroups;
    }

    // 6. Menu / Bookmarks
    if (FFBContainsAny(combined, @[@"bookmark", @"menu", @"menù", @"navigation", @"scorciatoie", @"281710865595635"]) ||
        [lbl isEqualToString:@"more"] || [lbl isEqualToString:@"altro"]) {
        return FocusFBTabMenu;
    }

    // 7. Profilo
    if (FFBContainsAny(combined, @[@"profile", @"profilo", @"timeline", @"perfil"]) ||
        [lbl isEqualToString:@"profil"]) {
        return FocusFBTabProfile;
    }

    // 8. Home / News Feed
    if (FFBContainsAny(combined, @[@"newsfeed", @"news_feed", @"main_feed", @"4748854339", @"sezione notizie", @"notizie", @"accueil", @"inicio", @"startseite"]) ||
        FFBContainsAny(ident, @[@"feed", @"home", @"tabbar-home"]) ||
        [lbl isEqualToString:@"home"] || [lbl hasPrefix:@"home,"] || [lbl hasPrefix:@"home "] ||
        [lbl isEqualToString:@"feed"]) {
        return FocusFBTabHome;
    }

    return FocusFBTabUnknown;
}

+ (NSString *)displayNameForTabType:(FocusFBTabType)tabType {
    switch (tabType) {
        case FocusFBTabMarketplace:   return FFBLoc(@"Tab.Marketplace");
        case FocusFBTabHome:          return FFBLoc(@"Tab.Home");
        case FocusFBTabReels:         return FFBLoc(@"Tab.Reels");
        case FocusFBTabFriends:       return FFBLoc(@"Tab.Friends");
        case FocusFBTabGroups:        return FFBLoc(@"Tab.Groups");
        case FocusFBTabNotifications: return FFBLoc(@"Tab.Notifications");
        case FocusFBTabProfile:       return FFBLoc(@"Tab.Profile");
        case FocusFBTabMenu:          return FFBLoc(@"Tab.Menu");
        case FocusFBTabUnknown:
        default:                      return FFBLoc(@"Tab.UnknownLabel");
    }
}

+ (NSString *)sfSymbolForTabType:(FocusFBTabType)tabType {
    switch (tabType) {
        case FocusFBTabMarketplace:   return @"storefront.fill";
        case FocusFBTabHome:          return @"house.fill";
        case FocusFBTabReels:         return @"play.rectangle.on.rectangle.fill";
        case FocusFBTabFriends:       return @"person.2.fill";
        case FocusFBTabGroups:        return @"person.3.fill";
        case FocusFBTabNotifications: return @"bell.fill";
        case FocusFBTabProfile:       return @"person.crop.circle.fill";
        case FocusFBTabMenu:          return @"line.3.horizontal";
        case FocusFBTabUnknown:
        default:                      return @"square.grid.2x2";
    }
}

- (BOOL)isTabAllowedForType:(FocusFBTabType)tabType key:(NSString *)rawKey {
    if (!self.enabled) return YES;

    if (rawKey.length > 0) {
        FocusFBOverrideMode overrideMode = [self overrideModeForTabKey:rawKey];
        if (overrideMode == FocusFBOverrideForceShow) return YES;
        if (overrideMode == FocusFBOverrideForceHide) return NO;
    }

    switch (tabType) {
        case FocusFBTabMarketplace:   return self.showMarketplaceTab;
        case FocusFBTabHome:          return self.showHomeTab;
        case FocusFBTabReels:         return self.showReelsTab;
        case FocusFBTabFriends:       return self.showFriendsTab;
        case FocusFBTabGroups:        return self.showGroupsTab;
        case FocusFBTabNotifications: return self.showNotificationsTab;
        case FocusFBTabProfile:       return self.showProfileTab;
        case FocusFBTabMenu:          return self.showMenuTab;
        case FocusFBTabUnknown:
        default:                      return !self.hideUnknownTabs;
    }
}

#pragma mark - Per-Tab Overrides

- (FocusFBOverrideMode)overrideModeForTabKey:(NSString *)key {
    if (key.length == 0) return FocusFBOverrideAuto;
    NSDictionary *dict = [_defaults dictionaryForKey:kKeyCustomOverrides];
    NSNumber *num = dict[key];
    if (![num isKindOfClass:NSNumber.class]) return FocusFBOverrideAuto;
    NSInteger val = num.integerValue;
    if (val == FocusFBOverrideForceShow || val == FocusFBOverrideForceHide) {
        return (FocusFBOverrideMode)val;
    }
    return FocusFBOverrideAuto;
}

- (void)setOverrideMode:(FocusFBOverrideMode)mode forTabKey:(NSString *)key {
    if (key.length == 0) return;
    NSMutableDictionary *dict = [[_defaults dictionaryForKey:kKeyCustomOverrides] ?: @{} mutableCopy];
    if (mode == FocusFBOverrideAuto) {
        [dict removeObjectForKey:key];
    } else {
        dict[key] = @(mode);
    }
    [_defaults setObject:dict forKey:kKeyCustomOverrides];
    [self notifyChanges];
}

- (void)clearAllOverrides {
    [_defaults removeObjectForKey:kKeyCustomOverrides];
}

#pragma mark - Live Discovered Tabs Registry

- (void)recordDiscoveredTabWithKey:(NSString *)key
                             label:(NSString *)label
                        identifier:(NSString *)identifier
                         className:(NSString *)className
                           tabType:(FocusFBTabType)tabType {
    if (key.length == 0) return;
    @synchronized (self) {
        FocusFBDiscoveredTab *entry = _discoveredMap[key];
        if (!entry) {
            entry = [[FocusFBDiscoveredTab alloc] init];
            entry.key = key;
            _discoveredMap[key] = entry;
            [_discoveredOrder addObject:key];
        }
        if (label.length > 0 && ![label isEqualToString:@"-"]) entry.label = label;
        if (identifier.length > 0 && ![identifier isEqualToString:@"-"]) entry.identifier = identifier;
        if (className.length > 0) entry.className = className;
        entry.tabType = tabType;
    }
}

- (NSArray<FocusFBDiscoveredTab *> *)discoveredTabs {
    @synchronized (self) {
        NSMutableArray<FocusFBDiscoveredTab *> *list = [NSMutableArray arrayWithCapacity:_discoveredOrder.count];
        for (NSString *key in _discoveredOrder) {
            FocusFBDiscoveredTab *item = _discoveredMap[key];
            if (item) [list addObject:item];
        }
        return [list copy];
    }
}

- (void)notifyChanges {
    [_defaults synchronize];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBPreferencesDidChangeNotification
                                                            object:self];
    });
}

@end
