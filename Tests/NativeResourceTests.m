#import <XCTest/XCTest.h>
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "NotationPrefsViewController.h"
#import "PrefsWindowController.h"
#import "NSData_transformations.h"

@interface NativeResourceTests : XCTestCase
@end
@implementation NativeResourceTests
- (void)testLoadsAllLocalizedCompiledResources {
    [NSApplication sharedApplication];
    NSString *root = [[@__FILE__ stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL]);
    FSRef reference;
    XCTAssertEqual(FSPathMakeRef((const UInt8 *)directory.fileSystemRepresentation, &reference, NULL), noErr);
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
            NSString *filename = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.lproj/%@.nib", localization, name]];
            NSData *nibData = [NSData dataWithContentsOfFile:[filename stringByAppendingPathComponent:@"keyedobjects.nib"]];
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
