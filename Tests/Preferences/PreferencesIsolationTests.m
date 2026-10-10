#import <XCTest/XCTest.h>

@interface PreferencesIsolationTests : XCTestCase
@property(nonatomic, retain) NSString *temporaryDirectory;
@end

@implementation PreferencesIsolationTests
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
- (void)testPreferencesUseIsolatedSuite {
    NSString *suite = [@"net.notational.velocity.tests." stringByAppendingString:[[NSUUID UUID] UUIDString]];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults setObject:self.temporaryDirectory forKey:@"NotesDirectory"];
    XCTAssertEqualObjects([defaults stringForKey:@"NotesDirectory"], self.temporaryDirectory);
    [defaults removePersistentDomainForName:suite];
}
@end
