#import "FocusFBPrefs.h"
#include <atomic>

NSString * const FocusFBPreferencesDidChangeNotification = @"com.focusfb.preferencesDidChange";

static NSString * const kKeyEnabled                   = @"FocusFB_Enabled";
static NSString * const kKeyHasSeenWelcome            = @"FocusFB_HasSeenWelcome";
static NSString * const kKeyLanguageCode              = @"FocusFB_LanguageCode";

static NSString * const kKeyShowHome                  = @"FocusFB_ShowTab_Home";
static NSString * const kKeyShowReels                 = @"FocusFB_ShowTab_Reels";
static NSString * const kKeyShowMarketplace           = @"FocusFB_ShowTab_Marketplace";
static NSString * const kKeyShowFriends               = @"FocusFB_ShowTab_Friends";
static NSString * const kKeyShowGroups                = @"FocusFB_ShowTab_Groups";
static NSString * const kKeyShowNotifications         = @"FocusFB_ShowTab_Notifications";
static NSString * const kKeyShowProfile               = @"FocusFB_ShowTab_Profile";
static NSString * const kKeyShowMenu                  = @"FocusFB_ShowTab_Menu";
static NSString * const kKeyHideUnknown               = @"FocusFB_HideUnknownTabs";

static NSString * const kKeyBlockAllAds               = @"FocusFB_BlockAllAds";
static NSString * const kKeyHidePeopleYouMayKnow      = @"FocusFB_HidePeopleYouMayKnow";
static NSString * const kKeyHideReelsCarousel         = @"FocusFB_HideReelsCarousel";
static NSString * const kKeyHideSuggestedClutter      = @"FocusFB_HideSuggestedClutter";
static NSString * const kKeyHideStoriesTray           = @"FocusFB_HideStoriesTray";

static NSString * const kKeyEnableMediaDownload       = @"FocusFB_EnableMediaDownload";
static NSString * const kKeyShowMediaDownloadButton   = @"FocusFB_ShowVideoQuickButton";

static NSString * const kKeyStoriesIncognitoMode      = @"FocusFB_StoriesIncognitoMode";

static NSString * const kKeyStartOnMarketplace        = @"FocusFB_StartOnMarketplace";
static NSString * const kKeyShieldHomeFeed            = @"FocusFB_ShieldHomeFeed";
static NSString * const kKeyBlockReelsEverywhere      = @"FocusFB_BlockReelsEverywhere";
static NSString * const kKeyReflowVisibleTabs         = @"FocusFB_ReflowVisibleTabs";
static NSString * const kKeyHideSingleTabBar          = @"FocusFB_HideSingleTabBar";

static NSString * const kKeyTwoFingerLongPress        = @"FocusFB_TwoFingerLongPress";
static NSString * const kKeyShowFloatingGear          = @"FocusFB_ShowFloatingGear";
static NSString * const kKeyCustomOverrides           = @"FocusFB_CustomTabOverrides";

static std::atomic<uint64_t> gPrefsGenCounter{1};

@implementation FocusFBDiscoveredTab
@end

