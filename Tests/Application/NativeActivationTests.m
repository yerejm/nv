#import <XCTest/XCTest.h>
#import "AppController.h"
#import "GlobalPrefs.h"

@interface ActivationApplication : NSObject
@property(nonatomic) BOOL active;
@property(nonatomic) NSUInteger hides;
@property(nonatomic) NSUInteger activations;
@end
@implementation ActivationApplication
- (BOOL)isActive { return self.active; }
- (void)hide:(id)sender { self.hides++; }
- (void)activateIgnoringOtherApps:(BOOL)force { self.activations++; }
@end
@interface ActivationWindow : NSObject
@property(nonatomic) BOOL main;
@property(nonatomic) BOOL activeSpace;
@property(nonatomic) NSUInteger orders;
@end
@implementation ActivationWindow
- (BOOL)isMainWindow { return self.main; }
- (BOOL)isOnActiveSpace { return self.activeSpace; }
- (NSInteger)windowNumber { return -1; }
- (void)makeKeyAndOrderFront:(id)sender { self.orders++; }
@end
@interface ActivationController : AppController
@property(nonatomic) NSUInteger selections;
- (id)initWithWindow:(ActivationWindow *)testWindow;
@end
@implementation ActivationController
- (id)initWithWindow:(ActivationWindow *)testWindow {
    if ((self = [super init])) window = (id)testWindow;
    return self;
}
- (void)_expandToolbar {}
- (void)setEmptyViewState:(BOOL)empty {}
@end
@interface NativeActivationTests : XCTestCase
@end
@implementation NativeActivationTests
- (void)testDesktopPreferencesKeepApplicationReachable {
    GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
    BOOL dock = prefs.showDockIcon, menu = prefs.showMenuBarIcon;
    @try {
        [prefs setShowDockIcon:NO sender:nil];
        XCTAssertTrue(prefs.showMenuBarIcon);
        [prefs setShowMenuBarIcon:NO sender:nil];
        XCTAssertTrue(prefs.showDockIcon);
    } @finally {
        [prefs setShowDockIcon:dock sender:nil];
        [prefs setShowMenuBarIcon:menu sender:nil];
    }
}
- (void)testActiveMainWindowTogglesHidden {
    NSApplication *original = NSApp;
    ActivationApplication *application = [[[ActivationApplication alloc] init] autorelease];
    application.active = YES;
    ActivationWindow *window = [[[ActivationWindow alloc] init] autorelease];
    window.main = YES;
    window.activeSpace = YES;
    ActivationController *controller = [[[ActivationController alloc] initWithWindow:window] autorelease];
    @try {
        NSApp = (id)application;
        [controller toggleNVActivation:nil];
        XCTAssertEqual(application.hides, 1U);
        XCTAssertEqual(application.activations, 0U);
    } @finally { NSApp = original; }
}
- (void)testInactiveWindowActivatesAndOrdersFront {
    NSApplication *original = NSApp;
    ActivationApplication *application = [[[ActivationApplication alloc] init] autorelease];
    ActivationWindow *window = [[[ActivationWindow alloc] init] autorelease];
    window.activeSpace = YES;
    ActivationController *controller = [[[ActivationController alloc] initWithWindow:window] autorelease];
    @try {
        NSApp = (id)application;
        [controller toggleNVActivation:nil];
        XCTAssertEqual(application.activations, 1U);
        XCTAssertEqual(window.orders, 1U);
        XCTAssertEqual(application.hides, 0U);
    } @finally { NSApp = original; }
}
@end
