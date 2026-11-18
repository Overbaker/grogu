#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Safe Obj-C bridge around private XCTest / MobileCoreServices APIs.
/// Adapted from OpenMinis/iCTRL (Apache-2.0).
@interface ForegroundApp : NSObject

+ (nullable NSString *)currentBundleID;
+ (pid_t)frontmostPID;
+ (double)setAXTimeout:(double)seconds;
+ (pid_t)processIDForBundleID:(NSString *)bundleId;

+ (nullable NSArray<NSDictionary *> *)installedAppsUserOnly:(BOOL)userOnly;
+ (BOOL)openBundleID:(NSString *)bundleId;
+ (BOOL)openURL:(NSURL *)url;
+ (BOOL)safeActivateBundleID:(NSString *)bundleId;
+ (BOOL)activateOrLaunchBundleID:(NSString *)bundleId;
+ (BOOL)safeTerminateBundleID:(NSString *)bundleId;

/// 0 = unknown, 1 = notRunning, 2 = backgroundSuspended, 3 = background, 4 = foreground.
+ (NSInteger)appStateForBundleID:(NSString *)bundleId;
+ (nullable NSString *)safeLabelForBundleID:(NSString *)bundleId;
+ (BOOL)hasSystemAlert;

+ (nullable id)safeSnapshotOfElement:(id)element;
+ (BOOL)safeBoolProperty:(NSString *)name ofElement:(id)element fallback:(BOOL)fallback;
+ (NSInteger)boolPropertyState:(NSString *)name
                     ofElement:(id)element
                        reason:(NSString * _Nullable * _Nullable)outReason;

+ (nullable id)boundedSnapshotForBundleID:(NSString *)bundleId
                                 maxDepth:(NSInteger)maxDepth
                              maxChildren:(NSInteger)maxChildren;

+ (nullable NSDictionary *)visibleListParts:(NSString *)bundleId
                                     screen:(CGRect)screen
                                maxElements:(NSInteger)maxElements;

+ (nullable NSDictionary *)locateInBoundedSnapshot:(id)root
                                             query:(NSString *)query
                                          contains:(BOOL)contains
                                             types:(nullable NSArray<NSNumber *> *)types
                                          viewport:(CGRect)viewport
                                          maxDepth:(NSInteger)maxDepth;

+ (nullable NSString *)renderBoundedSnapshot:(id)root
                                    maxDepth:(NSInteger)maxDepth
                                 maxElements:(NSInteger)maxElements
                                 visibleRect:(CGRect)visibleRect
                                nodesWritten:(NSInteger * _Nullable)outCount
                                   truncated:(BOOL * _Nullable)outTruncated;

@end

NS_ASSUME_NONNULL_END
