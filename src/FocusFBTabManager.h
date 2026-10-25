#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

void FocusFBStartEngine(void);
void FocusFBRefreshUIImmediately(void);
void FocusFBNavigateToMarketplace(BOOL allowDeepLinkFallback);
void FocusFBForceSwitchToMarketplaceNow(void);
BOOL FocusFBIsUserCurrentlyInMarketplace(void);
void FocusFBShowToast(NSString *message, NSString *sfSymbolName);
UIWindow * _Nullable FocusFBActiveWindow(void);
UIViewController * _Nullable FocusFBTopMostViewController(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
