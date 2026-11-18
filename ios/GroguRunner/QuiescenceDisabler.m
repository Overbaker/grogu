//
//  QuiescenceDisabler.m
//  Adapted from OpenMinis/iCTRL (Apache-2.0)
//

#import "QuiescenceDisabler.h"
#import <objc/runtime.h>

extern void _XCTSetApplicationStateTimeout(NSTimeInterval timeout) __attribute__((weak_import));

@implementation QuiescenceDisabler

static const NSTimeInterval kInteractionStateTimeout = 2.0;

static void noopQuiescence(id self, SEL _cmd, BOOL includingAnimations) {}
static void noopQuiescencePreEvent(id self, SEL _cmd, BOOL includingAnimations, BOOL isPreEvent) {}

+ (void)load {
    Class cls = NSClassFromString(@"XCUIApplicationProcess");
    if (!cls) { return; }

    SEL sel1 = NSSelectorFromString(@"waitForQuiescenceIncludingAnimationsIdle:");
    Method m1 = class_getInstanceMethod(cls, sel1);
    if (m1) {
        method_setImplementation(m1, (IMP)noopQuiescence);
        NSLog(@"[GroguRunner] quiescence wait disabled (waitForQuiescenceIncludingAnimationsIdle:)");
        return;
    }

    SEL sel2 = NSSelectorFromString(@"waitForQuiescenceIncludingAnimationsIdle:isPreEvent:");
    Method m2 = class_getInstanceMethod(cls, sel2);
    if (m2) {
        method_setImplementation(m2, (IMP)noopQuiescencePreEvent);
        NSLog(@"[GroguRunner] quiescence wait disabled (waitForQuiescenceIncludingAnimationsIdle:isPreEvent:)");
    }
}

+ (void)applyInteractionStateTimeout {
    if (_XCTSetApplicationStateTimeout == NULL) { return; }
    _XCTSetApplicationStateTimeout(kInteractionStateTimeout);
    NSLog(@"[GroguRunner] XCTest application-state timeout capped at %.0fs (post-bootstrap)", kInteractionStateTimeout);
}

@end
