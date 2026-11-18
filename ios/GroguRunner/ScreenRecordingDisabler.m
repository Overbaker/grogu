//
//  ScreenRecordingDisabler.m
//  Adapted from OpenMinis/iCTRL (Apache-2.0)
//

#import <Foundation/Foundation.h>

@interface ScreenRecordingDisabler : NSObject
@end

@implementation ScreenRecordingDisabler

+ (void)load {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        @"DisableDiagnosticScreenRecordings": @YES,
        @"DisableDiagnosticScreenshots": @YES,
    }];
}

@end
