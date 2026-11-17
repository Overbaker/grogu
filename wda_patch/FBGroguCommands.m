#import "FBGroguCommands.h"

#import <XCTest/XCTest.h>
#import <WebDriverAgentLib/FBApplication.h>
#import <WebDriverAgentLib/FBConfiguration.h>
#import <WebDriverAgentLib/FBRoute.h>
#import <WebDriverAgentLib/FBRouteRequest.h>
#import <WebDriverAgentLib/FBResponsePayload.h>
#import <WebDriverAgentLib/XCUIElement+FBUtilities.h>

static void GroguCollectNodes(id<XCUIElementSnapshot> snapshot,
                              NSMutableArray<NSDictionary *> *outNodes,
                              NSInteger depth,
                              NSInteger maxDepth,
                              NSInteger maxNodes)
{
  if (!snapshot || depth > maxDepth || (NSInteger)outNodes.count >= maxNodes) {
    return;
  }

  CGRect frame = snapshot.frame;
  NSString *label = snapshot.label ?: @"";
  NSString *ident = snapshot.identifier ?: @"";
  id valObj = snapshot.value;
  NSString *valStr = valObj ? [NSString stringWithFormat:@"%@", valObj] : @"";
  XCUIElementType elType = snapshot.elementType;

  BOOL hasContent = (label.length > 0 || ident.length > 0 || valStr.length > 0);
  BOOL interactive = (elType == XCUIElementTypeButton ||
                      elType == XCUIElementTypeTextField ||
                      elType == XCUIElementTypeSecureTextField ||
                      elType == XCUIElementTypeSearchField ||
                      elType == XCUIElementTypeCell ||
                      elType == XCUIElementTypeSwitch ||
                      elType == XCUIElementTypeLink ||
                      elType == XCUIElementTypeTab ||
                      elType == XCUIElementTypeSlider ||
                      elType == XCUIElementTypeTextView);

  if (frame.size.width > 0 && frame.size.height > 0 && (hasContent || interactive)) {
    if (elType != XCUIElementTypeApplication && elType != XCUIElementTypeWindow) {
      NSInteger cx = (NSInteger)llround(CGRectGetMidX(frame));
      NSInteger cy = (NSInteger)llround(CGRectGetMidY(frame));
      [outNodes addObject:@{
        @"index": @(outNodes.count),
        @"el_type": @(elType),
        @"label": label,
        @"name": ident,
        @"value": valStr,
        @"enabled": @(snapshot.isEnabled),
        @"rect": @{
          @"x": @((NSInteger)llround(frame.origin.x)),
          @"y": @((NSInteger)llround(frame.origin.y)),
          @"width": @((NSInteger)llround(frame.size.width)),
          @"height": @((NSInteger)llround(frame.size.height)),
        },
        @"center": @[@(cx), @(cy)],
      }];
    }
  }

  for (id<XCUIElementSnapshot> child in snapshot.children) {
    if ((NSInteger)outNodes.count >= maxNodes) {
      break;
    }
    GroguCollectNodes(child, outNodes, depth + 1, maxDepth, maxNodes);
  }
}

@implementation FBGroguCommands

+ (NSArray<FBRoute *> *)routes
{
  return @[
    [[FBRoute GET:@"/grogu/fast_tree"].withoutSession respondWithTarget:self action:@selector(handleFastTree:)],
    [[FBRoute POST:@"/grogu/reflex"].withoutSession respondWithTarget:self action:@selector(handleReflex:)],
  ];
}

+ (id<FBResponsePayload>)handleFastTree:(FBRouteRequest *)request
{
  NSDate *start = [NSDate date];
  FBApplication *app = [FBApplication fb_activeApplication];
  if (!app) {
    return FBResponseWithObject(@[]);
  }
  id<XCUIElementSnapshot> rootSnap = [app fb_lastSnapshot] ?: [app snapshot];
  NSMutableArray<NSDictionary *> *nodes = [NSMutableArray arrayWithCapacity:128];
  GroguCollectNodes(rootSnap, nodes, 0, 35, 160);
  double ms = [[NSDate date] timeIntervalSinceDate:start] * 1000.0;
  return FBResponseWithObject(@{
    @"bundleId": app.bundleID ?: @"",
    @"latency_ms": @(round(ms * 10.0) / 10.0),
    @"nodes": nodes,
  });
}

+ (id<FBResponsePayload>)handleReflex:(FBRouteRequest *)request
{
  NSDate *start = [NSDate date];
  NSString *matchText = request.arguments[@"match"];
  if (![matchText isKindOfClass:[NSString class]] || matchText.length == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"Missing 'match' string" traceback:nil]);
  }
  double timeoutMs = [request.arguments[@"timeout_ms"] doubleValue] ?: 1500.0;
  double pollMs = MAX(20.0, [request.arguments[@"poll_ms"] doubleValue] ?: 35.0);
  NSString *needle = matchText.lowercaseString;

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutMs / 1000.0];
  while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
    FBApplication *app = [FBApplication fb_activeApplication];
    id<XCUIElementSnapshot> rootSnap = [app snapshot];
    NSMutableArray<NSDictionary *> *nodes = [NSMutableArray arrayWithCapacity:128];
    GroguCollectNodes(rootSnap, nodes, 0, 35, 160);
    for (NSDictionary *node in nodes) {
      NSString *lbl = [node[@"label"] lowercaseString] ?: @"";
      NSString *nam = [node[@"name"] lowercaseString] ?: @"";
      NSString *val = [node[@"value"] lowercaseString] ?: @"";
      if ([lbl containsString:needle] || [nam containsString:needle] || [val containsString:needle]) {
        NSArray *center = node[@"center"];
        XCUICoordinate *coord = [[app coordinateWithNormalizedOffset:CGVectorMake(0, 0)]
                                  coordinateWithOffset:CGVectorMake([center[0] doubleValue], [center[1] doubleValue])];
        [coord tap];
        double ms = [[NSDate date] timeIntervalSinceDate:start] * 1000.0;
        return FBResponseWithObject(@{
          @"matched": node,
          @"tapped": center,
          @"latency_ms": @(round(ms * 10.0) / 10.0),
        });
      }
    }
    [NSThread sleepForTimeInterval:pollMs / 1000.0];
  }

  return FBResponseWithStatus([FBCommandStatus timeoutErrorWithMessage:@"Reflex match timeout" traceback:nil]);
}

@end
