#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installa il modulo Storie in Incognito (nessuna conferma di lettura inviata)
void FocusFBInstallStoriesManager(void);

/// Notifica l'apertura di un UIViewController per agganciare pigramente i manager SeenState di FBSnacks
void FocusFBNotifyStoryCandidateController(UIViewController * _Nullable vc);

/// Restituisce YES se la richiesta HTTP/GraphQL è una mutazione di "visto" delle Storie da bloccare
BOOL FocusFBIsStorySeenNetworkRequest(NSURLRequest * _Nullable request);

/// Restituisce YES se il visualizzatore Storie full-screen (FBSnacks / StoriesViewer) è attualmente visibile
BOOL FocusFBIsStoryViewerVisibleNow(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
