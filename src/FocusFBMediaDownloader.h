#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installa il downloader nativo per i Reels (icona in stile Facebook sopra il tasto Mi piace)
void FocusFBInstallMediaDownloader(void);

/// Sincronizza o rimuove i pulsanti download nei Reels visibili
void FocusFBMediaDownloaderSyncUI(void);

/// Notifica la comparsa di un controller (es. ingresso nella tab Reels o player full-screen)
void FocusFBNotifyMediaControllerTransition(UIViewController * _Nullable vc);

/// Chiamato dal layout delle UIScrollView/UICollectionView paginate dei Reels per agganciare ogni pagina
void FocusFBMediaDownloaderOnScrollLayout(UIScrollView * _Nullable scrollView);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
