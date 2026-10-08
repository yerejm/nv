#import <XCTest/XCTest.h>
#import "TestPaths.h"
#import "AttributedPlainText.h"
#import "NSString_NV.h"

@interface HyperlinkTests : XCTestCase
@end
@implementation HyperlinkTests
- (NSArray *)links:(NSAttributedString *)text {
    NSMutableArray *links = [NSMutableArray array];
    [text enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0, text.length) options:0 usingBlock:^(NSURL *url, NSRange range, BOOL *stop) {
        if (url) [links addObject:@{ @"start": @(range.location), @"length": @(range.length), @"text": [text.string substringWithRange:range], @"url": url.absoluteString }];
    }];
    return links;
}
- (void)testSaved77CasePolicy {
    NSString *fixture = NVFixturePath(@"hyperlink-policy.json");
    NSArray *cases = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:fixture] options:0 error:NULL];
    XCTAssertEqual(cases.count, 77U);
    for (NSDictionary *entry in cases) {
        NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:entry[@"input"]] autorelease];
        [text addLinkAttributesForRange:NSMakeRange(0, text.length)];
        XCTAssertEqualObjects([self links:text], entry[@"matches"], @"case %@", entry[@"id"]);
    }
}
- (void)testIncrementalUTF16RangeAndUntouchedLine {
    NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:@"😀 https://example.com\nsecond https://example.org"] autorelease];
    [text addLinkAttributesForRange:NSMakeRange(0, text.length)];
    NSURL *first = [text attribute:NSLinkAttributeName atIndex:3 effectiveRange:NULL];
    NSRange changed = [text.string rangeOfString:@"example.org"];
    [text replaceCharactersInRange:changed withString:@"example.net"];
    NSRange line = [text.string lineRangeForRange:changed];
    [text removeAttribute:NSLinkAttributeName range:line];
    [text addLinkAttributesForRange:line];
    NSArray *links = [self links:text];
    XCTAssertEqual(links.count, 2U);
    XCTAssertEqualObjects([text attribute:NSLinkAttributeName atIndex:3 effectiveRange:NULL], first);
    XCTAssertEqualObjects(links[1][@"url"], @"https://example.net");
    XCTAssertEqualObjects(links[0][@"start"], @3);
}
- (void)testWikiPrecedenceAndEmptyWikiSafety {
    NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:@"[[]] [[https://example.com]] [[Project Alpha]]"] autorelease];
    [text addLinkAttributesForRange:NSMakeRange(0, text.length)];
    NSArray *links = [self links:text];
    XCTAssertEqual(links.count, 2U);
    XCTAssertTrue([links[0][@"url"] hasPrefix:@"nv://find/"]);
    XCTAssertEqualObjects(links[1][@"url"], @"nv://find/Project%20Alpha");
}
- (void)testURLsStopAtUnbalancedSquareBrackets {
    for (NSArray *entry in @[@[@"https://example.com] after", @"https://example.com"], @[@"https://example.com/a]]b", @"https://example.com/a"],
                             @[@"https://[2001:db8::1]/path] after", @"https://[2001:db8::1]/path"]]) {
        NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:entry[0]] autorelease];
        [text addLinkAttributesForRange:NSMakeRange(0, text.length)];
        NSArray *links = [self links:text];
        XCTAssertEqual(links.count, 1U, @"%@", entry[0]);
        XCTAssertEqualObjects(links.firstObject[@"text"], entry[1]);
        XCTAssertEqualObjects(links.firstObject[@"url"], entry[1]);
    }
}
- (void)testEncodedUUIDQueryRetainsIdentity {
    NSString *input = @"nv://find/Title/?NV=ABEiM0RVZneImaq7zN3u%2Fw%3D%3D";
    NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:input] autorelease];
    [text addLinkAttributesForRange:NSMakeRange(0, text.length)];
    NSURL *url = [text attribute:NSLinkAttributeName atIndex:0 effectiveRange:NULL];
    NSString *encoded = [[url.query componentsSeparatedByString:@"NV="] lastObject];
    NSData *identity = [[encoded stringByReplacingPercentEscapes] decodeBase64WithNewlines:NO];
    CFUUIDBytes bytes = [@"00112233-4455-6677-8899-AABBCCDDEEFF" uuidBytes];
    XCTAssertEqualObjects(identity, [NSData dataWithBytes:&bytes length:sizeof(bytes)]);
}
- (void)testLargeNoteDetection {
    NSMutableString *body = [NSMutableString string];
    for (NSUInteger index = 0; index < 4000; index++) [body appendString:@"ordinary prose https://example.com/path\n"];
    NSMutableAttributedString *text = [[[NSMutableAttributedString alloc] initWithString:body] autorelease];
    NSDate *start = [NSDate date];
    [text addLinkAttributesForRange:NSMakeRange(0, text.length)];
    XCTAssertEqual([self links:text].count, 4000U);
    XCTAssertLessThan(-start.timeIntervalSinceNow, 5.0);
}
@end
