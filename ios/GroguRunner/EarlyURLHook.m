//
//  EarlyURLHook.m
//  Adapted from OpenMinis/iCTRL (Apache-2.0)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSMutableArray<NSURL *> *sEarlyURLs;
static NSMutableArray<NSString *> *sEarlyLogs;
static NSLock *sEarlyLock;

static BOOL sTestStarted = NO;
static BOOL sSetUpEntered = NO;
static BOOL sEarlyBackgroundArmed = NO;
static BOOL sPollArmed = NO;

@interface EarlyURLHook : NSObject
+ (NSArray<NSURL *> *)drainURLs;
+ (NSArray<NSString *> *)drainLogs;
+ (void)hookDelegateInstance:(id<UIApplicationDelegate>)delegate;
+ (void)tryInstall;
+ (void)hookClass:(Class)cls;
+ (void)markTestStarted;
+ (void)markSetUpEntered;
+ (void)armBootstrapObserver;
+ (void)armEarlyBackgrounding;
@end

static void earlyLog(NSString *msg) {
    NSLog(@"%@", msg);
    [sEarlyLock lock];
    if (sEarlyLogs) { [sEarlyLogs addObject:msg]; }
    [sEarlyLock unlock];
}

static void stashURL(NSURL *url) {
    if (![[url.scheme lowercaseString] isEqualToString:@"grogu-runner"]) { return; }
    [sEarlyLock lock];
    [sEarlyURLs addObject:url];
    [sEarlyLock unlock];
    earlyLog([NSString stringWithFormat:@"[GroguRunner] early-captured URL %@://%@", url.scheme, url.host ?: @""]);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"GroguRunnerReceivedURL" object:url];
    });
}

static BOOL hookedDidFinishLaunching(id self, SEL _cmd, id application, NSDictionary *options) {
    NSURL *url = options[UIApplicationLaunchOptionsURLKey];
    if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
    [EarlyURLHook armBootstrapObserver];
    SEL orig = NSSelectorFromString(@"groguearly_application:didFinishLaunchingWithOptions:");
    if ([self respondsToSelector:orig]) {
        BOOL (*imp)(id, SEL, id, NSDictionary *) = (BOOL (*)(id, SEL, id, NSDictionary *))[self methodForSelector:orig];
        return imp(self, orig, application, options);
    }
    return YES;
}

static BOOL hookedOpenURL(id self, SEL _cmd, id application, NSURL *url, NSDictionary *options) {
    if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
    SEL orig = NSSelectorFromString(@"groguearly_application:openURL:options:");
    if ([self respondsToSelector:orig]) {
        BOOL (*imp)(id, SEL, id, NSURL *, NSDictionary *) = (BOOL (*)(id, SEL, id, NSURL *, NSDictionary *))[self methodForSelector:orig];
        return imp(self, orig, application, url, options);
    }
    return YES;
}

static void hookedSceneOpenURLContexts(id self, SEL _cmd, id scene, NSSet *contexts) {
    for (id ctx in contexts) {
        if ([ctx respondsToSelector:@selector(URL)]) {
            NSURL *url = [ctx performSelector:@selector(URL)];
            if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
        }
    }
    SEL orig = NSSelectorFromString(@"groguearly_scene:openURLContexts:");
    if ([self respondsToSelector:orig]) {
        void (*imp)(id, SEL, id, NSSet *) = (void (*)(id, SEL, id, NSSet *))[self methodForSelector:orig];
        imp(self, orig, scene, contexts);
    }
}

static void hookedSceneWillConnect(id self, SEL _cmd, id scene, id session, id connectionOptions) {
    NSSet *urlContexts = nil;
    if ([connectionOptions respondsToSelector:@selector(URLContexts)]) {
        urlContexts = [connectionOptions performSelector:@selector(URLContexts)];
    }
    for (id ctx in urlContexts) {
        if ([ctx respondsToSelector:@selector(URL)]) {
            NSURL *url = [ctx performSelector:@selector(URL)];
            if ([url isKindOfClass:[NSURL class]]) { stashURL(url); }
        }
    }
    [EarlyURLHook armBootstrapObserver];
    SEL orig = NSSelectorFromString(@"groguearly_scene:willConnectToSession:options:");
    if ([self respondsToSelector:orig]) {
        void (*imp)(id, SEL, id, id, id) = (void (*)(id, SEL, id, id, id))[self methodForSelector:orig];
        imp(self, orig, scene, session, connectionOptions);
    }
}

static void (*original_setDelegate)(id, SEL, id<UIApplicationDelegate>);
static void swizzled_setDelegate(id self, SEL _cmd, id<UIApplicationDelegate> delegate) {
    if (delegate) {
        [EarlyURLHook hookDelegateInstance:delegate];
    }
    if (original_setDelegate) { original_setDelegate(self, _cmd, delegate); }
}

@implementation EarlyURLHook

+ (void)load {
    sEarlyURLs = [NSMutableArray array];
    sEarlyLogs = [NSMutableArray array];
    sEarlyLock = [[NSLock alloc] init];

    Method m = class_getInstanceMethod([UIApplication class], @selector(setDelegate:));
    if (m) {
        original_setDelegate = (void (*)(id, SEL, id<UIApplicationDelegate>))method_getImplementation(m);
        method_setImplementation(m, (IMP)swizzled_setDelegate);
    }

    [self tryInstall];
    dispatch_async(dispatch_get_main_queue(), ^{ [EarlyURLHook tryInstall]; });
    [self armBootstrapObserver];
    [self armEarlyBackgrounding];
}

