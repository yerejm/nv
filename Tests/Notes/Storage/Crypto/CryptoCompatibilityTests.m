#import <XCTest/XCTest.h>
#import "TestPaths.h"
#import "pbkdf2.h"
#import "broken_md5.h"

@interface CryptoCompatibilityTests : XCTestCase
@end

@implementation CryptoCompatibilityTests
- (NSData *)fixture:(NSString *)name {
    NSData *data = [NSData dataWithContentsOfFile:NVFixturePath(name)];
    XCTAssertNotNil(data);
    return data;
}
- (NSString *)hex:(NSData *)data {
    NSMutableString *result = [NSMutableString string];
    const unsigned char *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) [result appendFormat:@"%02x", bytes[index]];
    return result;
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
@end
