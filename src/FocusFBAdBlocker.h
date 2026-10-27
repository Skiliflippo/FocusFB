#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Installa i filtri AdBlock & Pulizia Feed post-avvio (RCTNetworking, Pando/FBTree, GraphQL JSON)
void FocusFBInstallAdBlocker(void);

/// Riprova pigramente l'aggancio a RCTNetworking / Pando se caricati dopo l'apertura di un tab
void FocusFBRetryLazyAdHooksIfNeeded(void);

/// Numero totale di annunci / post sponsorizzati bloccati nella sessione corrente
NSUInteger FocusFBBlockedAdsCount(void);

#ifdef __cplusplus
}
#endif
