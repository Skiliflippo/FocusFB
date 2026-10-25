#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Installa tutti e 3 i livelli di AdBlock (Pando/GraphQL Model, JSON Edge Pruner, UI Cell Safety Net)
void FocusFBInstallAdBlocker(void);

/// Numero totale di annunci / post sponsorizzati bloccati nella sessione corrente
NSUInteger FocusFBBlockedAdsCount(void);

#ifdef __cplusplus
}
#endif
