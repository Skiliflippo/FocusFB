#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, FFBPhysicalKeyType) {
    FFBPhysicalKeyTypeNone        = 0,
    FFBPhysicalKeyTypeBarcodeOrQR = 1,
    FFBPhysicalKeyTypeNFCTag      = 2,
};

typedef NS_ENUM(NSInteger, FFBLockScope) {
    FFBLockScopeExceptMarketplace = 0, // Unico ambito v2.5+: blocca solo Feed/Reels/Social, MAI Marketplace
};

extern NSString *const FocusFBLockStateDidChangeNotification;

@interface FocusFBLockManager : NSObject

+ (instancetype)shared;

/// Avvia il monitoraggio al lancio dell'app
- (void)start;

/// Stato Blocco Rigoroso (stile Foqos)
@property (nonatomic, readonly) BOOL strictLockActive;
@property (nonatomic, readonly) FFBPhysicalKeyType keyType;
@property (nonatomic, copy, readonly, nullable) NSString *keyLabel;
@property (nonatomic, readonly) BOOL hasRegisteredKey;

/// Ambito e Configurazione Limiti di Tempo (sessionLimitMinutes: 0 = spento, -1 = sempre bloccato, >0 = minuti)
@property (nonatomic, assign) FFBLockScope lockScope;
@property (nonatomic, assign) NSInteger sessionLimitMinutes;
@property (nonatomic, assign) NSInteger cooldownMinutes;     // pausa obbligatoria post-sessione (default 30)
@property (nonatomic, assign) NSInteger dailyLimitMinutes;   // 0 = disattivato
@property (nonatomic, assign) BOOL showRemainingTimerPill;

/// Statistiche live della sessione / giornata corrente
@property (nonatomic, readonly) NSInteger sessionUsedSeconds;
@property (nonatomic, readonly) NSInteger dailyUsedSeconds;
@property (nonatomic, readonly) NSTimeInterval cooldownRemainingSeconds;
@property (nonatomic, readonly) NSTimeInterval secondsUntilMidnight;
@property (nonatomic, readonly) BOOL isSessionLockedOut;
@property (nonatomic, readonly) BOOL isDailyLockedOut;
@property (nonatomic, readonly) BOOL isQuotaExhaustedNow;
@property (nonatomic, readonly) BOOL shouldForceMarketplaceOnlyNow;
@property (nonatomic, readonly) BOOL isTimeBlockedNow;
@property (nonatomic, readonly) BOOL isLockWallVisible;

/// Sblocco di emergenza stile Foqos (massimo 3 utilizzi al mese)
@property (nonatomic, assign) BOOL emergencyUnlockEnabled;
@property (nonatomic, readonly) NSInteger emergencyUnlocksRemainingThisMonth;
@property (nonatomic, readonly) NSInteger monthlyEmergencyUnlockLimit;

/// Mette in pausa il conteggio dei secondi mentre l'utente è dentro la UI di FocusFB
@property (nonatomic, assign) BOOL pauseCountingForFocusFBUI;

/// Passa immediatamente a Marketplace chiudendo il muro di blocco (in modalità ExceptMarketplace)
- (void)switchToFreeMarketplaceFromLockWall;

/// Mostra conferma sblocco di emergenza (3 al mese) e disattiva il blocco se confermato
- (void)presentEmergencyUnlockPromptFrom:(UIViewController *)presenter
                              onUnlocked:(void (^ _Nullable)(void))onUnlocked;
- (BOOL)consumeEmergencyUnlockAndDisableLock;

/// Stringhe formattate pronte per UI
- (NSString *)formattedRemainingSummary;
- (NSString *)registeredKeyDescription;

/// Attivazione / Disattivazione Blocco Rigoroso
- (BOOL)enableStrictLockError:(NSString * _Nullable * _Nullable)errorOut;
- (void)disableStrictLockAfterVerifiedScan;

/// Registrazione Chiavi Fisiche (chiamabili da UI Impostazioni)
- (void)presentRegisterBarcodeOrQRFrom:(UIViewController *)presenter
                            completion:(void (^ _Nullable)(BOOL success))completion;

- (void)presentGenerateSecretQRFrom:(UIViewController *)presenter
                         completion:(void (^ _Nullable)(BOOL success))completion;

- (void)presentRegisterNFCTagFrom:(UIViewController *)presenter
                       completion:(void (^ _Nullable)(BOOL success))completion;

/// Scansione di verifica della chiave fisica registrata (QR/Barcode o NFC in base a keyType)
- (void)presentVerifyPhysicalKeyFrom:(UIViewController *)presenter
                              reason:(nullable NSString *)reason
                          completion:(void (^)(BOOL verified))completion;

/// Azioni post-verifica emergenza
- (void)grantEmergencyFiveMinutes;
- (void)resetTodayUsageAndCooldown;

/// Aggiorna subito finestra di blocco e pillola timer
- (void)refreshEnforcementUI;

@end

NS_ASSUME_NONNULL_END
