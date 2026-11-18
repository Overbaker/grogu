#ifndef GroguRunner_Bridging_Header_h
#define GroguRunner_Bridging_Header_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>

#import "LockStateMonitor.h"
#import "ForegroundApp.h"
#import "QuiescenceDisabler.h"
#import "ObjCException.h"

@interface EarlyURLHook : NSObject
+ (NSArray<NSURL *> *)drainURLs;
+ (NSArray<NSString *> *)drainLogs;
+ (void)markTestStarted;
+ (void)markSetUpEntered;
@end

NS_ASSUME_NONNULL_BEGIN

@class XCPointerEventPath;

@interface XCSynthesizedEventRecord : NSObject
- (instancetype)initWithName:(NSString *)name;
- (void)addPointerEventPath:(XCPointerEventPath *)eventPath;
- (BOOL)synthesizeWithError:(NSError * _Nullable * _Nullable)error;
@end

@interface XCPointerEventPath : NSObject
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(NSTimeInterval)offset;
- (void)pressDownAtOffset:(NSTimeInterval)offset;
- (void)liftUpAtOffset:(NSTimeInterval)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset;
- (instancetype)initForTextInput;
- (void)typeText:(NSString *)text
        atOffset:(NSTimeInterval)offset
     typingSpeed:(NSUInteger)typingSpeed
    shouldRedact:(BOOL)shouldRedact;
@end

@interface XCUIDevice (GroguPrivate)
- (void)pressLockButton;
@end

@protocol XCTImageEncoding <NSObject>
@end

@interface XCTImage : NSObject
- (UIImage * _Nullable)platformImage;
- (NSData * _Nullable)data;
- (id<XCTImageEncoding> _Nullable)encoding;
@end

@interface XCUIScreenshot (GroguPrivate)
- (XCTImage * _Nullable)internalImage;
@end

@interface XCUIScreen (GroguPrivate)
- (XCUIScreenshot * _Nullable)screenshotWithPreferredEncoding:(id<XCTImageEncoding>)encoding
                                                         rect:(CGRect)rect
                                                      options:(NSDictionary * _Nullable)options
                                                        error:(NSError * _Nullable * _Nullable)error;
- (XCUIScreenshot * _Nullable)screenshotWithPreferredEncoding:(id<XCTImageEncoding>)encoding
                                                         rect:(CGRect)rect
                                                        error:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END

#endif