static NSDictionary<NSString *, NSString *> *FFBItalianStrings(void) {
    static NSDictionary<NSString *, NSString *> *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dict = @{
            @"AppTitle": @"FocusFB",
            @"Subtitle": @"Usa solo le parti di Facebook che ti servono",
            @"Close": @"Fine",
            @"Cancel": @"Annulla",
            @"OpenMarketplaceNow": @"Apri Marketplace",

            // Sezioni
            @"Sec.Master": @"Generale",
            @"Sec.AdBlock": @"Pulizia Feed e pubblicità",
            @"Sec.AdBlockFooter": @"Rimuove annunci sponsorizzati, carosello Reels, suggerimenti di amicizia e contenuti consigliati.",
            @"Sec.MediaPrivacy": @"Download Reels e Storie in incognito",
            @"Sec.MediaPrivacyFooter": @"Nei Reels trovi l'icona di download direttamente sopra il tasto Mi piace per salvare il video in HD nel Rullino.",
            @"Sec.Presets": @"Configurazioni rapide",
            @"Sec.Tabs": @"Schede visibili",
            @"Sec.TabsFooter": @"Scegli quali schede tenere nella barra in basso.",
            @"Sec.Shields": @"Aspetto e filtri",
            @"Sec.ShieldsFooter": @"Controlla la schermata iniziale e blocca Feed o Reels.",
            @"Sec.Shortcuts": @"Accesso impostazioni",
            @"Sec.ShortcutsFooter": @"Puoi aprire FocusFB tenendo premuto con 2 dita sullo schermo o tenendo premuta una scheda in basso.",
            @"Sec.Discovered": @"Altre schede rilevate",
            @"Sec.DiscoveredFooter": @"Schede aggiuntive trovate sul tuo account. Tocca una voce per mostrarla o nasconderla.",
            @"Sec.About": @"Info e supporto",

            // Master
            @"Master.Enable": @"FocusFB attivo",
            @"Master.EnableDesc": @"Disattiva per tornare temporaneamente a Facebook normale.",
            @"Lang.Switch": @"Lingua",

            // Pulizia Feed e AdBlock
            @"AdBlock.EnableAll": @"Blocca inserzioni sponsorizzate",
            @"AdBlock.EnableAllDesc": @"Rimuove annunci in Marketplace, ricerca, Feed e Storie.",
            @"AdBlock.HidePYMK": @"Rimuovi \"Persone che potresti conoscere\"",
            @"AdBlock.HidePYMKDesc": @"Elimina i riquadri di amicizie suggerite nel Feed e nelle Storie.",
            @"AdBlock.HideReelsCarousel": @"Nascondi carosello Reels",
            @"AdBlock.HideReelsCarouselDesc": @"Rimuove la striscia dei Reels consigliati dentro il Feed.",
            @"AdBlock.HideSuggested": @"Nascondi post e pagine suggerite",
            @"AdBlock.HideSuggestedDesc": @"Rimuove gruppi consigliati, post \"Suggeriti per te\" e Threads.",
            @"AdBlock.HideStoriesTray": @"Nascondi barra Storie",
            @"AdBlock.HideStoriesTrayDesc": @"Nasconde la riga delle Storie in cima al Feed.",

            // Download Video & Storie in incognito
            @"Media.EnableDownload": @"Pulsante download nei Reels",
            @"Media.EnableDownloadDesc": @"Mostra l'icona di download sopra Mi piace nei Reels per salvarli nel Rullino.",
            @"Stories.Incognito": @"Storie in incognito",
            @"Stories.IncognitoDesc": @"Guarda le Storie degli amici senza comparire nella lista visualizzazioni.",

            // Stringhe UI Download Video
            @"DL.Downloading": @"Download Reel in corso...",
            @"DL.SavedVideo": @"Video salvato nel Rullino",
            @"DL.Failed": @"Impossibile scaricare questo video",
            @"DL.NotFound": @"Avvia il Reel per un istante e riprova",

            // Presets
            @"Preset.MarketplaceOnly": @"Solo Marketplace",
            @"Preset.MarketplaceOnlyDesc": @"Tiene solo Marketplace a tutto schermo e blocca Feed e Reels.",
            @"Preset.SellerMode": @"Marketplace e Notifiche",
            @"Preset.SellerModeDesc": @"Tiene Marketplace, Notifiche e Menu per gestire annunci e risposte.",
            @"Preset.ShowAll": @"Mostra tutte le schede",
            @"Preset.ShowAllDesc": @"Ripristina tutte le schede (mantenendo AdBlock, Download e Incognito).",
            @"Preset.AppliedToast": @"Impostazione applicata",

            // Tab names
            @"Tab.Marketplace": @"Marketplace",
            @"Tab.MarketplaceDesc": @"Annunci di compravendita locali.",
            @"Tab.Home": @"Home",
            @"Tab.HomeDesc": @"Feed principale dei post.",
            @"Tab.Reels": @"Reels e Video",
            @"Tab.ReelsDesc": @"Video brevi a scorrimento verticale.",
            @"Tab.Friends": @"Amici",
            @"Tab.FriendsDesc": @"Richieste di amicizia e suggerimenti.",
            @"Tab.Groups": @"Gruppi",
            @"Tab.GroupsDesc": @"Post e discussioni dei gruppi.",
            @"Tab.Notifications": @"Notifiche",
            @"Tab.NotificationsDesc": @"Avvisi su messaggi, risposte e attività.",
            @"Tab.Profile": @"Profilo",
            @"Tab.ProfileDesc": @"Il tuo profilo personale.",
            @"Tab.Menu": @"Menu",
            @"Tab.MenuDesc": @"Impostazioni dell'account Facebook.",
            @"Tab.HideUnknown": @"Nascondi schede extra",
            @"Tab.HideUnknownDesc": @"Nasconde eventuali nuove schede aggiunte da Facebook (es. Gaming o Incontri).",
            @"Tab.UnknownLabel": @"Scheda aggiuntiva",

            // Shields
            @"Shield.StartMarketplace": @"Apri subito su Marketplace",
            @"Shield.StartMarketplaceDesc": @"All'avvio apre direttamente Marketplace invece della Home.",
            @"Shield.HomeFeed": @"Oscura il Feed Home",
            @"Shield.HomeFeedDesc": @"Copre i post della Home quando la scheda Home è disattivata.",
            @"Shield.BlockReels": @"Blocca apertura Reels",
            @"Shield.BlockReelsDesc": @"Impedisce l'apertura del player Reels anche dai link.",
            @"Shield.ReflowTabs": @"Centra le schede visibili",
            @"Shield.ReflowTabsDesc": @"Allinea al centro le icone rimaste nella barra inferiore.",
            @"Shield.HideSingleBar": @"Nascondi la barra con una sola scheda",
            @"Shield.HideSingleBarDesc": @"Rimuove del tutto la barra in basso quando resta attivo solo Marketplace.",

            // Shortcuts
            @"Short.TwoFinger": @"Tieni premuto con 2 dita",
            @"Short.TwoFingerDesc": @"Apre queste impostazioni tenendo 2 dita sullo schermo.",
            @"Short.FloatingGear": @"Pulsante impostazioni a schermo",
            @"Short.FloatingGearDesc": @"Mostra una piccola icona ingranaggio sul bordo dello schermo.",

            // Overrides
            @"Override.Auto": @"Automatico",
            @"Override.Show": @"Mostra sempre",
            @"Override.Hide": @"Nascondi sempre",
            @"Override.ResetAll": @"Ripristina predefiniti",
            @"Override.NoneYet": @"Nessuna scheda aggiuntiva rilevata.",

            // Shield Overlay UI
            @"Overlay.FeedTitle": @"Feed nascosto",
            @"Overlay.FeedBody": @"La Home è disattivata nelle impostazioni di FocusFB.",
            @"Overlay.ReelsTitle": @"Reels disattivati",
            @"Overlay.ReelsBody": @"I Reels sono bloccati nelle impostazioni di FocusFB.",
            @"Overlay.GoMarketplace": @"Vai a Marketplace",
            @"Overlay.GoBack": @"Indietro",
            @"Overlay.OpenSettings": @"Impostazioni",

            // Context Menu
            @"Menu.Settings": @"Impostazioni FocusFB",
            @"Menu.Marketplace": @"Vai a Marketplace",
            @"Menu.SoloToggleOn": @"Solo Marketplace",
            @"Menu.SoloToggleOff": @"Mostra tutte le schede",

            // Welcome
            @"Welcome.Title": @"FocusFB è attivo",
            @"Welcome.Body": @"Di base è visibile solo Marketplace, senza pubblicità né Reels.\n\nPer cambiare schede, scaricare media o attivare il blocco Foqos:\n• Tieni premuto con 2 dita in qualsiasi punto\n• Oppure tieni premuto sulla barra in basso",
            @"Welcome.Start": @"Continua",
            @"Welcome.Customize": @"Impostazioni",

            // Foqos Strict Lock & Time Limits (SOLO Feed / Reels / Social, Marketplace sempre libero)
            @"Sec.FoqosLock": @"Blocco Feed e Reels (Foqos)",
            @"Sec.FoqosLockFooter": @"Limita il tempo speso su Feed, Reels e schede social usando un codice QR, un codice a barre o un tag NFC fisico. Marketplace resta sempre libero.",
            @"Lock.BannerLockedTitle": @"Blocco attivo",
            @"Lock.BannerLockedSub": @"Marketplace è libero. Scansiona la chiave fisica per modificare le impostazioni.",
            @"Lock.BannerUnlockedTitle": @"Impostazioni sbloccate",
            @"Lock.BannerUnlockedSub": @"Il blocco tornerà attivo appena chiudi questa schermata.",
            @"Lock.ScanToEditBtn": @"Sblocca con chiave fisica",
            @"Lock.KeyStatusRow": @"Chiave associata",
            @"Lock.KeyNone": @"Nessuna chiave",
            @"Lock.RegisterQRBarcode": @"Associa codice QR o a barre",
            @"Lock.RegisterQRBarcodeDesc": @"Usa la fotocamera per associare il codice di un oggetto fisico.",
            @"Lock.GenerateSecretQR": @"Genera un codice QR da stampare",
            @"Lock.GenerateSecretQRDesc": @"Crea un codice QR casuale da stampare o salvare altrove.",
            @"Lock.RegisterNFC": @"Associa tag NFC",
            @"Lock.RegisterNFCDesc": @"Avvicina una tessera o adesivo NFC all'iPhone.",
            @"Lock.ScopeExceptMPBadge": @"Feed e Reels",
            @"Lock.SessionLimit": @"Tempo per sessione (Feed/Reels)",
            @"Lock.SessionLimitDesc": @"Durata massima continua fuori da Marketplace.",
            @"Lock.Cooldown": @"Pausa tra le sessioni",
            @"Lock.CooldownDesc": @"Attesa richiesta prima della sessione successiva.",
            @"Lock.DailyLimit": @"Limite giornaliero (Feed/Reels)",
            @"Lock.DailyLimitDesc": @"Tempo totale consentito in un giorno fuori da Marketplace.",
            @"Lock.ShowTimerPill": @"Mostra tempo rimasto in alto",
            @"Lock.ShowTimerPillDesc": @"Mostra il conto alla rovescia mentre usi Feed o altre schede.",
            @"Lock.AlwaysBlockedBadge": @"0 min",
            @"Lock.AlwaysBlockedOption": @"Sempre bloccato (0 min, solo con chiave)",
            @"Lock.EmergencyRow": @"Sblocco di emergenza",
            @"Lock.EmergencyDescFmt": @"Permette 3 sblocchi al mese senza chiave (%ld/%ld rimasti).",
            @"Lock.EmergencyBtnFmt": @"Emergenza (%ld/%ld rimasti)",
            @"Lock.EmergencyExhaustedFmt": @"Emergenza esaurita (0/%ld questo mese)",
            @"Lock.EmergencyConfirmTitle": @"Sblocco di emergenza",
            @"Lock.EmergencyConfirmBodyFmt": @"Vuoi usare uno sblocco di emergenza per disattivare il blocco? Ti resteranno %ld tentativi per questo mese.",
            @"Lock.EmergencyConfirmAction": @"Sblocca ora",
            @"Lock.EmergencyUsedToastFmt": @"Blocco disattivato (%ld/%ld emergenze rimaste)",
            @"Lock.EmergencyDisableWarnTitle": @"Disattivare lo sblocco di emergenza?",
            @"Lock.EmergencyDisableWarnBody": @"Se disattivi questa opzione e perdi la chiave fisica, non potrai più sbloccare FocusFB dall'app.",
            @"Lock.EmergencyDisableConfirm": @"Disattiva",
            @"Lock.StrictToggleOn": @"Attiva blocco",
            @"Lock.StrictToggleOnDesc": @"Blocca Feed, Reels e impostazioni con la chiave fisica (Marketplace resta libero).",
            @"Lock.StrictToggleOff": @"Disattiva blocco",
            @"Lock.StrictToggleOffDesc": @"Rimuove la protezione della chiave fisica.",
            @"Lock.Off": @"Spento",
            @"Lock.NeedKeyAlertTitle": @"Nessuna chiave associata",
            @"Lock.NeedKeyAlertBody": @"Prima di attivare il blocco, associa un codice QR, un codice a barre o un tag NFC.",
            @"Lock.LockedToast": @"Impostazioni bloccate: scansiona la chiave in alto",
            @"Lock.WallExtraSessionTitle": @"Tempo Feed scaduto",
            @"Lock.WallExtraDailyTitle": @"Limite giornaliero raggiunto",
            @"Lock.WallExtraAlwaysTitle": @"Feed e Reels bloccati",
            @"Lock.WallExtraBody": @"Il tempo per Feed e schede social è terminato. Marketplace resta sempre libero.",
            @"Lock.WallExtraAlwaysBody": @"Feed e Reels sono protetti dalla chiave fisica. Puoi tornare subito a Marketplace oppure sbloccare 5 minuti con la chiave.",
            @"Lock.WallResumeBtn": @"Sblocca con chiave (+5 min)",
            @"Lock.WallSettingsBtn": @"Sblocca impostazioni",
            @"Lock.WallGoMarketplaceBtn": @"Torna a Marketplace",
            @"Lock.WallRemainingWait": @"Disponibile tra",
            @"Lock.WallUsedToday": @"Usato oggi",
            @"Lock.ScanStep1": @"Inquadra il codice QR o a barre",
            @"Lock.ScanStep2": @"Inquadra di nuovo lo stesso codice per confermare",
            @"Lock.ScanUnlockPrompt": @"Inquadra la chiave registrata per sbloccare",
            @"Lock.ScanMismatch": @"Codice non riconosciuto. Usa la chiave associata.",
            @"Lock.KeySavedTitle": @"Chiave salvata",
            @"Lock.KeyNamePrompt": @"Nome promemoria facoltativo (es. Libro in salotto):",
            @"Lock.NFCUnavailableTitle": @"NFC non disponibile",
            @"Lock.NFCUnavailableBody": @"Con un Apple ID gratuito iOS non abilita la lettura NFC. Usa un codice QR o un codice a barre con la fotocamera.",
            @"Lock.ResetTimersRow": @"Azzera tempo usato oggi",
            @"Lock.ResetTimersDesc": @"Riporta a zero il contatore di oggi e della sessione.",
            @"Lock.TimersResetToast": @"Contatori azzerati",

            // Info & Supporto
            @"About.Donate": @"Supporta il progetto",
            @"About.DonateDesc": @"Offri un contributo volontario su PayPal.",
            @"About.GitHub": @"Codice sorgente su GitHub",
            @"About.GitHubDesc": @"Guida, aggiornamenti e licenza open source."
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
            @"Subtitle": @"Keep only the parts of Facebook you need",
            @"Close": @"Done",
            @"Cancel": @"Cancel",
            @"OpenMarketplaceNow": @"Open Marketplace",

            @"Sec.Master": @"General",
            @"Sec.AdBlock": @"Feed cleanup & ads",
            @"Sec.AdBlockFooter": @"Removes sponsored ads, Reels carousels, friend suggestions, and recommended posts.",
            @"Sec.MediaPrivacy": @"Reels download & incognito Stories",
            @"Sec.MediaPrivacyFooter": @"In Reels, tap the download icon right above the Like button to save HD videos directly to Photos.",
            @"Sec.Presets": @"Quick modes",
            @"Sec.Tabs": @"Visible tabs",
            @"Sec.TabsFooter": @"Choose which tabs stay on the bottom bar.",
            @"Sec.Shields": @"Layout & filters",
            @"Sec.ShieldsFooter": @"Control startup behavior and block Feed or Reels.",
            @"Sec.Shortcuts": @"Settings access",
            @"Sec.ShortcutsFooter": @"Open FocusFB anytime by holding 2 fingers on screen or long-pressing a tab.",
            @"Sec.Discovered": @"Extra detected tabs",
            @"Sec.DiscoveredFooter": @"Additional tabs found on your account. Tap an item to show or hide it.",
            @"Sec.About": @"About & support",

            @"Master.Enable": @"Enable FocusFB",
            @"Master.EnableDesc": @"Turn off to temporarily use standard Facebook.",
            @"Lang.Switch": @"Language",

            @"AdBlock.EnableAll": @"Block sponsored ads",
            @"AdBlock.EnableAllDesc": @"Removes ads across Marketplace, search, Feed, and Stories.",
            @"AdBlock.HidePYMK": @"Remove \"People You May Know\"",
            @"AdBlock.HidePYMKDesc": @"Hides friend suggestion boxes in Feed and Stories.",
            @"AdBlock.HideReelsCarousel": @"Hide Reels carousel",
            @"AdBlock.HideReelsCarouselDesc": @"Removes inline Reels shelves from the Feed.",
            @"AdBlock.HideSuggested": @"Hide suggested posts & pages",
            @"AdBlock.HideSuggestedDesc": @"Removes suggested groups, recommended posts, and Threads promos.",
            @"AdBlock.HideStoriesTray": @"Hide Stories bar",
            @"AdBlock.HideStoriesTrayDesc": @"Hides the Stories row at the top of the Feed.",

            @"Media.EnableDownload": @"Reels download button",
            @"Media.EnableDownloadDesc": @"Adds a native download icon right above the Like button in Reels.",
            @"Stories.Incognito": @"Incognito Stories",
            @"Stories.IncognitoDesc": @"Watch friends' Stories without sending a viewed receipt.",

            @"DL.Downloading": @"Downloading Reel...",
            @"DL.SavedVideo": @"Video saved to Photos",
            @"DL.Failed": @"Could not download this video",
            @"DL.NotFound": @"Let the Reel play for a moment and retry",
            @"DL.SaveVideo": @"Save Video to Photos",
            @"DL.Share": @"Share video file...",
            @"DL.Downloading": @"Downloading video...",
            @"DL.SavedVideo": @"Video saved to Photos",
            @"DL.Failed": @"Could not download this video",
            @"DL.NotFound": @"Play the video briefly and try again",

            @"Preset.MarketplaceOnly": @"Marketplace only",
            @"Preset.MarketplaceOnlyDesc": @"Keeps only full-screen Marketplace and blocks Feed and Reels.",
            @"Preset.SellerMode": @"Marketplace & Notifications",
            @"Preset.SellerModeDesc": @"Keeps Marketplace, Notifications, and Menu for managing listings.",
            @"Preset.ShowAll": @"Show all tabs",
            @"Preset.ShowAllDesc": @"Restores all tabs while keeping AdBlock, Downloads, and Incognito active.",
            @"Preset.AppliedToast": @"Mode applied",

            @"Tab.Marketplace": @"Marketplace",
            @"Tab.MarketplaceDesc": @"Local classifieds and listings.",
            @"Tab.Home": @"Home",
            @"Tab.HomeDesc": @"Main posts feed.",
            @"Tab.Reels": @"Reels & Video",
            @"Tab.ReelsDesc": @"Short vertical videos.",
            @"Tab.Friends": @"Friends",
            @"Tab.FriendsDesc": @"Friend requests and suggestions.",
            @"Tab.Groups": @"Groups",
            @"Tab.GroupsDesc": @"Group posts and discussions.",
            @"Tab.Notifications": @"Notifications",
            @"Tab.NotificationsDesc": @"Replies, messages, and activity alerts.",
            @"Tab.Profile": @"Profile",
            @"Tab.ProfileDesc": @"Your personal profile.",
            @"Tab.Menu": @"Menu",
            @"Tab.MenuDesc": @"Facebook account settings.",
            @"Tab.HideUnknown": @"Hide extra tabs",
            @"Tab.HideUnknownDesc": @"Hides extra tabs added by Facebook (such as Gaming or Dating).",
            @"Tab.UnknownLabel": @"Extra tab",

            @"Shield.StartMarketplace": @"Open directly on Marketplace",
            @"Shield.StartMarketplaceDesc": @"Skips Home at launch and opens Marketplace directly.",
            @"Shield.HomeFeed": @"Cover Home Feed",
            @"Shield.HomeFeedDesc": @"Covers Home posts when the Home tab is turned off.",
            @"Shield.BlockReels": @"Block Reels player",
            @"Shield.BlockReelsDesc": @"Prevents Reels from opening, including from shared links.",
            @"Shield.ReflowTabs": @"Center visible tabs",
            @"Shield.ReflowTabsDesc": @"Centers remaining tab icons on the bottom bar.",
            @"Shield.HideSingleBar": @"Hide bottom bar when single tab",
            @"Shield.HideSingleBarDesc": @"Removes the bottom bar completely when only Marketplace is visible.",

            @"Short.TwoFinger": @"2-finger hold",
            @"Short.TwoFingerDesc": @"Hold 2 fingers on screen to open these settings.",
            @"Short.FloatingGear": @"On-screen settings button",
            @"Short.FloatingGearDesc": @"Shows a small draggable gear button on the screen edge.",

            @"Override.Auto": @"Automatic",
            @"Override.Show": @"Always show",
            @"Override.Hide": @"Always hide",
            @"Override.ResetAll": @"Reset overrides",
            @"Override.NoneYet": @"No extra tabs detected.",

            @"Overlay.FeedTitle": @"Feed hidden",
            @"Overlay.FeedBody": @"Home is turned off in FocusFB settings.",
            @"Overlay.ReelsTitle": @"Reels blocked",
            @"Overlay.ReelsBody": @"Reels are turned off in FocusFB settings.",
            @"Overlay.GoMarketplace": @"Open Marketplace",
            @"Overlay.GoBack": @"Back",
            @"Overlay.OpenSettings": @"Settings",

            @"Menu.Settings": @"FocusFB Settings",
            @"Menu.Marketplace": @"Open Marketplace",
            @"Menu.SoloToggleOn": @"Marketplace only",
            @"Menu.SoloToggleOff": @"Show all tabs",

            @"Welcome.Title": @"FocusFB is active",
            @"Welcome.Body": @"Only Marketplace is shown by default, with ads and Reels removed.\n\nTo customize tabs, download media, or enable Foqos lock:\n• Hold 2 fingers anywhere on screen\n• Or long-press the bottom bar",
            @"Welcome.Start": @"Continue",
            @"Welcome.Customize": @"Settings",

            // Foqos Strict Lock & Time Limits (Feed / Reels / Social ONLY, Marketplace always free)
            @"Sec.FoqosLock": @"Feed & Reels lock (Foqos)",
            @"Sec.FoqosLockFooter": @"Limit time spent on Feed, Reels, and social tabs using a physical QR code, barcode, or NFC tag. Marketplace stays open at all times.",
            @"Lock.BannerLockedTitle": @"Lock active",
            @"Lock.BannerLockedSub": @"Marketplace is open. Scan your physical key to edit settings.",
            @"Lock.BannerUnlockedTitle": @"Settings unlocked",
            @"Lock.BannerUnlockedSub": @"Lock will resume when you close this screen.",
            @"Lock.ScanToEditBtn": @"Unlock with physical key",
            @"Lock.KeyStatusRow": @"Paired key",
            @"Lock.KeyNone": @"None",
            @"Lock.RegisterQRBarcode": @"Pair QR code or barcode",
            @"Lock.RegisterQRBarcodeDesc": @"Use the camera to pair a code on any physical object.",
            @"Lock.GenerateSecretQR": @"Create printable QR code",
            @"Lock.GenerateSecretQRDesc": @"Generate a random QR code to print or save elsewhere.",
            @"Lock.RegisterNFC": @"Pair NFC tag",
            @"Lock.RegisterNFCDesc": @"Hold an NFC card or sticker near your iPhone.",
            @"Lock.ScopeExceptMPBadge": @"Feed & Reels",
            @"Lock.SessionLimit": @"Session time (Feed/Reels)",
            @"Lock.SessionLimitDesc": @"Maximum continuous usage outside Marketplace.",
            @"Lock.Cooldown": @"Break between sessions",
            @"Lock.CooldownDesc": @"Waiting time before starting a new session.",
            @"Lock.DailyLimit": @"Daily limit (Feed/Reels)",
            @"Lock.DailyLimitDesc": @"Total time allowed per day outside Marketplace.",
            @"Lock.ShowTimerPill": @"Show remaining time at top",
            @"Lock.ShowTimerPillDesc": @"Displays a countdown while using Feed or social tabs.",
            @"Lock.AlwaysBlockedBadge": @"0 min",
            @"Lock.AlwaysBlockedOption": @"Always locked (0 min, key only)",
            @"Lock.EmergencyRow": @"Emergency unlock",
            @"Lock.EmergencyDescFmt": @"Allows 3 unlocks per month without your key (%ld/%ld left).",
            @"Lock.EmergencyBtnFmt": @"Emergency (%ld/%ld left)",
            @"Lock.EmergencyExhaustedFmt": @"No emergency unlocks left (0/%ld this month)",
            @"Lock.EmergencyConfirmTitle": @"Emergency unlock",
            @"Lock.EmergencyConfirmBodyFmt": @"Use one emergency unlock to turn off the lock? You will have %ld left for this month.",
            @"Lock.EmergencyConfirmAction": @"Unlock now",
            @"Lock.EmergencyUsedToastFmt": @"Lock disabled (%ld/%ld emergency unlocks left)",
            @"Lock.EmergencyDisableWarnTitle": @"Turn off emergency unlock?",
            @"Lock.EmergencyDisableWarnBody": @"If you disable this option and lose your physical key, you will not be able to unlock FocusFB from inside the app.",
            @"Lock.EmergencyDisableConfirm": @"Turn off",
            @"Lock.StrictToggleOn": @"Turn on lock",
            @"Lock.StrictToggleOnDesc": @"Protects Feed, Reels, and settings with your key (Marketplace stays open).",
            @"Lock.StrictToggleOff": @"Turn off lock",
            @"Lock.StrictToggleOffDesc": @"Removes physical key protection.",
            @"Lock.Off": @"Off",
            @"Lock.NeedKeyAlertTitle": @"No key paired",
            @"Lock.NeedKeyAlertBody": @"Pair a QR code, barcode, or NFC tag before turning on the lock.",
            @"Lock.LockedToast": @"Settings locked: scan your key at the top",
            @"Lock.WallExtraSessionTitle": @"Feed time is up",
            @"Lock.WallExtraDailyTitle": @"Daily limit reached",
            @"Lock.WallExtraAlwaysTitle": @"Feed & Reels locked",
            @"Lock.WallExtraBody": @"Your time for Feed and social tabs is up. Marketplace remains open.",
            @"Lock.WallExtraAlwaysBody": @"Feed and Reels are locked behind your physical key. Return to Marketplace anytime or scan your key for 5 minutes.",
            @"Lock.WallResumeBtn": @"Unlock with key (+5 min)",
            @"Lock.WallSettingsBtn": @"Unlock settings",
            @"Lock.WallGoMarketplaceBtn": @"Back to Marketplace",
            @"Lock.WallRemainingWait": @"Available in",
            @"Lock.WallUsedToday": @"Used today",
            @"Lock.ScanStep1": @"Point the camera at your QR code or barcode",
            @"Lock.ScanStep2": @"Scan the same code again to confirm",
            @"Lock.ScanUnlockPrompt": @"Scan your paired key to unlock",
            @"Lock.ScanMismatch": @"Code does not match your paired key.",
            @"Lock.KeySavedTitle": @"Key saved",
            @"Lock.KeyNamePrompt": @"Optional label (e.g. Living room book):",
            @"Lock.NFCUnavailableTitle": @"NFC unavailable",
            @"Lock.NFCUnavailableBody": @"Free Apple IDs do not support NFC reading on iOS. Pair a QR code or barcode with the camera instead.",
            @"Lock.ResetTimersRow": @"Reset today's usage",
            @"Lock.ResetTimersDesc": @"Resets today's and current session counters to zero.",
            @"Lock.TimersResetToast": @"Usage reset",

            // About & Support
            @"About.Donate": @"Support the project",
            @"About.DonateDesc": @"Leave a voluntary tip via PayPal.",
            @"About.GitHub": @"Source code on GitHub",
            @"About.GitHubDesc": @"Documentation, updates, and open-source license."
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

        [_defaults registerDefaults:@{
            kKeyEnabled:                   @YES,
            kKeyHasSeenWelcome:            @NO,
            kKeyLanguageCode:              @"auto",

            kKeyShowMarketplace:           @YES,
            kKeyShowHome:                  @NO,
            kKeyShowReels:                 @NO,
            kKeyShowFriends:               @NO,
            kKeyShowGroups:                @NO,
            kKeyShowNotifications:         @NO,
            kKeyShowProfile:               @NO,
            kKeyShowMenu:                  @NO,
            kKeyHideUnknown:               @YES,

            kKeyBlockAllAds:               @YES,
            kKeyHidePeopleYouMayKnow:      @YES,
            kKeyHideReelsCarousel:         @YES,
            kKeyHideSuggestedClutter:      @YES,
            kKeyHideStoriesTray:           @NO,

            kKeyEnableMediaDownload:       @YES,
            kKeyShowMediaDownloadButton:   @NO,

            kKeyStoriesIncognitoMode:      @YES,

            kKeyStartOnMarketplace:        @YES,
            kKeyShieldHomeFeed:            @YES,
            kKeyBlockReelsEverywhere:      @YES,
            kKeyReflowVisibleTabs:         @YES,
            kKeyHideSingleTabBar:          @YES,

            kKeyTwoFingerLongPress:        @YES,
            kKeyShowFloatingGear:          @NO
        }];
    }
    return self;
}

