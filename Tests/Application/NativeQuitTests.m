#import <XCTest/XCTest.h>
#import "AppController.h"

@interface QuitStorage : NSObject
@property(nonatomic, retain) NSMutableArray *events;
@property(nonatomic) BOOL flushSucceeds;
@end
@implementation QuitStorage
- (void)stopFileNotifications { [self.events addObject:@"stop monitoring"]; }
- (BOOL)flushAllNoteChanges {
    [self.events addObject:@"flush notes"];
    return self.flushSucceeds;
}
- (void)closeJournal { [self.events addObject:@"close journal"]; }
@end
@interface QuitPreferences : NSObject
@property(nonatomic, retain) NSMutableArray *events;
@end
@implementation QuitPreferences
- (void)setLastSearchString:(NSString *)search selectedNote:(id)note scrollOffsetForTableView:(id)table sender:(id)sender {
    [self.events addObject:@"save selection"];
}
- (void)saveCurrentBookmarksFromSender:(id)sender { [self.events addObject:@"save bookmarks"]; }
- (void)synchronize { [self.events addObject:@"save preferences"]; }
@end
@interface QuitController : AppController
- (id)initWithStorage:(QuitStorage *)storage preferences:(QuitPreferences *)preferences;
@end
@implementation QuitController
- (id)initWithStorage:(QuitStorage *)storage preferences:(QuitPreferences *)preferences {
    if ((self = [super init])) {
        notationController = (id)[storage retain];
        prefsController = (id)[preferences retain];
    }
    return self;
}
@end
@interface NativeQuitTests : XCTestCase
@end
@implementation NativeQuitTests
- (void)checkQuitWithFlush:(BOOL)success {
    [NSApplication sharedApplication];
    NSMutableArray *events = [NSMutableArray array];
    QuitStorage *storage = [[[QuitStorage alloc] init] autorelease];
    storage.events = events;
    storage.flushSucceeds = success;
    QuitPreferences *prefs = [[[QuitPreferences alloc] init] autorelease];
    prefs.events = events;
    QuitController *controller = [[[QuitController alloc] initWithStorage:storage preferences:prefs] autorelease];
    [controller applicationWillTerminate:[NSNotification notificationWithName:NSApplicationWillTerminateNotification object:NSApp]];
    NSArray *expected = success ? @[@"save selection", @"save bookmarks", @"stop monitoring", @"flush notes", @"close journal", @"save preferences"]
                               : @[@"save selection", @"save bookmarks", @"stop monitoring", @"flush notes", @"save preferences"];
    XCTAssertEqualObjects(events, expected);
}
- (void)testQuitFlushesBeforeClosingJournal { [self checkQuitWithFlush:YES]; }
- (void)testQuitKeepsJournalWhenFlushFails { [self checkQuitWithFlush:NO]; }
@end
