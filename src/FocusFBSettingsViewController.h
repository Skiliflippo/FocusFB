#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FocusFBSettingsViewController : UIViewController

+ (void)presentFromTopMostController;
+ (void)presentPreUnlockedFromTopController;
+ (void)presentWelcomeIfNeeded;

@end

NS_ASSUME_NONNULL_END
