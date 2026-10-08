#import <XCTest/XCTest.h>
#import "GlobalPrefs.h"
#import "NSString_CustomTruncation.h"

@interface PreviewTruncationTests : XCTestCase
@end

@implementation PreviewTruncationTests

- (NSAttributedString *)body:(NSString *)unit repeated:(NSUInteger)count {
    return [[[NSAttributedString alloc] initWithString:[@"" stringByPaddingToLength:unit.length * count withString:unit startingAtIndex:0]] autorelease];
}

- (CGFloat)widthOf:(NSString *)string {
    NSFont *font = [NSFont systemFontOfSize:[[GlobalPrefs defaultPrefs] tableFontSize]];
    return [string sizeWithAttributes:@{NSFontAttributeName: font}].width;
}

- (void)testPreviewsFillTheirWidthWhateverTheScript {
    CGFloat width = 300;
    for (NSString *unit in @[@"中文预览", @"iiii ", @"Wide WWW ", @"😀👩‍👩‍👧"]) {
        NSString *single = [[@"T" attributedSingleLinePreviewFromBodyText:[self body:unit repeated:2000] upToWidth:width] string];
        XCTAssertGreaterThan([self widthOf:single], width, @"%@", unit);
        NSString *multi = [[[@"T" attributedMultiLinePreviewFromBodyText:[self body:unit repeated:2000] upToWidth:width intrusionWidth:40] string] substringFromIndex:2];
        XCTAssertGreaterThan([self widthOf:multi], width * 2, @"%@", unit);
        XCTAssertLessThan(multi.length, 2000U, @"%@", unit);
    }
}

- (void)testPreviewsKeepWholeCharactersAndFlattenLineBreaks {
    for (NSUInteger count = 1; count < 12; count++) {
        NSString *preview = [@"👩‍👩‍👧😀\n\t中 x\r\n" truncatedPreviewStringOfLength:count];
        XCTAssertNotNil([preview dataUsingEncoding:NSUTF8StringEncoding], @"%lu", (unsigned long)count);
        XCTAssertEqual([preview rangeOfCharacterFromSet:[NSCharacterSet newlineCharacterSet]].location, (NSUInteger)NSNotFound);
        XCTAssertEqual([preview rangeOfString:@"\t"].location, (NSUInteger)NSNotFound);
    }
    XCTAssertEqualObjects([@"a\nb c" truncatedPreviewStringOfLength:10], @"a b c");
}

- (void)testATitleLongerThanTheRowDoesNotPullInTheWholeBody {
    NSString *title = [@"" stringByPaddingToLength:2000 withString:@"Long title " startingAtIndex:0];
    NSAttributedString *preview = [title attributedSingleLinePreviewFromBodyText:[self body:@"body " repeated:100000] upToWidth:200];
    XCTAssertFalse([preview.string containsString:@"body"]);
    XCTAssertEqualObjects([@"text" truncatedPreviewStringOfLength:0], @"");
}

@end
