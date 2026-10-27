#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installa i moduli Storie (Modalità Incognito senza conferma lettura + Blocco avanzamento automatico)
void FocusFBInstallStoriesManager(void);

/// Notifica l'apertura di un UIViewController per attivare pigramente gli hook FBSnacks solo quando serve
void FocusFBNotifyStoryCandidateController(UIViewController * _Nullable vc);

/// Restituisce YES se la richiesta HTTP/GraphQL è una mutazione di "visto" delle Storie da bloccare
BOOL FocusFBIsStorySeenNetworkRequest(NSURLRequest * _Nullable request);

/// Restituisce YES se il visualizzatore Storie (FBSnacks / StoriesViewer) è attualmente visibile
BOOL FocusFBIsStoryViewerVisibleNow(void);

/// Timestamp CFAbsoluteTimeGetCurrent() dell'ultimo tocco utente sullo schermo
double FocusFBLastUserTouchTimestamp(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
