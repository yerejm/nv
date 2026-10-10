#import <XCTest/XCTest.h>
#import "GlobalPrefs.h"

@interface PreferenceObserver : NSObject
@property(nonatomic, retain) NSMutableArray *selectors;
@end
@implementation PreferenceObserver
- (id)init {
    if ((self = [super init])) self.selectors = [NSMutableArray array];
    return self;
}
- (void)settingChangedForSelectorString:(NSString *)selector {
    [self.selectors addObject:selector];
}
- (void)dealloc {
}
@end

@interface CallbackTests : XCTestCase
@end
@implementation CallbackTests
- (void)testDispatchExcludesOriginalSender {
    GlobalPrefs *prefs = [[GlobalPrefs alloc] init];
    PreferenceObserver *sender = [[PreferenceObserver alloc] init];
    PreferenceObserver *listener = [[PreferenceObserver alloc] init];
    SEL setting = @selector(setConfirmNoteDeletion:sender:);
    [prefs registerForSettingChange:setting withTarget:sender];
    [prefs registerForSettingChange:setting withTarget:listener];
    [prefs setConfirmNoteDeletion:YES sender:sender];
    XCTAssertTrue([prefs confirmNoteDeletion]);
    XCTAssertEqual(sender.selectors.count, 0U);
    XCTAssertEqualObjects(listener.selectors, (@[NSStringFromSelector(setting)]));
}
- (void)testSelfSenderSuppressesCallbacks {
    GlobalPrefs *prefs = [[GlobalPrefs alloc] init];
    PreferenceObserver *listener = [[PreferenceObserver alloc] init];
    [prefs registerForSettingChange:@selector(setConfirmNoteDeletion:sender:) withTarget:listener];
    [prefs setConfirmNoteDeletion:NO sender:prefs];
    XCTAssertFalse([prefs confirmNoteDeletion]);
    XCTAssertEqual(listener.selectors.count, 0U);
}
- (void)testUnregisterStopsNotifications {
    GlobalPrefs *prefs = [[GlobalPrefs alloc] init];
    PreferenceObserver *listener = [[PreferenceObserver alloc] init];
    SEL setting = @selector(setConfirmNoteDeletion:sender:);
    [prefs registerForSettingChange:setting withTarget:listener];
    [prefs unregisterForNotificationsFromSelector:setting sender:listener];
    [prefs setConfirmNoteDeletion:YES sender:nil];
    XCTAssertEqual(listener.selectors.count, 0U);
}
@end
