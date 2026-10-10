#import <XCTest/XCTest.h>
#import "BookmarksController.h"
#import "NSString_NV.h"

@interface BookmarkTests : XCTestCase
@end
@implementation BookmarkTests
- (void)testBookmarkWithoutSearchStringSurvivesItsDictionaryRepresentation {
    CFUUIDBytes bytes = [@"6F1C2A4E-8B3D-4F5A-9C7E-1D2B3A4C5E6F" uuidBytes];
    NoteBookmark *bookmark = [[NoteBookmark alloc] initWithNoteUUIDBytes:bytes searchString:nil];

    NSDictionary *representation = [bookmark dictionaryRep];
    NoteBookmark *restored = [[NoteBookmark alloc] initWithDictionary:representation];

    XCTAssertNotNil(restored);
    XCTAssertEqualObjects([restored searchString], @"");
    XCTAssertEqualObjects(representation[@"NoteUUIDString"], [NSString uuidStringWithBytes:bytes]);
}
@end
