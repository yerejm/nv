#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "LinkingEditor.h"

@interface LinkingEditor (CursorTesting)
- (NSCursor *)editorCursor;
@end
@interface CursorFixture : LinkingEditor
- (void)setDarkBackground:(BOOL)dark inside:(BOOL)inside;
@end
@implementation CursorFixture
- (void)setDarkBackground:(BOOL)dark inside:(BOOL)inside {
    backgroundIsDark = dark;
    mouseInside = inside;
}
@end

@interface CursorTests : XCTestCase
@end
@implementation CursorTests
- (void)testEditorCursorDoesNotReplaceGlobalIBeam {
    [NSApplication sharedApplication];
    CursorFixture *editor = [[[CursorFixture alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)] autorelease];
    IMP original = method_getImplementation(class_getClassMethod([NSCursor class], @selector(IBeamCursor)));
    [editor setDarkBackground:YES inside:YES];
    [editor fixCursorForBackgroundUpdatingMouseInside:NO];
    XCTAssertEqual(method_getImplementation(class_getClassMethod([NSCursor class], @selector(IBeamCursor))), original);
    [editor setDarkBackground:NO inside:YES];
    XCTAssertEqualObjects([editor editorCursor], [NSCursor IBeamCursor]);
}
- (void)testCursorRectsCanRefreshAfterAppearanceAndVisibilityChanges {
    [NSApplication sharedApplication];
    CursorFixture *editor = [[[CursorFixture alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)] autorelease];
    NSWindow *window = [[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO] autorelease];
    [window setReleasedWhenClosed:NO];
    [window setContentView:editor];
    [editor setDarkBackground:YES inside:YES];
    XCTAssertNoThrow([editor resetCursorRects]);
    [editor setHidden:YES];
    XCTAssertNoThrow([editor fixCursorForBackgroundUpdatingMouseInside:NO]);
    [editor setHidden:NO];
    [editor setDarkBackground:NO inside:NO];
    XCTAssertNoThrow([editor resetCursorRects]);
    [window close];
}
@end
