//
//  ObjCException.m
//  Adapted from OpenMinis/iCTRL (Apache-2.0)
//

#import "ObjCException.h"
#import <CoreGraphics/CoreGraphics.h>
#import <XCTest/XCTest.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

@implementation ObjCException

+ (nullable NSString *)catching:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e.reason ?: e.name ?: @"unknown Obj-C exception";
    }
}

+ (nullable id)screenshotOf:(id)screen encoding:(id)encoding {
    @try {
        NSError *err = nil;
        SEL three = NSSelectorFromString(@"screenshotWithPreferredEncoding:rect:error:");
        if ([screen respondsToSelector:three]) {
            id (*fn)(id, SEL, id, CGRect, NSError **) = (id (*)(id, SEL, id, CGRect, NSError **))objc_msgSend;
            return fn(screen, three, encoding, CGRectNull, &err);
        }
        SEL four = NSSelectorFromString(@"screenshotWithPreferredEncoding:rect:options:error:");
        if ([screen respondsToSelector:four]) {
            id (*fn)(id, SEL, id, CGRect, id, NSError **) = (id (*)(id, SEL, id, CGRect, id, NSError **))objc_msgSend;
            return fn(screen, four, encoding, CGRectNull, nil, &err);
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

+ (nullable NSData *)daemonScreenshotWithEncoding:(id)encoding
                                          timeout:(double)timeout
                                              why:(NSString * _Nullable * _Nullable)why {
    @try {
        Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
        Class requestClass = NSClassFromString(@"XCTScreenshotRequest");
        SEL shared = NSSelectorFromString(@"sharedSession");
        SEL request = NSSelectorFromString(@"requestScreenshotWithRequest:withReply:");
        if (!sessionClass || !requestClass || ![sessionClass respondsToSelector:shared]) {
            if (why) { *why = @"XCTRunnerDaemonSession / XCTScreenshotRequest missing"; }
            return nil;
        }
        id session = [sessionClass performSelector:shared];
        if (![session respondsToSelector:request]) {
            if (why) { *why = @"session lacks requestScreenshotWithRequest:withReply:"; }
            return nil;
        }
        long long screenID = 1;
        @try { screenID = [[XCUIScreen.mainScreen valueForKey:@"displayID"] longLongValue]; } @catch (__unused NSException *e) {}
        id req = nil;
        SEL init4 = NSSelectorFromString(@"initWithScreenID:rect:encoding:options:");
        SEL init3 = NSSelectorFromString(@"initWithScreenID:rect:encoding:");
        if ([requestClass instancesRespondToSelector:init4]) {
            id (*f)(id, SEL, long long, CGRect, id, id) = (id (*)(id, SEL, long long, CGRect, id, id))objc_msgSend;
            req = f([requestClass alloc], init4, screenID, CGRectNull, encoding, nil);
        } else if ([requestClass instancesRespondToSelector:init3]) {
            id (*f)(id, SEL, long long, CGRect, id) = (id (*)(id, SEL, long long, CGRect, id))objc_msgSend;
            req = f([requestClass alloc], init3, screenID, CGRectNull, encoding);
        }
        if (!req) {
            if (why) { *why = @"XCTScreenshotRequest init failed"; }
            return nil;
        }
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block id image = nil;
        __block NSError *error = nil;
        void (*send)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
        send(session, request, req, ^(id img, NSError *err) {
            image = img; error = err;
            dispatch_semaphore_signal(done);
        });
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
            if (why) { *why = @"daemon screenshot timeout"; }
            return nil;
        }
        if (error || ![image respondsToSelector:@selector(data)]) {
            if (why) { *why = error.localizedDescription ?: @"reply carried no image data"; }
            return nil;
        }
        NSData *data = [image performSelector:@selector(data)];
        if (!data.length && why) { *why = @"empty image data"; }
        return data.length ? data : nil;
    } @catch (NSException *e) {
        if (why) { *why = e.reason ?: e.name; }
        return nil;
    }
}

+ (nullable id)makeImageEncoding:(Class)encodingClass
                             uti:(NSString *)uti
                         quality:(double)quality
                       diagnosis:(NSString * _Nullable * _Nullable)diagnosis {
    @try {
        SEL initSel = NSSelectorFromString(@"initWithUniformTypeIdentifier:compressionQuality:");
        if (!encodingClass || ![encodingClass instancesRespondToSelector:initSel]) {
            if (diagnosis) { *diagnosis = @"initWithUniformTypeIdentifier:compressionQuality: missing"; }
            return nil;
        }
        id (*fn)(id, SEL, id, double) = (id (*)(id, SEL, id, double))objc_msgSend;
        return fn([encodingClass alloc], initSel, uti, quality);
    } @catch (NSException *e) {
        if (diagnosis) { *diagnosis = e.reason ?: e.name; }
        return nil;
    }
}

@end
