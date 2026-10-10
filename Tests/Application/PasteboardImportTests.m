#import <XCTest/XCTest.h>
#import "AppController.h"
#import "AppController_Importing.h"
#import "NotationPrefs.h"

@interface PasteboardStorage : NSObject
@property(nonatomic, retain) NSArray *openedPaths;
@end
@implementation PasteboardStorage
- (BOOL)openFiles:(NSArray *)paths {
    self.openedPaths = paths;
    return YES;
}
- (int)currentNoteStorageFormat {
    return SingleDatabaseFormat;
}
@end
@interface PasteboardController : AppController
- (id)initWithStorage:(PasteboardStorage *)storage;
@end
@implementation PasteboardController
- (id)initWithStorage:(PasteboardStorage *)storage {
    if ((self = [super init])) notationController = (id)[storage retain];
    return self;
}
@end
@interface PasteboardImportTests : XCTestCase
@end
@implementation PasteboardImportTests
- (NSPasteboard *)pasteboardWithObjects:(NSArray *)objects {
    NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [pasteboard clearContents];
    [pasteboard writeObjects:objects];
    [self addTeardownBlock:^{ [pasteboard releaseGlobally]; }];
    return pasteboard;
}
- (void)testDroppedFileURLsAreImported {
    PasteboardStorage *storage = [[[PasteboardStorage alloc] init] autorelease];
    PasteboardController *controller = [[[PasteboardController alloc] initWithStorage:storage] autorelease];
    NSPasteboard *pasteboard = [self pasteboardWithObjects:@[[NSURL fileURLWithPath:@"/tmp/a b.txt"], [NSURL fileURLWithPath:@"/tmp/c.rtf"]]];
    XCTAssertTrue([controller addNotesFromPasteboard:pasteboard]);
    XCTAssertEqualObjects(storage.openedPaths, (@[@"/tmp/a b.txt", @"/tmp/c.rtf"]));
}
- (void)testFileURLsPasteAsLinks {
    PasteboardController *controller = [[[PasteboardController alloc] initWithStorage:[[[PasteboardStorage alloc] init] autorelease]] autorelease];
    NSPasteboard *pasteboard = [self pasteboardWithObjects:@[[NSURL fileURLWithPath:@"/tmp/a b.txt"], [NSURL fileURLWithPath:@"/tmp/c.rtf"]]];
    XCTAssertEqualObjects([controller stringWithNoteURLsOnPasteboard:pasteboard], @"<file:///tmp/a%20b.txt>\n<file:///tmp/c.rtf>");
}
- (void)testWebURLsAreNotFilePaths {
    NSPasteboard *pasteboard = [self pasteboardWithObjects:@[[NSURL URLWithString:@"https://example.com/a.txt"]]];
    XCTAssertEqualObjects(NVFilePathsOnPasteboard(pasteboard), @[]);
}
@end
