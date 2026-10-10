#import <XCTest/XCTest.h>
#import "TestPaths.h"
#import "NSData_transformations.h"
#import "NSString_NV.h"

NSData *NVVolumeUUIDForName(NSData *name);

@interface CryptoTests : XCTestCase
@end
@implementation CryptoTests
- (NSData *)bytesFromHex:(NSString *)hex {
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger index = 0; index < hex.length; index += 2) {
        unsigned int value = 0;
        [[NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(index, 2)]] scanHexInt:&value];
        unsigned char byte = value;
        [data appendBytes:&byte length:1];
    }
    return data;
}
- (NSArray *)aesVectors {
    NSString *fixture = NVFixturePath(@"crypto-vectors.json");
    NSDictionary *vectors = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:fixture] options:0 error:NULL];
    XCTAssertNotNil(vectors);
    return vectors[@"aes"];
}
- (void)testDecryptsFixedLegacyCiphertext {
    for (NSDictionary *vector in [self aesVectors]) {
        NSMutableData *ciphertext = [[self bytesFromHex:vector[@"ciphertext"]] mutableCopy];
        XCTAssertTrue([ciphertext decryptAESDataWithKey:[self bytesFromHex:vector[@"key"]] iv:[self bytesFromHex:vector[@"iv"]]]);
        XCTAssertEqualObjects(ciphertext, [self bytesFromHex:vector[@"plaintext"]]);
    }
}
- (void)testEncryptionMatchesLegacyCiphertext {
    for (NSDictionary *vector in [self aesVectors]) {
        NSMutableData *plaintext = [[self bytesFromHex:vector[@"plaintext"]] mutableCopy];
        XCTAssertTrue([plaintext encryptAESDataWithKey:[self bytesFromHex:vector[@"key"]] iv:[self bytesFromHex:vector[@"iv"]]]);
        XCTAssertEqualObjects(plaintext, [self bytesFromHex:vector[@"ciphertext"]]);
    }
}
- (void)testInvalidPaddingAndLengthsRejectWithoutChangingData {
    NSDictionary *vector = [self aesVectors][1];
    NSData *original = [self bytesFromHex:@"5a6e045708fb7196f02e553d02c3a692"];
    NSMutableData *ciphertext = [original mutableCopy];
    NSData *iv = [self bytesFromHex:vector[@"iv"]];
    XCTAssertFalse([ciphertext decryptAESDataWithKey:[self bytesFromHex:vector[@"key"]] iv:iv]);
    XCTAssertEqualObjects(ciphertext, original);
    XCTAssertFalse([ciphertext decryptAESDataWithKey:[NSMutableData dataWithLength:31] iv:iv]);
    XCTAssertEqualObjects(ciphertext, original);
    XCTAssertFalse([ciphertext encryptAESDataWithKey:[self bytesFromHex:vector[@"key"]] iv:[NSMutableData dataWithLength:15]]);
    XCTAssertEqualObjects(ciphertext, original);
}
- (void)testRandomDataIsFreshEachTime {
    NSData *first = [NSData randomDataOfLength:256];
    NSData *second = [NSData randomDataOfLength:256];
    XCTAssertEqual(first.length, 256U);
    XCTAssertEqual(second.length, 256U);
    XCTAssertNotEqualObjects(first, second);
}
- (void)testBase64LineWrappingAndUUID {
    NSData *input = [@"foo" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqualObjects([input encodeBase64], @"Zm9v\n");
    XCTAssertEqualObjects([input encodeBase64WithNewlines:NO], @"Zm9v");
    XCTAssertEqualObjects([@"Zm9v\n" decodeBase64], input);
    XCTAssertEqualObjects([@"Zm9v" decodeBase64WithNewlines:NO], input);
    XCTAssertEqualObjects([[NSData data] encodeBase64], @"");
    NSData *longInput = [NSMutableData dataWithLength:49];
    NSString *encoded = [longInput encodeBase64];
    NSArray *lines = [encoded componentsSeparatedByString:@"\n"];
    XCTAssertEqual([lines[0] length], 64U);
    XCTAssertEqual([lines[1] length], 4U);
    XCTAssertEqualObjects([encoded decodeBase64], longInput);
    CFUUIDBytes bytes = [@"00112233-4455-6677-8899-AABBCCDDEEFF" uuidBytes];
    NSData *identity = [NSData dataWithBytes:&bytes length:sizeof(bytes)];
    XCTAssertEqualObjects([identity encodeBase64WithNewlines:NO], @"ABEiM0RVZneImaq7zN3u/w==");
    XCTAssertEqualObjects([@"ABEiM0RVZneImaq7zN3u/w==" decodeBase64WithNewlines:NO], identity);
}
- (void)testLegacyCompressionTrailer {
    NSData *input = [@"Retained note: café 日本語\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *compressed = [input compressedData];
    uint32_t length = NSSwapHostIntToBig((uint32_t)input.length);
    XCTAssertEqualObjects([compressed subdataWithRange:NSMakeRange(compressed.length - 4, 4)], [NSData dataWithBytes:&length length:4]);
    XCTAssertEqualObjects([compressed uncompressedData], input);
}
- (void)testLegacyVolumeIdentity {
    NSArray *names = @[@"0000000000000000", @"0001020304050607", @"ffffffffffffffff"];
    NSArray *identities = @[@"a97c9eaf-e18f-3be3-80cd-8a8c6fb6e8e7", @"a7cc4235-c97b-3eab-82d0-791629076ab6", @"c91b7f5d-b692-32dd-9835-a33a972c901c"];
    for (NSUInteger index = 0; index < names.count; index++) {
        CFUUIDBytes expected = [identities[index] uuidBytes];
        XCTAssertEqualObjects(NVVolumeUUIDForName([self bytesFromHex:names[index]]), [NSData dataWithBytes:&expected length:sizeof(expected)]);
    }
}
@end
