#import <XCTest/XCTest.h>
#import "DeletedNoteObject.h"
#import "pbkdf2.h"
#import "broken_md5.h"

@interface CompatibilityTests : XCTestCase
@property(nonatomic, retain) NSString *temporaryDirectory;
@end

@implementation CompatibilityTests
- (void)setUp {
    [super setUp];
    self.temporaryDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.temporaryDirectory withIntermediateDirectories:YES attributes:nil error:NULL]);
}
- (void)tearDown {
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:self.temporaryDirectory error:NULL]);
    self.temporaryDirectory = nil;
    [super tearDown];
}
- (NSData *)fixture:(NSString *)name {
    NSString *testDirectory = [@__FILE__ stringByDeletingLastPathComponent];
    NSData *data = [NSData dataWithContentsOfFile:[testDirectory stringByAppendingPathComponent:[@"Fixtures" stringByAppendingPathComponent:name]]];
    XCTAssertNotNil(data);
    return data;
}
- (NSString *)hex:(NSData *)data {
    NSMutableString *result = [NSMutableString string];
    const unsigned char *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) [result appendFormat:@"%02x", bytes[index]];
    return result;
}
- (void)assertDeletion:(DeletedNoteObject *)note {
    XCTAssertTrue([note isKindOfClass:[DeletedNoteObject class]]);
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, *[note uniqueNoteIDBytes]);
    NSString *identity = [(NSString *)CFUUIDCreateString(NULL, uuid) autorelease];
    CFRelease(uuid);
    XCTAssertEqualObjects(identity, @"00112233-4455-6677-8899-AABBCCDDEEFF");
    XCTAssertEqual([note logSequenceNumber], 42U);
    XCTAssertEqualObjects([note syncServicesMD][@"Simplenote"][@"key"], @"sanitized-retired-id");
    XCTAssertNil([note originalNote]);
}
- (void)testLegacyKeyedDeletionArchive {
    [self assertDeletion:[NSKeyedUnarchiver unarchiveObjectWithData:[self fixture:@"deleted-keyed.archive"]]];
}
- (void)testLegacyPositionalDeletionArchive {
    [self assertDeletion:[NSUnarchiver unarchiveObjectWithData:[self fixture:@"deleted-positional.archive"]]];
}
- (void)testDeletionIdentityHashAndJournalSequence {
    DeletedNoteObject *first = [NSKeyedUnarchiver unarchiveObjectWithData:[self fixture:@"deleted-keyed.archive"]];
    DeletedNoteObject *second = [NSUnarchiver unarchiveObjectWithData:[self fixture:@"deleted-positional.archive"]];
    XCTAssertEqualObjects(first, second);
    XCTAssertEqual(first.hash, second.hash);
    XCTAssertEqual(([NSSet setWithObjects:first, second, nil].count), 1U);
    [second incrementLSN];
    XCTAssertTrue([first youngerThanLogObject:second]);
    XCTAssertFalse([second youngerThanLogObject:first]);
}
- (void)testPBKDF2PublishedVectors {
    NSArray *vectors = @[
        @[@1, @"0c60c80f961f0e71f3a9b524af6012062fe037a6"],
        @[@2, @"ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957"],
        @[@4096, @"4b007901b765489abead49d926f721d065a429c1"]
    ];
    for (NSArray *vector in vectors) {
        unsigned char bytes[20];
        XCTAssertTrue(pbkdf2_sha1("password", 8, "salt", 4, [vector[0] unsignedIntValue], (char *)bytes, sizeof(bytes)));
        XCTAssertEqualObjects([self hex:[NSData dataWithBytes:bytes length:sizeof(bytes)]], vector[1]);
    }
}
- (void)testPBKDF2RejectsZeroIterations {
    char bytes[32];
    XCTAssertFalse(pbkdf2_sha1("password", 8, "salt", 4, 0, bytes, sizeof(bytes)));
}
- (void)testLegacyBrokenMD5Fixture {
    const unsigned char input[] = "legacy import: café 日本語";
    unsigned char digest[16];
    BrokenMD5_CTX context;
    BrokenMD5Init(&context);
    BrokenMD5Update(&context, input, sizeof(input) - 1);
    BrokenMD5Final(digest, &context);
    NSString *expected = [[[NSString alloc] initWithData:[self fixture:@"broken-md5.txt"] encoding:NSUTF8StringEncoding] autorelease];
    XCTAssertEqualObjects([self hex:[NSData dataWithBytes:digest length:sizeof(digest)]], expected);
}
- (void)testPreferencesUseIsolatedSuite {
    NSString *suite = [@"net.notational.velocity.tests." stringByAppendingString:[[NSUUID UUID] UUIDString]];
    NSUserDefaults *defaults = [[[NSUserDefaults alloc] initWithSuiteName:suite] autorelease];
    [defaults setObject:self.temporaryDirectory forKey:@"NotesDirectory"];
    XCTAssertEqualObjects([defaults stringForKey:@"NotesDirectory"], self.temporaryDirectory);
    [defaults removePersistentDomainForName:suite];
}
@end
