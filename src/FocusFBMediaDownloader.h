#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installa il sistema di download media (pressione prolungata + pulsante rapido su Reels/Video/Storie)
void FocusFBInstallMediaDownloader(void);

/// Aggiorna visibilità della scorciatoia su finestra e del pulsante download rapido
void FocusFBMediaDownloaderSyncUI(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