+ (BOOL)isCoveredBySystemPrompt {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundInactive) {
            return YES;
        }
    }
    return NO;
}

+ (void)armEarlyBackgrounding {
    if (sEarlyBackgroundArmed) { return; }
    sEarlyBackgroundArmed = YES;
    [self attemptEarlyBackgroundingWithRetriesRemaining:40];
}

+ (void)attemptEarlyBackgroundingWithRetriesRemaining:(NSInteger)retries {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (sSetUpEntered || sTestStarted) { return; }
        if ([self isCoveredBySystemPrompt]) {
            if (retries > 0) { [self attemptEarlyBackgroundingWithRetriesRemaining:retries - 1]; }
            return;
        }
        static int lockToken = -1;
        uint64_t lockState = 0;
        if (lockToken == -1 &&
            notify_register_check("com.apple.springboard.lockstate", &lockToken) != NOTIFY_STATUS_OK) {
            lockToken = -2;
        }
        if (lockToken >= 0 && notify_get_state(lockToken, &lockState) == NOTIFY_STATUS_OK && lockState != 0) {
            if (retries > 0) { [self attemptEarlyBackgroundingWithRetriesRemaining:retries - 1]; }
            return;
        }
        UIApplication *app = UIApplication.sharedApplication;
        SEL sus = NSSelectorFromString(@"suspend");
        if (![app respondsToSelector:sus]) { return; }
        @try {
            ((void (*)(id, SEL))objc_msgSend)(app, sus);
        } @catch (__unused NSException *e) {}
    });
}

+ (void)armBootstrapObserver {
    if (sPollArmed) { return; }
    sPollArmed = YES;
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        if (sTestStarted || sSetUpEntered) { return; }
        earlyLog(@"[GroguRunner] didBecomeActive before setUp");
    }];
}

+ (void)hookDelegateInstance:(id<UIApplicationDelegate>)delegate {
    Class cls = object_getClass(delegate);
    if (cls) { [self hookClass:cls]; }
}

static BOOL sInstalled = NO;

+ (void)tryInstall {
    if (sInstalled) { return; }
    Class cls = NSClassFromString(@"_XCTRunnerAppDelegate");
    if (cls) { [self hookClass:cls]; }
}

+ (void)hookClass:(Class)cls {
    if (sInstalled) { return; }
    sInstalled = YES;

    SEL dfl = NSSelectorFromString(@"application:didFinishLaunchingWithOptions:");
    if (!class_addMethod(cls, dfl, (IMP)hookedDidFinishLaunching, "B@:@@")) {
        SEL tmp = NSSelectorFromString(@"groguearly_application:didFinishLaunchingWithOptions:");
        if (class_addMethod(cls, tmp, (IMP)hookedDidFinishLaunching, "B@:@@")) {
            Method a = class_getInstanceMethod(cls, dfl);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    SEL ou = NSSelectorFromString(@"application:openURL:options:");
    if (!class_addMethod(cls, ou, (IMP)hookedOpenURL, "B@:@@@")) {
        SEL tmp = NSSelectorFromString(@"groguearly_application:openURL:options:");
        if (class_addMethod(cls, tmp, (IMP)hookedOpenURL, "B@:@@@")) {
            Method a = class_getInstanceMethod(cls, ou);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    SEL sou = NSSelectorFromString(@"scene:openURLContexts:");
    if (!class_addMethod(cls, sou, (IMP)hookedSceneOpenURLContexts, "v@:@@")) {
        SEL tmp = NSSelectorFromString(@"groguearly_scene:openURLContexts:");
        if (class_addMethod(cls, tmp, (IMP)hookedSceneOpenURLContexts, "v@:@@")) {
            Method a = class_getInstanceMethod(cls, sou);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }

    SEL swc = NSSelectorFromString(@"scene:willConnectToSession:options:");
    if (!class_addMethod(cls, swc, (IMP)hookedSceneWillConnect, "v@:@@@")) {
        SEL tmp = NSSelectorFromString(@"groguearly_scene:willConnectToSession:options:");
        if (class_addMethod(cls, tmp, (IMP)hookedSceneWillConnect, "v@:@@@")) {
            Method a = class_getInstanceMethod(cls, swc);
            Method b = class_getInstanceMethod(cls, tmp);
            if (a && b) { method_exchangeImplementations(a, b); }
        }
    }
}

+ (void)markTestStarted {
    sTestStarted = YES;
}

+ (void)markSetUpEntered {
    sSetUpEntered = YES;
}

+ (NSArray<NSURL *> *)drainURLs {
    [sEarlyLock lock];
    NSArray *urls = [sEarlyURLs copy];
    [sEarlyURLs removeAllObjects];
    [sEarlyLock unlock];
    return urls;
}

+ (NSArray<NSString *> *)drainLogs {
    [sEarlyLock lock];
    NSArray *logs = [sEarlyLogs copy];
    [sEarlyLogs removeAllObjects];
    [sEarlyLock unlock];
    return logs;
}

@end
