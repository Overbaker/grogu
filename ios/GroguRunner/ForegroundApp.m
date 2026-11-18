//
//  ForegroundApp.m
//  Adapted from OpenMinis/iCTRL (Apache-2.0)
//

#include <errno.h>
#include <signal.h>
#import "ForegroundApp.h"
#import <XCTest/XCTest.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

@interface XCAXClient_iOS : NSObject
+ (instancetype)sharedClient;
- (id)activeApplications;
@end

@interface XCTRunnerDaemonSession : NSObject
+ (instancetype)sharedSession;
- (void)openDefaultApplicationForURL:(NSURL *)url completion:(void (^)(BOOL result, NSError *error))completion;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
- (NSArray *)allInstalledApplications;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleId;
- (BOOL)openURL:(id)url;
- (BOOL)openSensitiveURL:(id)url withOptions:(id)options;
@end

@interface LSApplicationProxy : NSObject
@property (nonatomic, readonly) NSString *applicationIdentifier;
@property (nonatomic, readonly) NSString *localizedName;
@property (nonatomic, readonly) NSString *applicationType;
@end

@implementation ForegroundApp

+ (nullable id)axInterface {
    @try {
        Class deviceClass = NSClassFromString(@"XCUIDevice");
        SEL sharedSel = NSSelectorFromString(@"sharedDevice");
        SEL ifaceSel = NSSelectorFromString(@"accessibilityInterface");
        if ([deviceClass respondsToSelector:sharedSel]) {
            id device = [deviceClass performSelector:sharedSel];
            if ([device respondsToSelector:ifaceSel]) {
                id iface = [device performSelector:ifaceSel];
                if (iface) { return iface; }
            }
        }
        Class clientClass = NSClassFromString(@"XCAXClient_iOS");
        SEL legacySel = NSSelectorFromString(@"sharedClient");
        if (clientClass && [clientClass respondsToSelector:legacySel]) {
            return [clientClass performSelector:legacySel];
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

+ (double)setAXTimeout:(double)seconds {
    @try {
        id client = [self axInterface];
        if (!client) { return -1; }
        double previous = -1;
        SEL getSel = NSSelectorFromString(@"AXTimeout");
        if ([client respondsToSelector:getSel]) {
            double (*getFn)(id, SEL) = (double (*)(id, SEL))objc_msgSend;
            previous = getFn(client, getSel);
        }
        SEL setSel = NSSelectorFromString(@"_setAXTimeout:error:");
        if ([client respondsToSelector:setSel]) {
            NSError *err = nil;
            BOOL (*setFn)(id, SEL, double, NSError **) = (BOOL (*)(id, SEL, double, NSError **))objc_msgSend;
            if (!setFn(client, setSel, seconds, &err)) { return -2; }
            return previous;
        }
        SEL plainSel = NSSelectorFromString(@"setAXTimeout:");
        if ([client respondsToSelector:plainSel]) {
            void (*fn)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
            fn(client, plainSel, seconds);
            return previous;
        }
        return -1;
    } @catch (__unused NSException *e) {
        return -3;
    }
}

+ (pid_t)frontmostPID {
    @try {
        id client = [self axInterface];
        if (!client) { return 0; }
        SEL sel = NSSelectorFromString(@"activeApplications");
        if (![client respondsToSelector:sel]) { return 0; }
        NSArray *apps = [client performSelector:sel];
        if (![apps isKindOfClass:[NSArray class]] || apps.count == 0) { return 0; }

        id element = apps.firstObject;
        SEL pidSel = NSSelectorFromString(@"processIdentifier");
        for (id a in apps) {
            if (![a respondsToSelector:pidSel]) { continue; }
            pid_t p = [[a valueForKey:@"processIdentifier"] intValue];
            if (p > 0 && (kill(p, 0) == 0 || errno != ESRCH)) { element = a; break; }
        }
        if (![element respondsToSelector:pidSel]) { return 0; }
        NSMethodSignature *sig = [element methodSignatureForSelector:pidSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.selector = pidSel;
        [inv invokeWithTarget:element];
        pid_t pid = 0;
        [inv getReturnValue:&pid];
        return pid;
    } @catch (__unused NSException *e) {
        return 0;
    }
}

+ (pid_t)processIDForBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return 0; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return 0; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        SEL pidSel = NSSelectorFromString(@"processID");
        if (!app || ![app respondsToSelector:pidSel]) { return 0; }
        pid_t (*pidFn)(id, SEL) = (pid_t (*)(id, SEL))objc_msgSend;
        return pidFn(app, pidSel);
    } @catch (__unused NSException *e) {
        return 0;
    }
}

+ (nullable NSString *)currentBundleID {
    @try {
        id client = [self axInterface];
        if (!client) { return nil; }
        SEL sel = NSSelectorFromString(@"activeApplications");
        if (![client respondsToSelector:sel]) { return nil; }
        NSArray *apps = [client performSelector:sel];
        if (![apps isKindOfClass:[NSArray class]] || apps.count == 0) { return nil; }

        NSString *springboard = nil;
        for (id element in apps) {
            NSString *bid = [self bundleIDForElement:element];
            if (bid.length == 0) { continue; }
            if ([bid isEqualToString:@"com.apple.springboard"]) { springboard = bid; continue; }
            NSInteger state = [self appStateForBundleID:bid];
            if (state == 4 || state == 0) { return bid; }
        }
        if (springboard) { return springboard; }
        return [self bundleIDForElement:apps.firstObject];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

+ (nullable NSString *)bundleIDForElement:(id)element {
    @try {
        for (NSString *name in @[@"bundleIdentifier", @"bundleID"]) {
            SEL s = NSSelectorFromString(name);
            if ([element respondsToSelector:s]) {
                id v = [element performSelector:s];
                if ([v isKindOfClass:[NSString class]] && [v length] > 0) { return v; }
            }
        }
        SEL pidSel = NSSelectorFromString(@"processIdentifier");
        if ([element respondsToSelector:pidSel]) {
            NSMethodSignature *sig = [element methodSignatureForSelector:pidSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.selector = pidSel;
            [inv invokeWithTarget:element];
            pid_t pid = 0;
            [inv getReturnValue:&pid];
            if (pid > 0) { return [self bundleIDForPID:pid]; }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

+ (nullable NSString *)bundleIDForPID:(pid_t)pid {
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        SEL initSel = NSSelectorFromString(@"initWithProcessID:");
        if (appClass && [appClass instancesRespondToSelector:initSel]) {
            id app = [appClass alloc];
            NSMethodSignature *sig = [app methodSignatureForSelector:initSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.selector = initSel;
            [inv setArgument:&pid atIndex:2];
            [inv invokeWithTarget:app];
            void *result = NULL;
            [inv getReturnValue:&result];
            id appInstance = (__bridge id)result;
            SEL bidSel = NSSelectorFromString(@"bundleID");
            if ([appInstance respondsToSelector:bidSel]) {
                id bid = [appInstance performSelector:bidSel];
                if ([bid isKindOfClass:[NSString class]]) { return bid; }
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

+ (nullable NSArray<NSDictionary *> *)installedAppsUserOnly:(BOOL)userOnly {
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) { return nil; }
        id ws = [wsClass performSelector:@selector(defaultWorkspace)];
        if (!ws) { return nil; }

        NSArray *apps = nil;
        if ([ws respondsToSelector:@selector(allApplications)]) {
            apps = [ws performSelector:@selector(allApplications)];
        }
        if ((![apps isKindOfClass:[NSArray class]] || apps.count == 0) &&
            [ws respondsToSelector:@selector(allInstalledApplications)]) {
            apps = [ws performSelector:@selector(allInstalledApplications)];
        }
        if (![apps isKindOfClass:[NSArray class]]) { return nil; }

        NSMutableArray *out = [NSMutableArray array];
        for (id proxy in apps) {
            @try {
                NSString *bid = [proxy respondsToSelector:@selector(applicationIdentifier)]
                    ? [proxy performSelector:@selector(applicationIdentifier)] : nil;
                NSString *name = [proxy respondsToSelector:@selector(localizedName)]
                    ? [proxy performSelector:@selector(localizedName)] : nil;
                NSString *type = [proxy respondsToSelector:@selector(applicationType)]
                    ? [proxy performSelector:@selector(applicationType)] : nil;
                if (bid.length == 0) { continue; }
                if (userOnly && type && ![type isEqualToString:@"User"]) { continue; }
                [out addObject:@{
                    @"bundle_id": bid ?: @"",
                    @"name": name ?: @"",
                    @"type": type ?: @"",
                }];
            } @catch (__unused NSException *e) {}
        }
        [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
        return out;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

+ (BOOL)activateOrLaunchBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return NO; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return NO; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        if (!app) { return NO; }
        BOOL running = NO;
        if ([app respondsToSelector:@selector(running)]) {
            BOOL (*runningFn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
            running = runningFn(app, @selector(running));
        }
        SEL sel = running ? @selector(activate) : @selector(launch);
        if ([app respondsToSelector:sel]) {
            [app performSelector:sel];
            return YES;
        }
        return NO;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (BOOL)safeActivateBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return NO; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return NO; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        if (!app) { return NO; }
        if ([app respondsToSelector:@selector(activate)]) {
            [app performSelector:@selector(activate)];
        }
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (BOOL)safeTerminateBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return NO; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return NO; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        if (!app) { return NO; }
        if ([app respondsToSelector:@selector(terminate)]) {
            [app performSelector:@selector(terminate)];
        }
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (NSInteger)appStateForBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return 0; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return 0; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        if (!app || ![app respondsToSelector:@selector(state)]) { return 0; }
        NSInteger (*stateFn)(id, SEL) = (NSInteger (*)(id, SEL))objc_msgSend;
        return stateFn(app, @selector(state));
    } @catch (__unused NSException *e) {
        return 0;
    }
}

+ (nullable NSString *)safeLabelForBundleID:(NSString *)bundleId {
    if (bundleId.length == 0) { return nil; }
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return nil; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id app = initFn([appClass alloc], @selector(initWithBundleIdentifier:), bundleId);
        if (!app || ![app respondsToSelector:@selector(label)]) { return nil; }
        id label = [app performSelector:@selector(label)];
        return ([label isKindOfClass:[NSString class]] && [label length] > 0) ? label : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

+ (BOOL)hasSystemAlert {
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return NO; }
        id (*initFn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id sb = initFn([appClass alloc], @selector(initWithBundleIdentifier:), @"com.apple.springboard");
        if (!sb) { return NO; }
        id alerts = [sb performSelector:@selector(alerts)];
        if (alerts && [alerts respondsToSelector:@selector(count)]) {
            NSUInteger (*countFn)(id, SEL) = (NSUInteger (*)(id, SEL))objc_msgSend;
            return countFn(alerts, @selector(count)) > 0;
        }
        return NO;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (BOOL)openURL:(NSURL *)url {
    @try {
        Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
        if (sessionClass) {
            id session = [sessionClass performSelector:@selector(sharedSession)];
            SEL sel = @selector(openDefaultApplicationForURL:completion:);
            if (session && [session respondsToSelector:sel]) {
                __block BOOL ok = NO;
                dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                [session openDefaultApplicationForURL:url completion:^(BOOL result, NSError *err) {
                    ok = result && (err == nil);
                    dispatch_semaphore_signal(sem);
                }];
                dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
                if (ok) { return YES; }
            }
        }
    } @catch (__unused NSException *e) {}

    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) { return NO; }
        id ws = [wsClass performSelector:@selector(defaultWorkspace)];
        if (!ws) { return NO; }
        if ([ws respondsToSelector:@selector(openSensitiveURL:withOptions:)]) {
            BOOL (*fn)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))objc_msgSend;
            if (fn(ws, @selector(openSensitiveURL:withOptions:), url, nil)) { return YES; }
        }
        if ([ws respondsToSelector:@selector(openURL:)]) {
            BOOL (*fn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
            return fn(ws, @selector(openURL:), url);
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

+ (BOOL)openBundleID:(NSString *)bundleId {
    @try {
        Class wsClass = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsClass) { return NO; }
        id ws = [wsClass performSelector:@selector(defaultWorkspace)];
        if (![ws respondsToSelector:@selector(openApplicationWithBundleID:)]) { return NO; }
        BOOL (*openFn)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
        return openFn(ws, @selector(openApplicationWithBundleID:), bundleId);
    } @catch (__unused NSException *e) {
        return NO;
    }
}

+ (nullable id)safeSnapshotOfElement:(id)element {
    if (!element) { return nil; }
    @try {
        SEL sel = NSSelectorFromString(@"snapshotWithError:");
        if (![element respondsToSelector:sel]) { return nil; }
        NSError *err = nil;
        id (*fn)(id, SEL, NSError **) = (id (*)(id, SEL, NSError **))objc_msgSend;
        id snap = fn(element, sel, &err);
        return err ? nil : snap;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

+ (BOOL)safeBoolProperty:(NSString *)name ofElement:(id)element fallback:(BOOL)fallback {
    if (!element) { return fallback; }
    @try {
        SEL sel = NSSelectorFromString(name);
        if (![element respondsToSelector:sel]) { return fallback; }
        BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        return fn(element, sel);
    } @catch (__unused NSException *e) {
        return fallback;
    }
}

+ (NSInteger)boolPropertyState:(NSString *)name
                     ofElement:(id)element
                        reason:(NSString * _Nullable * _Nullable)outReason {
    if (!element) { return 0; }
    @try {
        SEL sel = NSSelectorFromString(name);
        if (![element respondsToSelector:sel]) { return 0; }
        BOOL (*fn)(id, SEL) = (BOOL (*)(id, SEL))objc_msgSend;
        return fn(element, sel) ? 1 : 0;
    } @catch (NSException *e) {
        if (outReason) { *outReason = e.reason ?: e.name; }
        return -1;
    }
}

#pragma mark - Bounded Snapshot & Viewport Culling

+ (nullable id)boundedSnapshotForBundleID:(NSString *)bundleId
                                 maxDepth:(NSInteger)maxDepth
                              maxChildren:(NSInteger)maxChildren {
    @try {
        Class appClass = NSClassFromString(@"XCUIApplication");
        if (!appClass) { return nil; }
        id app = [[appClass alloc] performSelector:NSSelectorFromString(@"initWithBundleIdentifier:")
                                        withObject:bundleId];
        if (!app) { return nil; }

        id axElement = nil;
        for (NSString *sel in @[@"accessibilityElement", @"element"]) {
            SEL s = NSSelectorFromString(sel);
            if ([app respondsToSelector:s]) {
                axElement = [app performSelector:s];
                if (axElement) { break; }
            }
        }
        if (!axElement) { return nil; }

        id client = [self axInterface];
        if (!client) { return nil; }

        SEL reqSel = NSSelectorFromString(@"requestSnapshotForElement:attributes:parameters:error:");
        if (![client respondsToSelector:reqSel]) { return nil; }

        id attrs = nil;
        Class elemClass = NSClassFromString(@"XCUIElement");
        SEL attrSel = NSSelectorFromString(@"standardAttributeNames");
        if ([elemClass respondsToSelector:attrSel]) { attrs = [elemClass performSelector:attrSel]; }
        if ([attrs isKindOfClass:[NSSet class]]) { attrs = [(NSSet *)attrs allObjects]; }
        if (![attrs isKindOfClass:[NSArray class]]) { return nil; }

        NSMutableArray *wanted = [NSMutableArray arrayWithArray:(NSArray *)attrs];
        for (NSString *key in @[@"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeValue",
                                @"XC_kAXXCAttributeIdentifier",
                                @"XC_kAXXCAttributePlaceholderValue",
                                @"XC_kAXXCAttributeFrame"]) {
            if (![wanted containsObject:key]) { [wanted addObject:key]; }
        }

        NSError *err = nil;
        id (*fn)(id, SEL, id, id, id, NSError **) = (id (*)(id, SEL, id, id, id, NSError **))objc_msgSend;
        id result = fn(client, reqSel, axElement, wanted,
                       @{ @"maxDepth": @(maxDepth),
                          @"maxChildren": @(maxChildren),
                          @"maxArrayCount": @(maxChildren) }, &err);
        if (err || !result) { return nil; }

        SEL rootSel = NSSelectorFromString(@"rootElementSnapshot");
        if (![result respondsToSelector:rootSel]) { return nil; }
        return [result performSelector:rootSel];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *GroguTypeName(NSInteger t) {
    switch (t) {
        case 0: return @"Any";           case 1: return @"Other";
        case 2: return @"Application";   case 3: return @"Group";
        case 4: return @"Window";        case 5: return @"Sheet";
        case 7: return @"Alert";         case 9: return @"Button";
        case 19: return @"Keyboard";     case 20: return @"Key";
        case 21: return @"NavigationBar"; case 22: return @"TabBar";
        case 24: return @"Toolbar";      case 26: return @"Table";
        case 32: return @"CollectionView"; case 33: return @"Slider";
        case 36: return @"ActivityIndicator"; case 37: return @"SegmentedControl";
        case 38: return @"Picker";       case 39: return @"PickerWheel";
        case 40: return @"Switch";       case 42: return @"Link";
        case 43: return @"Image";        case 44: return @"Icon";
        case 45: return @"SearchField";  case 46: return @"ScrollView";
        case 48: return @"StaticText";   case 49: return @"TextField";
        case 50: return @"SecureTextField"; case 52: return @"TextView";
        case 57: return @"Map";          case 58: return @"WebView";
        case 75: return @"Cell";
        default: return [NSString stringWithFormat:@"Type%ld", (long)t];
    }
}

static BOOL GroguIsScrollIndicator(NSInteger type) { return type == 47; }
static BOOL GroguIsChromeBar(NSInteger t) { return t == 21 || t == 22 || t == 24 || t == 25; }
static BOOL GroguIsScrollable(NSInteger t) { return t == 26 || t == 32 || t == 46; }

static BOOL GroguRectVisible(CGRect f, CGRect viewport) {
    if (CGRectIsNull(viewport)) { return YES; }
    if (f.size.width <= 0 || f.size.height <= 0) { return NO; }
    return CGRectIntersectsRect(f, viewport);
}

static void GroguReadNode(id node, NSString **label, NSString **ident, NSString **value,
                          NSInteger *type, CGRect *frame) {
    SEL s = NSSelectorFromString(@"label");
    if ([node respondsToSelector:s]) { id v = [node performSelector:s]; if ([v isKindOfClass:[NSString class]]) *label = v; }
    s = NSSelectorFromString(@"identifier");
    if ([node respondsToSelector:s]) { id v = [node performSelector:s]; if ([v isKindOfClass:[NSString class]]) *ident = v; }
    s = NSSelectorFromString(@"value");
    if ([node respondsToSelector:s]) { id v = [node performSelector:s]; if ([v isKindOfClass:[NSString class]]) *value = v; }
    s = NSSelectorFromString(@"elementType");
    if ([node respondsToSelector:s]) {
        NSMethodSignature *sig = [node methodSignatureForSelector:s];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.selector = s; [inv invokeWithTarget:node];
        NSUInteger raw = 0; [inv getReturnValue:&raw]; *type = (NSInteger)raw;
    }
    s = NSSelectorFromString(@"frame");
    if ([node respondsToSelector:s]) {
        NSMethodSignature *sig = [node methodSignatureForSelector:s];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.selector = s; [inv invokeWithTarget:node];
        [inv getReturnValue:frame];
    }
}

static NSMutableString *GroguBuildLine(NSInteger depth, NSInteger type, NSString *label,
                                       NSString *value, NSString *ident, CGRect frame) {
    NSMutableString *line = [NSMutableString string];
    for (NSInteger i = 0; i < depth; i++) { [line appendString:@"  "]; }
    [line appendString:GroguTypeName(type)];
    if (label.length) { [line appendFormat:@", label: '%@'", label]; }
    if (value.length) { [line appendFormat:@", value: '%@'", value]; }
    if (ident.length) { [line appendFormat:@", id: '%@'", ident]; }
    [line appendFormat:@", {{%d, %d}, {%d, %d}}",
        (int)frame.origin.x, (int)frame.origin.y, (int)frame.size.width, (int)frame.size.height];
    return line;
}

static BOOL GroguRenderNode(id node, NSInteger depth, NSInteger maxDepth,
                            NSInteger maxElements, NSMutableArray *lines,
                            NSInteger *count, BOOL *truncated, CGRect viewport) {
    if (!node || *count >= maxElements) { if (*count >= maxElements) { *truncated = YES; } return NO; }
    @try {
        NSString *label = nil, *ident = nil, *value = nil;
        NSInteger type = 0;
        CGRect frame = CGRectZero;
        GroguReadNode(node, &label, &ident, &value, &type, &frame);

        BOOL selfVisible = GroguRectVisible(frame, viewport) && !GroguIsScrollIndicator(type);
        BOOL culling = !CGRectIsNull(viewport);

        NSMutableString *line = nil;
        NSUInteger slot = NSNotFound;
        if (!culling) {
            line = GroguBuildLine(depth, type, label, value, ident, frame);
            [lines addObject:line];
            (*count)++;
        } else if (selfVisible) {
            line = GroguBuildLine(depth, type, label, value, ident, frame);
            slot = lines.count;
            [lines addObject:[NSNull null]];
        } else {
            slot = lines.count;
            [lines addObject:[NSNull null]];
        }

        BOOL keptAnything = selfVisible;
        CGRect childViewport = viewport;
        if (culling && type == 75 && frame.size.width > 0 && frame.size.height > 0) {
            CGRect clip = CGRectIntersection(viewport, frame);
            childViewport = CGRectIsNull(clip) ? CGRectMake(-100000, -100000, 1, 1) : clip;
        }
        if (depth < maxDepth) {
            SEL s = NSSelectorFromString(@"children");
            if ([node respondsToSelector:s]) {
                id kids = [node performSelector:s];
                if ([kids isKindOfClass:[NSArray class]]) {
                    for (id k in (NSArray *)kids) {
                        if (*count >= maxElements) { *truncated = YES; break; }
                        if (GroguRenderNode(k, depth + 1, maxDepth, maxElements,
                                            lines, count, truncated, childViewport)) {
                            keptAnything = YES;
                        }
                    }
                }
            }
        }

        if (culling && keptAnything) {
            if (!line) { line = GroguBuildLine(depth, type, label, value, ident, frame); }
            lines[slot] = line;
            (*count)++;
        }
        return culling ? keptAnything : YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

+ (nullable NSString *)renderBoundedSnapshot:(id)root
                                    maxDepth:(NSInteger)maxDepth
                                 maxElements:(NSInteger)maxElements
                                 visibleRect:(CGRect)visibleRect
                                nodesWritten:(NSInteger * _Nullable)outCount
                                   truncated:(BOOL * _Nullable)outTruncated {
    if (!root) { return nil; }
    NSMutableArray *lines = [NSMutableArray array];
    NSInteger count = 0; BOOL trunc = NO;
    GroguRenderNode(root, 0, maxDepth, maxElements, lines, &count, &trunc, visibleRect);
    if (outCount) { *outCount = count; }
    if (outTruncated) { *outTruncated = trunc; }
    if (!CGRectIsNull(visibleRect)) {
        [lines removeObjectIdenticalTo:[NSNull null]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

+ (nullable NSDictionary *)visibleListParts:(NSString *)bundleId
                                     screen:(CGRect)screen
                                maxElements:(NSInteger)maxElements {
    @try {
        id root = [self boundedSnapshotForBundleID:bundleId maxDepth:30 maxChildren:12];
        if (!root) { return nil; }
        id iface = [self axInterface];
        SEL attrSel = NSSelectorFromString(@"attributesForElement:attributes:error:");
        SEL reqSel = NSSelectorFromString(@"requestSnapshotForElement:attributes:parameters:error:");
        if (![iface respondsToSelector:attrSel] || ![iface respondsToSelector:reqSel]) { return nil; }
        id (*attrFn)(id, SEL, id, id, NSError **) = (id (*)(id, SEL, id, id, NSError **))objc_msgSend;
        id (*reqFn)(id, SEL, id, id, id, NSError **) = (id (*)(id, SEL, id, id, id, NSError **))objc_msgSend;

        NSArray *bestCells = nil; id bestNode = nil; double bestArea = 0; id bestCount = nil; NSInteger bestDepth = -1;
        NSMutableArray *stack = [NSMutableArray arrayWithObject:@[root, @0]];
        while (stack.count) {
            NSArray *top = stack.lastObject; [stack removeLastObject];
            id n = top[0]; NSInteger depth = [top[1] integerValue];
            for (id c in [n valueForKey:@"children"] ?: @[]) { [stack addObject:@[c, @(depth + 1)]]; }
            NSUInteger type = [[n valueForKey:@"elementType"] unsignedIntegerValue];
            if (type != 26 && type != 32) { continue; }
            CGRect f = [[n valueForKey:@"frame"] CGRectValue];
            if (f.size.height < screen.size.height * 0.4 || !CGRectIntersectsRect(f, screen)) { continue; }
            NSError *err = nil;
            NSDictionary *vals = attrFn(iface, attrSel, [n valueForKey:@"accessibilityElement"],
                                        @[@"XC_kAXXCAttributeVisibleCells", @"XC_kAXXCAttributeChildrenCount"], &err);
            id cells = nil, count = nil;
            for (id k in vals) {
                if ([[k description] containsString:@"VisibleCells"]) cells = vals[k];
                if ([[k description] containsString:@"ChildrenCount"]) count = vals[k];
            }
            double area = f.size.width * f.size.height;
            if ([cells isKindOfClass:[NSArray class]] && [cells count] > 0
                && (bestNode == nil || depth > bestDepth || (depth == bestDepth && area < bestArea))) {
                bestCells = cells; bestNode = n; bestArea = area; bestCount = count; bestDepth = depth;
            }
        }
        if (!bestNode) { return nil; }
        NSInteger n = 0; BOOL trunc = NO;
        NSString *rootBody = [self renderBoundedSnapshot:root maxDepth:30 maxElements:maxElements visibleRect:screen
                                            nodesWritten:&n truncated:&trunc] ?: @"";
        NSArray *attrs = @[@"XC_kAXXCAttributeLabel", @"XC_kAXXCAttributeValue", @"XC_kAXXCAttributeFrame",
                           @"XC_kAXXCAttributeElementType", @"XC_kAXXCAttributeIdentifier",
                           @"XC_kAXXCAttributePlaceholderValue"];
        NSMutableArray *bodies = [NSMutableArray array];
        for (id cell in bestCells) {
            NSError *e2 = nil;
            id res = reqFn(iface, reqSel, cell, attrs, @{@"maxDepth": @24, @"maxChildren": @50, @"maxArrayCount": @50}, &e2);
            id snap = nil;
            @try { snap = [res valueForKey:@"rootElementSnapshot"]; } @catch (__unused NSException *x) { snap = res; }
            if (!snap) { continue; }
            NSInteger m = 0; BOOL t2 = NO;
            NSString *body = [self renderBoundedSnapshot:snap maxDepth:24 maxElements:400 visibleRect:screen
                                            nodesWritten:&m truncated:&t2];
            if (body.length) { [bodies addObject:body]; }
        }
        NSUInteger type = [[bestNode valueForKey:@"elementType"] unsignedIntegerValue];
        return @{
            @"root_body": rootBody,
            @"container_type": type == 26 ? @"Table" : @"CollectionView",
            @"container_frame": [bestNode valueForKey:@"frame"],
            @"cell_bodies": bodies,
            @"children_count": bestCount ?: @(-1),
        };
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL GroguSameClass(unichar a, unichar b) {
    BOOL ad = a >= '0' && a <= '9', bd = b >= '0' && b <= '9';
    if (ad && bd) { return YES; }
    BOOL al = (a | 0x20) >= 'a' && (a | 0x20) <= 'z', bl = (b | 0x20) >= 'a' && (b | 0x20) <= 'z';
    return al && bl;
}

static NSInteger GroguContainsQuality(NSString *hay, NSString *needle, NSRange r) {
    if (r.location == 0) { return 0; }
    unichar before = [hay characterAtIndex:r.location - 1];
    BOOL leftOK = !GroguSameClass(before, [needle characterAtIndex:0]);
    NSUInteger after = NSMaxRange(r);
    BOOL rightOK = after >= hay.length
        || !GroguSameClass([hay characterAtIndex:after], [needle characterAtIndex:needle.length - 1]);
    return (leftOK && rightOK) ? 1 : 2;
}

typedef struct {
    __unsafe_unretained NSString *needle;
    BOOL contains;
    __unsafe_unretained NSSet<NSNumber *> *types;
    NSInteger maxDepth;
    NSInteger maxVisit;
    NSInteger visited;
    CGRect viewport;
} GroguLocateCtx;

static void GroguCollect(id node, NSInteger depth, GroguLocateCtx *ctx,
                         BOOL inChrome, NSValue *scrollAncestor,
                         NSMutableDictionary<NSString *, NSNumber *> *labelSeen,
                         NSMutableDictionary<NSString *, NSNumber *> *identSeen,
                         NSMutableArray<NSMutableDictionary *> *out,
                         NSMutableArray<NSArray *> *chromeBars,
                         NSMutableArray<NSValue *> *scrollables,
                         NSMutableArray<NSString *> *fingerprint) {
    if (!node || ctx->visited >= ctx->maxVisit) { return; }
    @try {
        ctx->visited++;
        NSString *label = nil, *ident = nil, *value = nil;
        NSInteger type = 0;
        CGRect frame = CGRectZero;
        GroguReadNode(node, &label, &ident, &value, &type, &frame);

        if (GroguIsChromeBar(type)) { [chromeBars addObject:@[@(type), [NSValue valueWithCGRect:frame]]]; }
        if (GroguIsScrollable(type) && GroguRectVisible(frame, ctx->viewport)) {
            [scrollables addObject:[NSValue valueWithCGRect:frame]];
        }
        if (fingerprint.count < 40 && label.length && GroguRectVisible(frame, ctx->viewport)) {
            [fingerprint addObject:[NSString stringWithFormat:@"%@@%d", label, (int)frame.origin.y]];
        }

        BOOL typeOK = depth > 0 && (!ctx->types || [ctx->types containsObject:@(type)]);
        if (typeOK) {
            NSInteger labelOrdinal = label.length ? [labelSeen[label] integerValue] : 0;
            NSInteger identOrdinal = ident.length ? [identSeen[ident] integerValue] : 0;
            if (label.length) { labelSeen[label] = @(labelOrdinal + 1); }
            if (ident.length) { identSeen[ident] = @(identOrdinal + 1); }

            NSInteger tier = -1, quality = 0;
            if (label.length && [label isEqualToString:ctx->needle]) { tier = 0; }
            else if (ident.length && [ident isEqualToString:ctx->needle]) { tier = 1; }
            else if (value.length && [value isEqualToString:ctx->needle]) { tier = 3; }
            else if (ctx->contains) {
                NSString *hay = [NSString stringWithFormat:@"%@ %@", label ?: @"", value ?: @""];
                NSRange r = [hay rangeOfString:ctx->needle options:NSCaseInsensitiveSearch];
                if (r.location != NSNotFound) { tier = 2; quality = GroguContainsQuality(hay, ctx->needle, r); }
            }
            BOOL valueOnly = !label.length && !ident.length && value.length && (tier == 2 || tier == 3);
            if (tier >= 0 && (label.length || ident.length || valueOnly)) {
                BOOL byLabel = label.length > 0 && tier != 1;
                NSMutableDictionary *c = [@{
                    @"how": tier == 0 ? @"exact" : (tier == 1 ? @"id" : (tier == 3 ? @"value" : @"contains")),
                    @"tier": @(tier), @"quality": @(quality),
                    @"label": label ?: @"", @"identifier": ident ?: @"",
                    @"value": value ?: @"",
                    @"type": @(type),
                    @"key": valueOnly ? @"value" : (byLabel ? @"label" : @"identifier"),
                    @"ordinal": @(byLabel ? labelOrdinal : identOrdinal),
                    @"order": @(out.count),
                    @"in_chrome": @(inChrome),
                    @"x": @(frame.origin.x), @"y": @(frame.origin.y),
                    @"w": @(frame.size.width), @"h": @(frame.size.height),
                } mutableCopy];
                if (out.count < 150) { [out addObject:c]; }
            }
        }

        if (depth >= ctx->maxDepth) { return; }
        BOOL childChrome = inChrome || GroguIsChromeBar(type);
        NSValue *childScroll = GroguIsScrollable(type) ? [NSValue valueWithCGRect:frame] : scrollAncestor;
        SEL s = NSSelectorFromString(@"children");
        if ([node respondsToSelector:s]) {
            id kids = [node performSelector:s];
            if ([kids isKindOfClass:[NSArray class]]) {
                for (id k in (NSArray *)kids) {
                    GroguCollect(k, depth + 1, ctx, childChrome, childScroll, labelSeen, identSeen,
                                 out, chromeBars, scrollables, fingerprint);
                }
            }
        }
    } @catch (__unused NSException *e) {}
}

+ (nullable NSDictionary *)locateInBoundedSnapshot:(id)root
                                             query:(NSString *)query
                                          contains:(BOOL)contains
                                             types:(nullable NSArray<NSNumber *> *)types
                                          viewport:(CGRect)viewport
                                          maxDepth:(NSInteger)maxDepth {
    if (!root || !query.length) { return nil; }
    __attribute__((objc_precise_lifetime)) NSSet<NSNumber *> *typeSet =
        types ? [NSSet setWithArray:types] : nil;
    GroguLocateCtx ctx = {
        .needle = query, .contains = contains,
        .types = typeSet,
        .maxDepth = maxDepth, .maxVisit = 5000, .visited = 0, .viewport = viewport,
    };
    NSMutableArray<NSMutableDictionary *> *cands = [NSMutableArray array];
    NSMutableArray<NSArray *> *bars = [NSMutableArray array];
    NSMutableArray<NSValue *> *scrollables = [NSMutableArray array];
    NSMutableArray<NSString *> *fp = [NSMutableArray array];
    GroguCollect(root, 0, &ctx, NO, nil, [NSMutableDictionary dictionary], [NSMutableDictionary dictionary],
                 cands, bars, scrollables, fp);

    CGFloat h = viewport.size.height;
    CGFloat top = 0, bottom = h;
    for (NSArray *b in bars) {
        NSInteger t = [b[0] integerValue];
        CGRect f = [b[1] CGRectValue];
        if (f.size.height <= 0 || f.size.height >= h * 0.4 || !GroguRectVisible(f, viewport)) { continue; }
        BOOL topBar = (t == 21 || t == 25);
        if (topBar && CGRectGetMaxY(f) > top && f.origin.y < h * 0.3) { top = CGRectGetMaxY(f); }
        if (!topBar && f.origin.y < bottom && CGRectGetMaxY(f) > h * 0.7) { bottom = f.origin.y; }
    }

    for (NSMutableDictionary *c in cands) {
        CGRect f = CGRectMake([c[@"x"] doubleValue], [c[@"y"] doubleValue], [c[@"w"] doubleValue], [c[@"h"] doubleValue]);
        NSInteger vis = 2;
        if (GroguRectVisible(f, viewport)) {
            CGFloat mx = CGRectGetMidX(f), my = CGRectGetMidY(f);
            BOOL centreOn = mx >= 0 && mx <= viewport.size.width && my >= 0 && my <= h;
            BOOL inBand = my > top && my < bottom;
            vis = (centreOn && (inBand || [c[@"in_chrome"] boolValue])) ? 0 : 1;
        }
        c[@"vis"] = @(vis);
        c[@"visibility"] = vis == 0 ? @"in_view" : (vis == 1 ? @"partial" : @"offscreen");
    }

    [cands sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        for (NSString *k in @[@"vis", @"tier", @"quality"]) {
            NSComparisonResult r = [a[k] compare:b[k]];
            if (r != NSOrderedSame) { return r; }
        }
        NSUInteger la = [a[@"label"] length], lb = [b[@"label"] length];
        if (la != lb) { return la < lb ? NSOrderedAscending : NSOrderedDescending; }
        return [a[@"order"] compare:b[@"order"]];
    }];

    return @{
        @"candidates": cands,
        @"visited": @(ctx.visited),
        @"fingerprint": [fp componentsJoinedByString:@"|"],
    };
}

@end