- (uint64_t)prefsGeneration {
    return gPrefsGenCounter.load(std::memory_order_relaxed);
}

#pragma mark - Properties

#define FFB_BOOL_PROP(getter, setter, keyConst) \
- (BOOL)getter { return [_defaults boolForKey:keyConst]; } \
- (void)setter:(BOOL)val { \
    [_defaults setBool:val forKey:keyConst]; \
    gPrefsGenCounter.fetch_add(1, std::memory_order_relaxed); \
}

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

FFB_BOOL_PROP(blockAllAds, setBlockAllAds, kKeyBlockAllAds)
FFB_BOOL_PROP(hidePeopleYouMayKnow, setHidePeopleYouMayKnow, kKeyHidePeopleYouMayKnow)
FFB_BOOL_PROP(hideReelsCarousel, setHideReelsCarousel, kKeyHideReelsCarousel)
FFB_BOOL_PROP(hideSuggestedClutter, setHideSuggestedClutter, kKeyHideSuggestedClutter)
FFB_BOOL_PROP(hideStoriesTray, setHideStoriesTray, kKeyHideStoriesTray)

FFB_BOOL_PROP(enableMediaDownload, setEnableMediaDownload, kKeyEnableMediaDownload)
FFB_BOOL_PROP(showMediaDownloadButton, setShowMediaDownloadButton, kKeyShowMediaDownloadButton)

