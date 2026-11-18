//
//  XCTCompatShim.m
//  Adapted from OpenMinis/iCTRL (Apache-2.0)
//

#import <Foundation/Foundation.h>

@interface XCTCommandLineToolHelper : NSObject
@end

@implementation XCTCommandLineToolHelper

+ (id)configurationFromCommandLineArguments:(id)arguments
                               userDefaults:(id)userDefaults
                      requiresTestBundleURL:(BOOL)requiresTestBundleURL
                                   outError:(NSError **)outError {
    NSLog(@"[GroguRunner] XCTCommandLineToolHelper shim invoked unexpectedly; returning nil.");
    if (outError) { *outError = nil; }
    return nil;
}

+ (void)exitWithMessage:(id)message usage:(id)usage {
    NSLog(@"[GroguRunner] XCTCommandLineToolHelper shim exitWithMessage: %@ (usage: %@)", message, usage);
}

@end
