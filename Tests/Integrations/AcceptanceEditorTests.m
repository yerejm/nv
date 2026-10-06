#import <XCTest/XCTest.h>
#import "AcceptanceEditorSession.h"

@interface AcceptanceApplication : NSObject
@property(nonatomic) pid_t processIdentifier;
@property(nonatomic, retain) NSDate *launchDate;
@property(nonatomic, copy) NSString *bundleIdentifier;
@property(nonatomic, retain) NSURL *bundleURL;
@property(nonatomic, getter=isTerminated) BOOL terminated;
@property(nonatomic, getter=isFinishedLaunching) BOOL finishedLaunching;
@property(nonatomic, getter=isHidden) BOOL hidden;
@property(nonatomic, getter=isActive) BOOL active;
@property(nonatomic) BOOL normalQuitSucceeds;
@property(nonatomic) BOOL hideSucceeds;
@property(nonatomic) NSUInteger normalQuitCount;
@property(nonatomic) NSUInteger forcedQuitCount;
@end
@implementation AcceptanceApplication
- (BOOL)hide { self.hidden = self.hideSucceeds; return self.hidden; }
- (BOOL)terminate {
    self.normalQuitCount++;
    self.terminated = self.normalQuitSucceeds;
    return self.terminated;
}
- (BOOL)forceTerminate {
    self.forcedQuitCount++;
    self.terminated = YES;
    return YES;
}
@end

@interface AcceptanceWorkspace : NSObject
@property(nonatomic, retain) NSArray *runningApplications;
@property(nonatomic, retain) AcceptanceApplication *openedApplication;
@property(nonatomic, retain) NSWorkspaceOpenConfiguration *configuration;
@property(nonatomic) BOOL receivedOpen;
@property(nonatomic) NSTimeInterval delay;
@end
@implementation AcceptanceWorkspace
- (void)openURLs:(NSArray *)URLs withApplicationAtURL:(NSURL *)URL configuration:(NSWorkspaceOpenConfiguration *)configuration
    completionHandler:(void (^)(NSRunningApplication *, NSError *))completion {
    self.receivedOpen = YES;
    self.configuration = configuration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        completion((id)self.openedApplication, self.openedApplication ? nil : [NSError errorWithDomain:@"AcceptanceTests" code:1 userInfo:nil]);
    });
}
@end

