#import "AcceptanceEditorSession.h"
#include <math.h>

static NSString *ReceiptPath(NSString *directory) {
    return [directory stringByAppendingPathComponent:@"external-editor.plist"];
}

static NSString *CancellationPath(NSString *directory) {
    return [directory stringByAppendingPathComponent:@"external-editor-cancelled"];
}

static void WaitForEditorExit(NSRunningApplication *application, NSTimeInterval timeout) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!application.terminated && limit.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

BOOL NVAcceptanceEditorMatchesIdentity(NSRunningApplication *application, NSDictionary *identity) {
    if (![identity isKindOfClass:[NSDictionary class]] ||
        ![identity[@"pid"] isKindOfClass:[NSNumber class]] ||
        ![identity[@"launched"] isKindOfClass:[NSNumber class]]) return NO;
    return application.processIdentifier > 0 && application.processIdentifier == [identity[@"pid"] intValue] &&
        application.launchDate && fabs(application.launchDate.timeIntervalSince1970 - [identity[@"launched"] doubleValue]) < 0.001 &&
        [application.bundleIdentifier isEqualToString:identity[@"bundleIdentifier"]] &&
        [application.bundleURL.path.stringByResolvingSymlinksInPath isEqualToString:identity[@"bundlePath"]];
}

BOOL NVStopAcceptanceEditor(NSRunningApplication *application, NSDictionary *identity, NSTimeInterval timeout) {
    if (!application || application.terminated) return YES;
    if (!NVAcceptanceEditorMatchesIdentity(application, identity)) return NO;
    [application terminate];
    WaitForEditorExit(application, timeout);
    if (!application.terminated && NVAcceptanceEditorMatchesIdentity(application, identity)) {
        [application forceTerminate];
        WaitForEditorExit(application, timeout);
    }
    return application.terminated;
}

BOOL NVCleanupAcceptanceEditor(NSString *directory) {
    if (![[NSData data] writeToFile:CancellationPath(directory) atomically:YES]) return NO;
    NSString *path = ReceiptPath(directory);
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return YES;
    NSDictionary *identity = [NSDictionary dictionaryWithContentsOfFile:path];
    if (![identity isKindOfClass:[NSDictionary class]] ||
        ![identity[@"pid"] isKindOfClass:[NSNumber class]] || [identity[@"pid"] intValue] <= 0 ||
        ![identity[@"launched"] isKindOfClass:[NSNumber class]] ||
        ![identity[@"bundleIdentifier"] isEqualToString:@"com.apple.TextEdit"] ||
        ![identity[@"bundlePath"] isKindOfClass:[NSString class]]) return NO;
    NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:[identity[@"pid"] intValue]];
    if (!NVStopAcceptanceEditor(application, identity, 2)) return NO;
    return [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

@implementation NVAcceptanceEditorSession
- (id)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) _directory = [directory.stringByResolvingSymlinksInPath copy];
    return self;
}
- (void)dealloc {
    [_directory release];
    [_application release];
    [_identity release];
    [super dealloc];
}
- (BOOL)openURLs:(NSArray *)URLs withApplicationAtURL:(NSURL *)applicationURL workspace:(NSWorkspace *)workspace timeout:(NSTimeInterval)timeout {
    if (!URLs.count || !applicationURL || _opening || _teardownRequested || _finishedOpening) return NO;
    for (NSURL *URL in URLs)
        if (!URL.isFileURL || ![URL.path.stringByResolvingSymlinksInPath hasPrefix:[_directory stringByAppendingString:@"/"]]) return NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:ReceiptPath(_directory)] ||
        [[NSFileManager defaultManager] fileExistsAtPath:CancellationPath(_directory)]) return NO;
    NSMutableSet *existing = [NSMutableSet set];
    for (NSRunningApplication *application in workspace.runningApplications)
        [existing addObject:@(application.processIdentifier)];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.createsNewApplicationInstance = YES;
    configuration.allowsRunningApplicationSubstitution = NO;
    configuration.activates = NO;
    configuration.hides = YES;
    configuration.addsToRecentItems = NO;
    configuration.promptsUserIfNeeded = NO;
    configuration.arguments = @[@"-ApplePersistenceIgnoreState", @"YES", @"-NSQuitAlwaysKeepsWindows", @"NO"];
    _opening = YES;
    [workspace openURLs:URLs withApplicationAtURL:applicationURL configuration:configuration completionHandler:^(NSRunningApplication *application, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (application && ![existing containsObject:@(application.processIdentifier)] && application.launchDate &&
                [application.bundleIdentifier isEqualToString:@"com.apple.TextEdit"] &&
                [application.bundleURL.path.stringByResolvingSymlinksInPath isEqualToString:applicationURL.path.stringByResolvingSymlinksInPath]) {
                _application = [application retain];
                _identity = [@{@"pid": @(application.processIdentifier), @"launched": @(application.launchDate.timeIntervalSince1970),
                    @"bundleIdentifier": application.bundleIdentifier, @"bundlePath": application.bundleURL.path.stringByResolvingSymlinksInPath} retain];
                _openedSuccessfully = !error && [_identity writeToFile:ReceiptPath(_directory) atomically:YES];
            }
            if (!_openedSuccessfully)
                NSLog(@"NV acceptance editor launch failed: %@ (PID %d, launch date %@)", error, application.processIdentifier, application.launchDate);
            _opening = NO;
            _finishedOpening = YES;
            if ([[NSFileManager defaultManager] fileExistsAtPath:CancellationPath(_directory)]) _teardownRequested = YES;
            if (_teardownRequested || !_openedSuccessfully) [self tearDown];
        });
    }];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!_finishedOpening && limit.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    if (!_finishedOpening) [self tearDown];
    if (!_finishedOpening || !_openedSuccessfully || _teardownRequested) return NO;
    limit = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!_application.finishedLaunching && !_application.terminated && limit.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    if (!_application.finishedLaunching || _application.terminated) {
        NSLog(@"NV acceptance editor did not finish launching: finished=%d terminated=%d", _application.finishedLaunching, _application.terminated);
        return NO;
    }
    [_application hide];
    while ((!_application.hidden || _application.active) && limit.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    BOOL background = _application.hidden && !_application.active;
    if (!background) NSLog(@"NV acceptance editor could not remain in the background: hidden=%d active=%d", _application.hidden, _application.active);
    return background;
}
- (BOOL)tearDown {
    _teardownRequested = YES;
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
    while (_opening && limit.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    if (_opening) return NO;
    if (!NVStopAcceptanceEditor(_application, _identity, 2)) return NO;
    if (!_identity) return YES;
    NSString *path = ReceiptPath(_directory);
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (![[NSDictionary dictionaryWithContentsOfFile:path] isEqualToDictionary:_identity]) return NO;
        return [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    return YES;
}
@end
