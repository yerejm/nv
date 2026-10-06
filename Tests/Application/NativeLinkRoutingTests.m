#import <XCTest/XCTest.h>
#import "AppController.h"
#import "AppController_Importing.h"
#import "NSString_NV.h"
#import "NSData_transformations.h"

@interface RoutingStorage : NSObject
@property(nonatomic) NSUInteger lookups;
@property(nonatomic, retain) NSData *identity;
@end
@implementation RoutingStorage
- (id)noteForUUIDBytes:(CFUUIDBytes *)bytes {
    self.lookups++;
    if (bytes) self.identity = [NSData dataWithBytes:bytes length:16];
    return nil;
}
@end
@interface RoutingController : AppController
- (id)initWithStorage:(RoutingStorage *)storage;
@end
@implementation RoutingController
- (id)initWithStorage:(RoutingStorage *)storage {
    if ((self = [super init])) notationController = (id)storage;
    return self;
}
- (void)searchForString:(NSString *)search {}
@end
@interface NativeLinkRoutingTests : XCTestCase
@end
@implementation NativeLinkRoutingTests
- (void)testEncodedUUIDRoutesAfterTitleChanges {
    RoutingStorage *storage = [[[RoutingStorage alloc] init] autorelease];
    RoutingController *controller = [[[RoutingController alloc] initWithStorage:storage] autorelease];
    CFUUIDBytes uuid = [@"00112233-4455-6677-8899-AABBCCDDEEFF" uuidBytes];
    NSData *identity = [NSData dataWithBytes:&uuid length:16];
    NSString *encoded = [[identity encodeBase64WithNewlines:NO] stringWithPercentEscapes];
    XCTAssertTrue([controller interpretNVURL:[NSURL URLWithString:[@"nv://find/Old%20title/?NV=" stringByAppendingString:encoded]]]);
    XCTAssertEqual(storage.lookups, 1U);
    XCTAssertEqualObjects(storage.identity, identity);
}
- (void)testMalformedUUIDDoesNotReadBeyondDecodedData {
    RoutingStorage *storage = [[[RoutingStorage alloc] init] autorelease];
    RoutingController *controller = [[[RoutingController alloc] initWithStorage:storage] autorelease];
    for (NSString *value in @[@"?", @"AA==", @"AAAA", @"!!!!!!!!!!!!!!!!!!"]) {
        XCTAssertTrue([controller interpretNVURL:[NSURL URLWithString:[@"nv://find/title/?NV=" stringByAppendingString:value]]]);
    }
    XCTAssertEqual(storage.lookups, 0U);
}
@end