@interface AcceptanceEditorTests : XCTestCase
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, retain) AcceptanceApplication *application;
@property(nonatomic, retain) AcceptanceWorkspace *workspace;
@property(nonatomic, retain) NVAcceptanceEditorSession *session;
@end
@implementation AcceptanceEditorTests
- (void)setUp {
    [super setUp];
    self.directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.directory withIntermediateDirectories:YES attributes:nil error:NULL]);
    self.application = [[[AcceptanceApplication alloc] init] autorelease];
    self.application.processIdentifier = 12345;
    self.application.launchDate = [NSDate dateWithTimeIntervalSince1970:1700000000];
    self.application.bundleIdentifier = @"com.apple.TextEdit";
    self.application.bundleURL = [NSURL fileURLWithPath:@"/System/Applications/TextEdit.app"];
    self.application.normalQuitSucceeds = YES;
    self.application.finishedLaunching = YES;
    self.application.hideSucceeds = YES;
    self.workspace = [[[AcceptanceWorkspace alloc] init] autorelease];
    self.workspace.runningApplications = @[];
    self.workspace.openedApplication = self.application;
    self.session = [[[NVAcceptanceEditorSession alloc] initWithDirectory:self.directory] autorelease];
}
- (void)tearDown {
    XCTAssertTrue([self.session tearDown]);
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:self.directory error:NULL]);
    self.session = nil;
    self.workspace = nil;
    self.application = nil;
    [super tearDown];
}
- (BOOL)openWithTimeout:(NSTimeInterval)timeout {
    return [self.session openURLs:@[[NSURL fileURLWithPath:[self.directory stringByAppendingPathComponent:@"note.txt"]]]
        withApplicationAtURL:self.application.bundleURL workspace:(id)self.workspace timeout:timeout];
}
- (NSDictionary *)identity {
    return @{@"pid": @(self.application.processIdentifier), @"launched": @(self.application.launchDate.timeIntervalSince1970),
        @"bundleIdentifier": self.application.bundleIdentifier, @"bundlePath": self.application.bundleURL.path};
}
- (void)testLaunchIsSeparateHiddenAndDoesNotRestoreDocuments {
    XCTAssertTrue([self openWithTimeout:1]);
    NSWorkspaceOpenConfiguration *configuration = self.workspace.configuration;
    XCTAssertTrue(configuration.createsNewApplicationInstance);
    XCTAssertFalse(configuration.allowsRunningApplicationSubstitution);
    XCTAssertFalse(configuration.activates);
    XCTAssertTrue(configuration.hides);
    XCTAssertFalse(configuration.addsToRecentItems);
    XCTAssertFalse(configuration.promptsUserIfNeeded);
    XCTAssertEqualObjects(configuration.arguments, (@[@"-ApplePersistenceIgnoreState", @"YES", @"-NSQuitAlwaysKeepsWindows", @"NO"]));
}
- (void)testTeardownClosesOwnedProcessAndRemovesReceipt {
    XCTAssertTrue([self openWithTimeout:1]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:[self.directory stringByAppendingPathComponent:@"external-editor.plist"]]);
    XCTAssertTrue([self.session tearDown]);
    XCTAssertTrue(self.application.terminated);
    XCTAssertEqual(self.application.normalQuitCount, 1U);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[self.directory stringByAppendingPathComponent:@"external-editor.plist"]]);
    XCTAssertTrue([self.session tearDown]);
    XCTAssertEqual(self.application.normalQuitCount, 1U);
}
- (void)testLaunchFailureHasNoProcessToClose {
    self.workspace.openedApplication = nil;
    XCTAssertFalse([self openWithTimeout:1]);
    XCTAssertTrue([self.session tearDown]);
    XCTAssertEqual(self.application.normalQuitCount, 0U);
}
- (void)testPreexistingProcessIsNeverOwnedOrTerminated {
    self.workspace.runningApplications = @[self.application];
    XCTAssertFalse([self openWithTimeout:1]);
    XCTAssertTrue([self.session tearDown]);
    XCTAssertEqual(self.application.normalQuitCount, 0U);
    XCTAssertEqual(self.application.forcedQuitCount, 0U);
}
- (void)testFilesOutsideTestDirectoryAreRejected {
    XCTAssertFalse([self.session openURLs:@[[NSURL fileURLWithPath:[self.directory stringByAppendingString:@"-other/note.txt"]]]
        withApplicationAtURL:self.application.bundleURL workspace:(id)self.workspace timeout:1]);
    XCTAssertFalse(self.workspace.receivedOpen);
}
- (void)testLateLaunchAfterTimeoutIsClosed {
    self.workspace.delay = 0.05;
    XCTAssertFalse([self openWithTimeout:0.001]);
    XCTAssertTrue(self.application.terminated);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[self.directory stringByAppendingPathComponent:@"external-editor.plist"]]);
}
- (void)testRunnerCleanupPreventsLaterLaunch {
    XCTAssertTrue(NVCleanupAcceptanceEditor(self.directory));
    XCTAssertFalse([self openWithTimeout:1]);
    XCTAssertFalse(self.workspace.receivedOpen);
    XCTAssertEqual(self.application.normalQuitCount, 0U);
}
- (void)testRunnerCleanupDuringPendingLaunchClosesReturnedEditor {
    self.workspace.delay = 0.05;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        XCTAssertTrue(NVCleanupAcceptanceEditor(self.directory));
    });
    XCTAssertFalse([self openWithTimeout:1]);
    XCTAssertTrue(self.application.terminated);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:[self.directory stringByAppendingPathComponent:@"external-editor.plist"]]);
}
- (void)testMismatchedIdentityCannotTerminateProcess {
    for (NSDictionary *change in @[@{@"pid": @99999}, @{@"launched": @1},
                                    @{@"bundleIdentifier": @"another.editor"}, @{@"bundlePath": @"/another/app"}]) {
        NSMutableDictionary *identity = [[self.identity mutableCopy] autorelease];
        [identity addEntriesFromDictionary:change];
        XCTAssertFalse(NVStopAcceptanceEditor((id)self.application, identity, 0));
    }
    XCTAssertEqual(self.application.normalQuitCount, 0U);
    XCTAssertEqual(self.application.forcedQuitCount, 0U);
}
- (void)testRefusedNormalQuitFallsBackOnlyForOwnedProcess {
    self.application.normalQuitSucceeds = NO;
    XCTAssertTrue(NVStopAcceptanceEditor((id)self.application, self.identity, 0));
    XCTAssertEqual(self.application.normalQuitCount, 1U);
    XCTAssertEqual(self.application.forcedQuitCount, 1U);
}
- (void)testMalformedReceiptIsRejectedAndPreserved {
    NSString *path = [self.directory stringByAppendingPathComponent:@"external-editor.plist"];
    XCTAssertTrue([@{@"pid": @"not a process"} writeToFile:path atomically:YES]);
    XCTAssertFalse(NVCleanupAcceptanceEditor(self.directory));
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path]);
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:path error:NULL]);
}
- (void)testSessionCannotRemoveAnotherSessionsReceipt {
    NSString *path = [self.directory stringByAppendingPathComponent:@"external-editor.plist"];
    NSDictionary *identity = self.identity;
    XCTAssertTrue([identity writeToFile:path atomically:YES]);
    XCTAssertFalse([self openWithTimeout:1]);
    XCTAssertTrue([self.session tearDown]);
    XCTAssertEqualObjects([NSDictionary dictionaryWithContentsOfFile:path], identity);
    XCTAssertFalse(self.workspace.receivedOpen);
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:path error:NULL]);
}
- (void)testFailedBackgroundLaunchStillCleansUpOwnedEditor {
    self.application.hideSucceeds = NO;
    XCTAssertFalse([self openWithTimeout:0.05]);
    XCTAssertTrue([self.session tearDown]);
    XCTAssertTrue(self.application.terminated);
}
- (void)testExceptionAfterOpeningStillClosesEditorInFinally {
    @try {
        XCTAssertTrue([self openWithTimeout:1]);
        @throw [NSException exceptionWithName:@"AcceptanceFailure" reason:@"Simulated failed check" userInfo:nil];
    } @catch (NSException *exception) {
        XCTAssertEqualObjects(exception.name, @"AcceptanceFailure");
    } @finally {
        XCTAssertTrue([self.session tearDown]);
    }
    XCTAssertTrue(self.application.terminated);
}
@end