FFB_BOOL_PROP(storiesIncognitoMode, setStoriesIncognitoMode, kKeyStoriesIncognitoMode)

FFB_BOOL_PROP(startOnMarketplace, setStartOnMarketplace, kKeyStartOnMarketplace)
FFB_BOOL_PROP(shieldHomeFeed, setShieldHomeFeed, kKeyShieldHomeFeed)
FFB_BOOL_PROP(blockReelsEverywhere, setBlockReelsEverywhere, kKeyBlockReelsEverywhere)
FFB_BOOL_PROP(reflowVisibleTabs, setReflowVisibleTabs, kKeyReflowVisibleTabs)
FFB_BOOL_PROP(hideSingleTabBar, setHideSingleTabBar, kKeyHideSingleTabBar)

FFB_BOOL_PROP(twoFingerLongPressEnabled, setTwoFingerLongPressEnabled, kKeyTwoFingerLongPress)
FFB_BOOL_PROP(showFloatingGearButton, setShowFloatingGearButton, kKeyShowFloatingGear)

- (NSString *)languageCode {
    return [_defaults stringForKey:kKeyLanguageCode] ?: @"auto";
}

- (void)setLanguageCode:(NSString *)languageCode {
    [_defaults setObject:(languageCode ?: @"auto") forKey:kKeyLanguageCode];
    gPrefsGenCounter.fetch_add(1, std::memory_order_relaxed);
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
    self.hideReelsCarousel = YES;
    self.hidePeopleYouMayKnow = YES;
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
    self.hideReelsCarousel = YES;
    self.hidePeopleYouMayKnow = YES;
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
    gPrefsGenCounter.fetch_add(1, std::memory_order_relaxed);
    [self notifyChanges];
}

- (void)clearAllOverrides {
    [_defaults removeObjectForKey:kKeyCustomOverrides];
    gPrefsGenCounter.fetch_add(1, std::memory_order_relaxed);
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
    gPrefsGenCounter.fetch_add(1, std::memory_order_relaxed);
    [_defaults synchronize];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:FocusFBPreferencesDidChangeNotification
                                                            object:self];
    });
}

@end
