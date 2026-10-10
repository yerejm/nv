#import <XCTest/XCTest.h>
#import "NVShortcutRecorder.h"

@interface ShortcutRecorderDelegate : NSObject <NVShortcutRecorderDelegate>
@property(nonatomic) BOOL accepts;
@property(nonatomic) NSInteger keyCode;
@property(nonatomic) NSUInteger modifiers, changes, begins, ends;
@end
@implementation ShortcutRecorderDelegate
- (BOOL)shortcutRecorder:(NVShortcutRecorder *)recorder shouldChangeToKeyCode:(NSInteger)keyCode carbonModifiers:(NSUInteger)modifiers {
    self.changes++;
    self.keyCode = keyCode;
    self.modifiers = modifiers;
    return self.accepts;
}
- (void)shortcutRecorderDidBeginRecording:(NVShortcutRecorder *)recorder { self.begins++; }
- (void)shortcutRecorderDidEndRecording:(NVShortcutRecorder *)recorder {
    XCTAssertFalse(recorder.recording);
    self.ends++;
}
@end

@interface ShortcutRecorderTests : XCTestCase
@end

@implementation ShortcutRecorderTests

- (TISInputSourceRef)copyLayout:(NSString *)identifier {
    CFArrayRef sources = TISCreateInputSourceList((__bridge CFDictionaryRef)@{(__bridge id)kTISPropertyInputSourceID: identifier}, true);
    TISInputSourceRef source = sources && CFArrayGetCount(sources) ? (TISInputSourceRef)CFRetain(CFArrayGetValueAtIndex(sources, 0)) : NULL;
    if (sources) CFRelease(sources);
    return source;
}

- (void)testKeysAreNamedByTheirKeyboardLayout {
    TISInputSourceRef us = [self copyLayout:@"com.apple.keylayout.US"];
    TISInputSourceRef german = [self copyLayout:@"com.apple.keylayout.German"];
    TISInputSourceRef french = [self copyLayout:@"com.apple.keylayout.French"];
    XCTAssertTrue(us && german && french);
    XCTAssertEqualObjects(NVShortcutDescription(kVK_ANSI_Z, cmdKey, us), @"⌘Z");
    XCTAssertEqualObjects(NVShortcutDescription(kVK_ANSI_Z, cmdKey, german), @"⌘Y");
    XCTAssertEqualObjects(NVShortcutDescription(kVK_ANSI_Y, cmdKey, german), @"⌘Z");
    XCTAssertEqualObjects(NVShortcutDescription(kVK_ANSI_Minus, optionKey, german), @"⌥ß");
    XCTAssertEqualObjects(NVShortcutDescription(kVK_ANSI_A, controlKey, french), @"⌃Q");
    XCTAssertEqualObjects(NVShortcutDescription(kVK_ANSI_Q, controlKey, french), @"⌃A");
    if (us) CFRelease(us);
    if (german) CFRelease(german);
    if (french) CFRelease(french);
}

- (void)testModifiersFollowTheSystemOrderAndSpecialKeysUseSymbols {
    NSUInteger all = cmdKey | shiftKey | optionKey | controlKey;
    XCTAssertTrue([NVShortcutDescription(kVK_ANSI_N, all, NULL) hasPrefix:@"⌃⌥⇧⌘"]);
    XCTAssertEqualObjects(NVShortcutDescription(kVK_F20, 0, NULL), @"F20");
    XCTAssertEqualObjects(NVShortcutDescription(kVK_F1, cmdKey, NULL), @"⌘F1");
    XCTAssertEqualObjects(NVShortcutDescription(kVK_LeftArrow, controlKey | optionKey, NULL), @"⌃⌥←");
    XCTAssertEqualObjects(NVShortcutDescription(kVK_Return, cmdKey, NULL), @"⌘↩");
    XCTAssertEqualObjects(NVShortcutDescription(kVK_Space, controlKey, NULL), ([@"⌃" stringByAppendingString:NSLocalizedString(@"Space", nil)]));
}

- (void)testRecordingAsksTheDelegateAndHonoursItsAnswer {
    [NSApplication sharedApplication];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 300, 60) styleMask:NSWindowStyleMaskTitled
                                                      backing:NSBackingStoreBuffered defer:NO];
    [window setReleasedWhenClosed:NO];
    NVShortcutRecorder *recorder = [[NVShortcutRecorder alloc] initWithFrame:NSMakeRect(20, 20, 160, 22)];
    [window.contentView addSubview:recorder];
    ShortcutRecorderDelegate *delegate = [[ShortcutRecorderDelegate alloc] init];
    recorder.delegate = delegate;
    XCTAssertEqual(recorder.keyCode, -1);

    NSEvent *(^key)(unsigned short, NSEventModifierFlags) = ^(unsigned short keyCode, NSEventModifierFlags flags) {
        return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:window.windowNumber
                                 context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:keyCode];
    };
    // a click reaches mouseDown: after the window has already focused the recorder
    XCTAssertTrue([window makeFirstResponder:recorder]);
    [recorder mouseDown:[NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(40, 30) modifierFlags:0 timestamp:0
                                       windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1]];
    XCTAssertTrue(recorder.recording);
    XCTAssertEqual(delegate.begins, 1U);
    [recorder keyDown:key(kVK_ANSI_K, NSEventModifierFlagShift)];
    XCTAssertTrue(recorder.recording);
    XCTAssertEqual(delegate.changes, 0U);

    delegate.accepts = NO;
    XCTAssertTrue([recorder performKeyEquivalent:key(kVK_ANSI_K, NSEventModifierFlagCommand | NSEventModifierFlagOption)]);
    XCTAssertFalse(recorder.recording);
    XCTAssertEqual(delegate.ends, 1U);
    XCTAssertEqual(delegate.changes, 1U);
    XCTAssertEqual(recorder.keyCode, -1);

    delegate.accepts = YES;
    [window makeFirstResponder:recorder];
    XCTAssertTrue([recorder performKeyEquivalent:key(kVK_ANSI_K, NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagFunction)]);
    XCTAssertEqual(delegate.keyCode, kVK_ANSI_K);
    XCTAssertEqual(delegate.modifiers, (NSUInteger)(cmdKey | optionKey));
    XCTAssertEqual(recorder.keyCode, kVK_ANSI_K);
    XCTAssertEqual(recorder.modifiers, (NSUInteger)(cmdKey | optionKey));

    [window makeFirstResponder:recorder];
    [recorder keyDown:key(kVK_Escape, 0)];
    XCTAssertFalse(recorder.recording);
    XCTAssertEqual(delegate.changes, 2U);
    XCTAssertEqual(recorder.keyCode, kVK_ANSI_K);

    [window makeFirstResponder:recorder];
    [recorder keyDown:key(kVK_ForwardDelete, 0)];
    XCTAssertFalse(recorder.recording);
    XCTAssertEqual(delegate.keyCode, -1);
    XCTAssertEqual(recorder.keyCode, -1);
    XCTAssertEqual(delegate.begins, delegate.ends);

    XCTAssertFalse([recorder performKeyEquivalent:key(kVK_ANSI_W, NSEventModifierFlagCommand)]);
    XCTAssertEqual(delegate.changes, 3U);
    [window close];
}

@end
