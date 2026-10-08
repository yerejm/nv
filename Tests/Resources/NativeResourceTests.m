#import <XCTest/XCTest.h>
#import "TestPaths.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NotationPrefsViewController.h"
#import "PrefsWindowController.h"
#import "NSData_transformations.h"

@interface CompletionAlert : NSAlert
@end
@implementation CompletionAlert
- (void)beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler {
    handler(NSAlertSecondButtonReturn);
}
@end

@interface CompletionRecorder : NSObject
@property(nonatomic, assign) NSAlert *alert;
@property(nonatomic, assign) NSModalResponse response;
@property(nonatomic, assign) void *context;
- (void)alertDidEnd:(NSAlert *)alert returnCode:(NSModalResponse)response contextInfo:(void *)context;
@end
@implementation CompletionRecorder
- (void)alertDidEnd:(NSAlert *)alert returnCode:(NSModalResponse)response contextInfo:(void *)context {
    self.alert = alert;
    self.response = response;
    self.context = context;
}
@end

//legacy nibs are checked in compiled; xibs are compiled here the way the app build does
static NSData *CompiledNibData(NSString *basePath, NSString *scratchDirectory) {
    NSString *xib = [basePath stringByAppendingPathExtension:@"xib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:xib])
        return [NSData dataWithContentsOfFile:[[basePath stringByAppendingPathExtension:@"nib"] stringByAppendingPathComponent:@"keyedobjects.nib"]];
    NSString *output = [scratchDirectory stringByAppendingPathComponent:[[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"nib"]];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"ibtool", @"--minimum-deployment-target", @"15.0", @"--compile", output, xib];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) return nil;
    [task waitUntilExit];
    return task.terminationStatus == 0 ? [NSData dataWithContentsOfFile:output] : nil;
}

@interface NativeResourceTests : XCTestCase
@end
@implementation NativeResourceTests
- (void)testAlertCompletionPreservesAlertResponseAndContext {
    [NSApplication sharedApplication];
    CompletionAlert *alert = [[[CompletionAlert alloc] init] autorelease];
    CompletionRecorder *recorder = [[[CompletionRecorder alloc] init] autorelease];
    NSWindow *window = [[[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO] autorelease];
    NVBeginAlertSheet(alert, window, recorder, @selector(alertDidEnd:returnCode:contextInfo:), recorder);
    XCTAssertEqual(recorder.alert, alert);
    XCTAssertEqual(recorder.response, NSAlertSecondButtonReturn);
    XCTAssertEqual(recorder.context, recorder);
}
- (void)testLoadsAllLocalizedCompiledResources {
    [NSApplication sharedApplication];
    NSString *root = NVResourcesDirectory();
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
    NVFileReference reference;
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)directory.fileSystemRepresentation, &reference, NULL), noErr);
    GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
    [prefs setAliasDataForDefaultDirectory:[NSData aliasDataForFSRef:&reference] sender:prefs];
    [prefs setNotationPrefs:[[[NotationPrefs alloc] init] autorelease] sender:prefs];
    for (NSString *imageFile in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[root stringByAppendingPathComponent:@"Images"] error:NULL]) {
        NSImage *image = [[[NSImage alloc] initWithContentsOfFile:[[root stringByAppendingPathComponent:@"Images"] stringByAppendingPathComponent:imageFile]] autorelease];
        if (image) [image setName:[imageFile stringByDeletingPathExtension]];
    }
    for (NSString *localization in @[@"en", @"de", @"it", @"fr", @"pt", @"zh_CN"]) {
        for (NSString *name in @[@"MainMenu", @"Preferences", @"NotationPrefsView"]) {
            NSMutableDictionary *registry = [prefs valueForKey:@"selectorObservers"];
            NSMutableDictionary *savedObservers = [NSMutableDictionary dictionary];
            for (NSString *selector in registry)
                savedObservers[selector] = [[registry[selector] mutableCopy] autorelease];
            NSData *nibData = CompiledNibData([root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lproj/%@", localization, name]], directory);
            NSNib *nib = [[[NSNib alloc] initWithNibData:nibData bundle:nil] autorelease];
            XCTAssertNotNil(nib, @"%@ %@", localization, name);
            id owner = [name isEqualToString:@"MainMenu"] ? (id)NSApp :
                [name isEqualToString:@"Preferences"] ? (id)[[[PrefsWindowController alloc] init] autorelease] :
                (id)[[[NotationPrefsViewController alloc] init] autorelease];
            NSArray *objects = nil;
            XCTAssertNoThrow(XCTAssertTrue([nib instantiateWithOwner:owner topLevelObjects:&objects], @"%@ %@", localization, name));
            XCTAssertGreaterThan(objects.count, 0U);
            if ([name isEqualToString:@"MainMenu"]) {
                XCTAssertNotNil(NSApp.mainMenu);
                XCTAssertGreaterThan(NSApp.mainMenu.numberOfItems, 2);
            } else {
                XCTAssertNotNil([owner valueForKey:[name isEqualToString:@"Preferences"] ? @"window" : @"view"]);
                if ([name isEqualToString:@"Preferences"]) {
                    NSWindow *window = [owner valueForKey:@"window"];
                    NSRect frame = window.frame;
                    XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 640);
                    for (NSToolbarItem *item in window.toolbar.items) {
                        [owner switchViews:item];
                        XCTAssertTrue(NSEqualRects(frame, window.frame), @"%@ %@", localization, item.itemIdentifier);
                        NSView *pane = window.contentView.subviews.firstObject;
                        XCTAssertTrue(NSContainsRect(window.contentView.bounds, pane.frame), @"%@ %@", localization, item.itemIdentifier);
                    }
                }
            }
            NSApp.delegate = nil;
            [registry setDictionary:savedObservers];
            for (NSWindow *window in [[NSApp.windows copy] autorelease]) {
                window.delegate = nil;
                [window setReleasedWhenClosed:NO];
                [window close];
            }
        }
    }
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:directory error:NULL]);
}
@end
