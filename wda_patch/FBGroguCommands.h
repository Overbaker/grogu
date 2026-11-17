#import <Foundation/Foundation.h>
#import <WebDriverAgentLib/FBCommandHandler.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Custom ultra-low-latency WebDriverAgent endpoints for Grogu:
 *   - GET  /grogu/fast_tree : Lightweight accessibility snapshot without quiescence waits
 *   - POST /grogu/reflex    : On-device rule polling + XCSynthesizeEventRecord tap (zero network RTT)
 */
@interface FBGroguCommands : NSObject <FBCommandHandler>

@end

NS_ASSUME_NONNULL_END
