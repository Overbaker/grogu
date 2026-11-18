#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface QuiescenceDisabler : NSObject

/// Must be called only AFTER the test has started (post enableAutomationMode:).
+ (void)applyInteractionStateTimeout;

@end

NS_ASSUME_NONNULL_END
