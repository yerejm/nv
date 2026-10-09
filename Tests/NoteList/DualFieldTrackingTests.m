#import <XCTest/XCTest.h>
#import "DualField.h"

@interface DualFieldTrackingTests : XCTestCase
@end
@implementation DualFieldTrackingTests
- (NSArray *)iconAreasOfField:(DualField *)field {
    NSRect iconRect = [[field cell] snapbackButtonRectForBounds:field.bounds];
    return [field.trackingAreas filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSTrackingArea *area, NSDictionary *bindings) {
        return area.owner == field && NSEqualRects(area.rect, iconRect);
    }]];
}
- (NSEvent *)event:(NSEventType)type forArea:(NSTrackingArea *)area inWindow:(NSWindow *)window {
    return [NSEvent enterExitEventWithType:type location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber
                                   context:nil eventNumber:0 trackingNumber:(NSInteger)area userData:NULL];
}
- (void)testIconTrackingAreaFollowsResizesAndTogglesTheSnapbackButton {
    [NSApplication sharedApplication];
    NSWindow *window = [[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 100) styleMask:NSWindowStyleMaskTitled
                                                      backing:NSBackingStoreBuffered defer:NO] autorelease];
    window.releasedWhenClosed = NO;
    DualField *field = [[[DualField alloc] initWithFrame:NSMakeRect(10, 10, 300, 22)] autorelease];
    [field awakeFromNib];
    [window.contentView addSubview:field];
    [field updateTrackingAreas];
    XCTAssertEqual([self iconAreasOfField:field].count, 1U);

    [field setFrame:NSMakeRect(10, 10, 360, 40)];
    [field updateTrackingAreas];
    NSArray *areas = [self iconAreasOfField:field];
    XCTAssertEqual(areas.count, 1U);
    XCTAssertEqual([field.trackingAreas indexesOfObjectsPassingTest:^BOOL(NSTrackingArea *area, NSUInteger i, BOOL *stop) {
        return area.owner == field;
    }].count, 1U);

    NSTrackingArea *area = areas.firstObject;
    DualFieldCell *cell = [field cell];
    [field setShowsDocumentIcon:YES];
    [field mouseEntered:[self event:NSEventTypeMouseEntered forArea:area inWindow:window]];
    XCTAssertTrue([cell snapbackButtonIsVisible]);
    [field mouseExited:[self event:NSEventTypeMouseExited forArea:area inWindow:window]];
    XCTAssertFalse([cell snapbackButtonIsVisible]);
    [window close];
}
@end
