#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCException : NSObject

+ (nullable NSString *)catching:(NS_NOESCAPE void (^)(void))block;

+ (nullable id)screenshotOf:(id)screen encoding:(id)encoding;

+ (nullable NSData *)daemonScreenshotWithEncoding:(id)encoding
                                          timeout:(double)timeout
                                              why:(NSString * _Nullable * _Nullable)why;

+ (nullable id)makeImageEncoding:(Class)encodingClass
                             uti:(NSString *)uti
                         quality:(double)quality
                       diagnosis:(NSString * _Nullable * _Nullable)diagnosis;

@end

NS_ASSUME_NONNULL_END
