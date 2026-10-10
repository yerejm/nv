#import <XCTest/XCTest.h>
#import "TestPaths.h"
#import "DeletedNoteObject.h"

@interface DeletedNoteObjectTests : XCTestCase
@end

@implementation DeletedNoteObjectTests
- (NSData *)fixture:(NSString *)name {
    NSData *data = [NSData dataWithContentsOfFile:NVFixturePath(name)];
    XCTAssertNotNil(data);
    return data;
}
- (void)assertDeletion:(DeletedNoteObject *)note {
    XCTAssertTrue([note isKindOfClass:[DeletedNoteObject class]]);
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, *[note uniqueNoteIDBytes]);
    NSString *identity = CFBridgingRelease(CFUUIDCreateString(NULL, uuid));
    CFRelease(uuid);
    XCTAssertEqualObjects(identity, @"00112233-4455-6677-8899-AABBCCDDEEFF");
    XCTAssertEqual([note logSequenceNumber], 42U);
    XCTAssertEqualObjects([note syncServicesMD][@"Simplenote"][@"key"], @"sanitized-retired-id");
    XCTAssertNil([note originalNote]);
}
- (void)testLegacyKeyedDeletionArchive {
    [self assertDeletion:NVUnarchiveObject([self fixture:@"deleted-keyed.archive"], [DeletedNoteObject class])];
}
- (void)testLegacyPositionalDeletionArchive {
    [self assertDeletion:NVUnarchiveLegacyObject([self fixture:@"deleted-positional.archive"])];
}
- (void)testDeletionIdentityHashAndJournalSequence {
    DeletedNoteObject *first = NVUnarchiveObject([self fixture:@"deleted-keyed.archive"], [DeletedNoteObject class]);
    DeletedNoteObject *second = NVUnarchiveLegacyObject([self fixture:@"deleted-positional.archive"]);
    XCTAssertEqualObjects(first, second);
    XCTAssertEqual(first.hash, second.hash);
    XCTAssertEqual(([NSSet setWithObjects:first, second, nil].count), 1U);
    [second incrementLSN];
    XCTAssertTrue([first youngerThanLogObject:second]);
    XCTAssertFalse([second youngerThanLogObject:first]);
}
@end
