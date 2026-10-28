#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installa il downloader per Video, Reels e Storie Video (integrato nel menu Condividi di Facebook)
void FocusFBInstallMediaDownloader(void);

/// Aggiorna il pulsante "Scarica video" nel menu Condividi / Opzioni e l'eventuale icona rapida
void FocusFBMediaDownloaderSyncUI(void);

/// Notifica la comparsa imminente o completata di un UIViewController (es. menu Condividi / BottomSheet)
void FocusFBNotifyMediaControllerTransition(UIViewController * _Nullable vc);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
