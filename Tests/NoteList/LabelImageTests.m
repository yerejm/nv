#import <XCTest/XCTest.h>
#import "LabelsListController.h"

@interface LabelImageTests : XCTestCase
@end
@implementation LabelImageTests
- (NSBitmapImageRep *)bitmapOfImage:(NSImage *)image scale:(CGFloat)scale {
    NSSize size = image.size;
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(size.width * scale)
        pixelsHigh:(NSInteger)(size.height * scale) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    bitmap.size = size;
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [image drawInRect:(NSRect){NSZeroPoint, size}];
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}
- (void)testLabelImageIsDrawnOnDemandWithTextKnockedOutOfItsFill {
    [NSApplication sharedApplication];
    LabelsListController *labels = [[LabelsListController alloc] init];
    NSImage *image = [labels cachedLabelImageForWord:@"Project" highlighted:NO];
    XCTAssertEqual(image, [labels cachedLabelImageForWord:@"project" highlighted:NO]);
    XCTAssertGreaterThan(image.size.width, 0);
    XCTAssertGreaterThan(image.size.height, 0);
    //drawn on demand at the destination's scale rather than cached as a bitmap
    XCTAssertEqual(image.representations.count, 1U);
    XCTAssertTrue([image.representations.firstObject isKindOfClass:[NSCustomImageRep class]]);

    NSBitmapImageRep *bitmap = [self bitmapOfImage:image scale:2];
    NSUInteger filled = 0, knockedOut = 0;
    for (NSInteger y = 6; y < bitmap.pixelsHigh - 6; y++) {
        for (NSInteger x = 6; x < bitmap.pixelsWide - 6; x++) {
            CGFloat alpha = [bitmap colorAtX:x y:y].alphaComponent;
            if (alpha > 0.95) filled++;
            else if (alpha < 0.05) knockedOut++;
        }
    }
    XCTAssertGreaterThan(filled, 0U);
    XCTAssertGreaterThan(knockedOut, 0U);
}
@end
