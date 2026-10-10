#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "LinkingEditor.h"

@interface CursorFixture : LinkingEditor
- (void)setInside:(BOOL)inside;
@end
@implementation CursorFixture
- (void)setInside:(BOOL)inside {
    mouseInside = inside;
}
@end

@interface CursorTests : XCTestCase
@end
@implementation CursorTests
- (void)testDarkBackgroundKeepsSystemIBeam {
    [NSApplication sharedApplication];
    CursorFixture *editor = [[CursorFixture alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    IMP original = method_getImplementation(class_getClassMethod([NSCursor class], @selector(IBeamCursor)));
    [editor setBackgroundColor:[NSColor blackColor]];
    [editor setInside:YES];
    [editor fixCursorForBackgroundUpdatingMouseInside:NO];
    XCTAssertEqual(method_getImplementation(class_getClassMethod([NSCursor class], @selector(IBeamCursor))), original);
    XCTAssertEqualObjects([NSCursor currentCursor], [NSCursor IBeamCursor]);
}
- (void)testCursorRectsCanRefreshAfterAppearanceAndVisibilityChanges {
    [NSApplication sharedApplication];
    CursorFixture *editor = [[CursorFixture alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];
    [window setContentView:editor];
    [editor setBackgroundColor:[NSColor blackColor]];
    [editor setInside:YES];
    XCTAssertNoThrow([editor resetCursorRects]);
    [editor setHidden:YES];
    XCTAssertNoThrow([editor fixCursorForBackgroundUpdatingMouseInside:NO]);
    [editor setHidden:NO];
    [editor setBackgroundColor:[NSColor whiteColor]];
    [editor setInside:NO];
    XCTAssertNoThrow([editor resetCursorRects]);
    [window close];
}
@end
