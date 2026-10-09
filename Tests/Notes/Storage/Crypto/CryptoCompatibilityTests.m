#import <XCTest/XCTest.h>
#import "TestPaths.h"
#import "NSData_transformations.h"
#import "NVMD5.h"
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
- (NSData *)utf8:(NSString *)string {
    return [string dataUsingEncoding:NSUTF8StringEncoding];
}
- (void)testPBKDF2PublishedVectors {
    NSData *password = [self utf8:@"password"], *salt = [self utf8:@"salt"];
    NSArray *vectors = @[
        @[@1, @"0c60c80f961f0e71f3a9b524af6012062fe037a6"],
        @[@2, @"ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957"],
        @[@4096, @"4b007901b765489abead49d926f721d065a429c1"]
    ];
    for (NSArray *vector in vectors) {
        XCTAssertEqualObjects([self hex:[password derivedKeyOfLength:20 salt:salt iterations:[vector[0] intValue]]], vector[1]);
    }
    NSData *multiBlock = [[self utf8:@"passwordPASSWORDpassword"] derivedKeyOfLength:25 salt:[self utf8:@"saltSALTsaltSALTsaltSALTsaltSALTsalt"] iterations:4096];
    XCTAssertEqualObjects([self hex:multiBlock], @"3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038");
    NSData *embeddedNul = [[NSData dataWithBytes:"pass\0word" length:9] derivedKeyOfLength:16 salt:[NSData dataWithBytes:"sa\0lt" length:5] iterations:4096];
    XCTAssertEqualObjects([self hex:embeddedNul], @"56fa6aa75548099dcc37d7f03425e0c3");
}
- (void)testPBKDF2SHA256AndHMACPublishedVectors {
    NSData *password = [self utf8:@"password"], *salt = [self utf8:@"salt"];
    XCTAssertEqualObjects([self hex:[password derivedKeyOfLength:32 salt:salt iterations:1 PRF:kCCPRFHmacAlgSHA256]],
                          @"120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
    XCTAssertEqualObjects([self hex:[password derivedKeyOfLength:32 salt:salt iterations:4096 PRF:kCCPRFHmacAlgSHA256]],
                          @"c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");
    XCTAssertEqualObjects([self hex:NVHMACSHA256([self utf8:@"Jefe"], [self utf8:@"what do ya "], [self utf8:@"want for nothing?"])],
                          @"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
}
- (void)testPurposeSubkeysMatchIndependentDerivation {
    NSData *key = [NSMutableData dataWithLength:32];
    XCTAssertEqualObjects([self hex:[key subkeyForPurpose:"Notational Velocity journal encryption" salt:nil]],
                          @"cf8504d6f5131d825c1ed9d79eb3ce593ed30cf8f706b54afc44b6510cef0f5f");
    XCTAssertEqualObjects([self hex:[key subkeyForPurpose:"Notational Velocity database authentication" salt:[self utf8:@"salt"]]],
                          @"49f12573852e71b73a00a981def41fb58d4e5925270576dab19ed9988678c91b");
}
- (void)testTimingSafeComparison {
    XCTAssertTrue(NVTimingSafeEqualData([self utf8:@"tag"], [self utf8:@"tag"]));
    XCTAssertFalse(NVTimingSafeEqualData([self utf8:@"tag"], [self utf8:@"taG"]));
    XCTAssertFalse(NVTimingSafeEqualData([self utf8:@"tag"], [self utf8:@"tags"]));
    XCTAssertFalse(NVTimingSafeEqualData(nil, nil));
}
- (void)testPBKDF2RejectsZeroIterations {
    XCTAssertNil([[self utf8:@"password"] derivedKeyOfLength:32 salt:[self utf8:@"salt"] iterations:0]);
}
- (NSString *)legacyMD5:(NSData *)data {
    NVMD5_CTX context;
    unsigned char digest[16];
    NVMD5Init(&context);
    NVMD5Update(&context, data.bytes, (unsigned)data.length);
    NVMD5Final(digest, &context);
    return [self hex:[NSData dataWithBytes:digest length:sizeof(digest)]];
}
- (void)testLegacyDigestsAcrossBlockBoundaries {
    NSDictionary *md5 = @{
        @"": @"d41d8cd98f00b204e9800998ecf8427e",
        @"abc": @"900150983cd24fb0d6963f7d28e17f72",
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789": @"d174ab98d277d9f5a5611c2c9f419d9f",
        @"12345678901234567890123456789012345678901234567890123456789012345678901234567890": @"57edf4a22be3c955ac49da2e2107b67a"
    };
    NSDictionary *sha1 = @{
        @"": @"da39a3ee5e6b4b0d3255bfef95601890afd80709",
        @"abc": @"a9993e364706816aba3e25717850c26c9cd0d89d",
        @"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq": @"84983e441c3bd26ebaae4aa1f95129e5e54670f1"
    };
    for (NSString *input in md5) XCTAssertEqualObjects([self legacyMD5:[self utf8:input]], md5[input]);
    for (NSString *input in sha1) XCTAssertEqualObjects([self hex:[[self utf8:input] SHA1Digest]], sha1[input]);
    NSMutableData *millionAs = [NSMutableData dataWithLength:1000000];
    memset(millionAs.mutableBytes, 'a', millionAs.length);
    XCTAssertEqualObjects([self legacyMD5:millionAs], @"7707d6ae4e027c70eea2a935c2296f21");
    XCTAssertEqualObjects([self hex:[millionAs SHA1Digest]], @"34aa973cd4c4daa4f61eeb2bdbad27316534016f");
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
