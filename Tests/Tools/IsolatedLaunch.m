#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "NVFileReference.h"
#import "NVArchive.h"
#import "NSData_transformations.h"
#import "AppController.h"
#import "AppController_Importing.h"
#import "NotationPrefs.h"
#import "NotationPrefsViewController.h"
#import "NotationDirectoryManager.h"
#import "NotationFileManager.h"
#import "NoteObject.h"
#import "FastListDataSource.h"
#import "GlobalPrefs.h"
#import "PrefsWindowController.h"
#import "LinkingEditor.h"
#import "AttributedPlainText.h"
#import "ExternalEditorListController.h"
#import "ExporterManager.h"
#import "ODBEditor.h"
#import "NVHotKey.h"
#import "NVShortcutRecorder.h"
#import "DualField.h"
#import "AugmentedScrollView.h"
#import "NVSplitView.h"
#import "TemporaryFileCachePreparer.h"
#import "AcceptanceEditorSession.h"
#include <sys/mount.h>
#include <dlfcn.h>
#include <objc/runtime.h>

@interface AppController (ServiceAcceptance)
- (void)createFromSelection:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error;
+ (void)migrateLegacyNotesListLayoutInDefaults:(NSUserDefaults *)defaults sideBySide:(BOOL)sideBySide;
@end

@interface AcceptanceExportDestination : NSObject
@property(nonatomic, retain) NSURL *URL;
@end
@implementation AcceptanceExportDestination
- (void)dealloc { [_URL release]; [super dealloc]; }
@end

@interface AcceptanceStatusMenuObserver : NSObject <NSMenuDelegate>
@property(nonatomic) BOOL opened;
@end
@implementation AcceptanceStatusMenuObserver
- (void)menuWillOpen:(NSMenu *)menu { self.opened = YES; }
@end

@interface ExporterManager (Acceptance)
- (void)exportPanelDidEnd:(NSSavePanel *)sheet returnCode:(NSModalResponse)returnCode contextInfo:(void *)context;
@end

static NSString *acceptanceRoot;
static NSMutableArray *checks;
static NSUInteger requestCount;
static NSUInteger hotkeyCount;

static NSString *NVIsolatedTemporaryDirectory(void) {
    Dl_info caller;
    if (acceptanceRoot && dladdr(__builtin_return_address(0), &caller) &&
        [[NSString stringWithUTF8String:caller.dli_fname].lastPathComponent isEqualToString:@"NVDevelopment"])
        return [acceptanceRoot stringByAppendingPathComponent:@"tmp/"];
    return NSTemporaryDirectory();
}

__attribute__((used, section("__DATA,__interpose"))) static struct {
    const void *replacement;
    const void *original;
} temporaryDirectoryOverride = { (const void *)NVIsolatedTemporaryDirectory, (const void *)NSTemporaryDirectory };

@interface NVHotkeyRecorder : NSObject
- (void)fired:(id)sender;
@end
@implementation NVHotkeyRecorder
- (void)fired:(id)sender { hotkeyCount++; }
@end

@interface NVRequestRecorder : NSURLProtocol
@end
@implementation NVRequestRecorder
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    requestCount++;
    return NO;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {}
- (void)stopLoading {}
@end

static NSMenuItem *MenuItemWithAction(NSMenu *menu, SEL action) {
    for (NSMenuItem *item in menu.itemArray) {
        if (item.action == action) return item;
        NSMenuItem *nested = item.submenu ? MenuItemWithAction(item.submenu, action) : nil;
        if (nested) return nested;
    }
    return nil;
}

static NSMenuItem *FindMenuCommand(NSMenu *menu) {
    for (NSMenuItem *item in menu.itemArray) {
        if ((item.action == @selector(performFindPanelAction:) || item.action == @selector(performTextFinderAction:)) && item.tag == NSTextFinderActionShowFindInterface)
            return item;
        NSMenuItem *nested = item.submenu ? FindMenuCommand(item.submenu) : nil;
        if (nested) return nested;
    }
    return nil;
}

static void Check(NSString *name, BOOL passed) {
    [checks addObject:@{@"check": name, @"passed": @(passed)}];
    NSLog(@"NV acceptance: %@ %@", passed ? @"PASS" : @"FAIL", name);
}

// Acceptance runs outside the app's event loop, so pending events are delivered here as that loop would;
// otherwise activation, hiding and unhiding lag until something else, such as a menu, drains the queue.
static void Pump(NSTimeInterval seconds) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([limit timeIntervalSinceNow] > 0) {
        NSEvent *event;
        while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:nil inMode:NSDefaultRunLoopMode dequeue:YES]))
            [NSApp sendEvent:event];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
}

// macOS may decline activation while someone is using another app; failures in such a run reflect the desktop, not the app.
static BOOL activationRefused;

static void WaitForActivation(NSWindow *window) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:3];
    while ((!NSApp.isActive || NSApp.isHidden || !window.isKeyWindow) && limit.timeIntervalSinceNow > 0) Pump(0.05);
    if (!NSApp.isActive) {
        activationRefused = YES;
        NSLog(@"NV acceptance: activation refused while %@ is frontmost", NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier);
    }
}

static NSBitmapImageRep *SnapshotView(NSView *view, NSString *name) {
    [view.window displayIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    }];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[acceptanceRoot stringByAppendingPathComponent:name] atomically:YES];
    return bitmap;
}

static void Snapshot(NSWindow *window, NSString *name) {
    SnapshotView(window.contentView, name);
}

static BOOL HeaderTitlesShareVerticalCentre(NSTableView *table) {
    NSTableHeaderView *header = table.headerView;
    if (!header || table.numberOfColumns < 2) return NO;
    [header.window displayIfNeeded];
    NSBitmapImageRep *bitmap = [header bitmapImageRepForCachingDisplayInRect:header.bounds];
    [header.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [header cacheDisplayInRect:header.bounds toBitmapImageRep:bitmap];
    }];
    CGFloat scale = bitmap.pixelsWide / NSWidth(header.bounds);
    CGFloat lowestCentre = CGFLOAT_MAX, highestCentre = -CGFLOAT_MAX;
    for (NSInteger column = 0; column < table.numberOfColumns; column++) {
        NSRect rect = [header headerRectOfColumn:column];
        NSTableColumn *tableColumn = table.tableColumns[column];
        if ([table indicatorImageInTableColumn:tableColumn])
            rect.size.width = NSMinX([tableColumn.headerCell sortIndicatorRectForBounds:rect]) - NSMinX(rect);
        rect = NSMakeRect(NSMinX(rect) + 3, NSMinY(rect), NSWidth(rect) - 6, NSHeight(rect) - 2);
        CGFloat background = [[[bitmap colorAtX:NSMinX(rect) * scale y:(NSMinY(rect) + 2) * scale] colorUsingColorSpace:NSColorSpace.sRGBColorSpace] brightnessComponent];
        NSInteger top = NSIntegerMax, bottom = -1;
        for (NSInteger y = NSMinY(rect) * scale; y < NSMaxY(rect) * scale; y++)
            for (NSInteger x = NSMinX(rect) * scale; x < NSMaxX(rect) * scale; x++)
                if (fabs([[[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace] brightnessComponent] - background) > 0.3) {
                    top = MIN(top, y);
                    bottom = MAX(bottom, y);
                }
        if (bottom < 0) return NO;
        CGFloat centre = (top + bottom + 1) / scale / 2;
        lowestCentre = MIN(lowestCentre, centre);
        highestCentre = MAX(highestCentre, centre);
    }
    return highestCentre - lowestCentre <= 1;
}

static BOOL RowIsDrawnWithin(NSView *container, NSTableView *table, NSInteger row) {
    [container.window displayIfNeeded];
    NSBitmapImageRep *bitmap = [container bitmapImageRepForCachingDisplayInRect:container.bounds];
    [container.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [container cacheDisplayInRect:container.bounds toBitmapImageRep:bitmap];
    }];
    NSRect rect = [container convertRect:NSIntersectionRect([table rectOfRow:row], table.visibleRect) fromView:table];
    rect = NSIntersectionRect(rect, container.bounds);
    if (NSIsEmptyRect(rect)) return NO;
    CGFloat scale = bitmap.pixelsWide / NSWidth(container.bounds);
    CGFloat darkest = 1, lightest = 0;
    for (NSInteger y = NSMinY(rect) * scale; y < NSMaxY(rect) * scale; y++) {
        NSInteger pixelY = container.isFlipped ? y : bitmap.pixelsHigh - 1 - y;
        for (NSInteger x = NSMinX(rect) * scale; x < NSMaxX(rect) * scale; x++) {
            CGFloat brightness = [[[bitmap colorAtX:x y:pixelY] colorUsingColorSpace:NSColorSpace.sRGBColorSpace] brightnessComponent];
            darkest = MIN(darkest, brightness);
            lightest = MAX(lightest, brightness);
        }
    }
    return lightest - darkest > 0.4;
}

//the notes list is the split view's first pane and the editor its second
static BOOL ListPaneCollapsed(NVSplitView *split) {
    return split.isLeadingPaneCollapsed;
}

static CGFloat ListPaneSize(NVSplitView *split) {
    NSSize size = split.subviews.firstObject.frame.size;
    return split.isVertical ? size.width : size.height;
}

static void SetListPaneSize(NVSplitView *split, CGFloat size) {
    [split setPosition:size ofDividerAtIndex:0];
}

static BOOL DividerIsVisible(NVSplitView *split) {
    return split.dividerThickness >= 1 && [split.dividerColor isEqual:[[GlobalPrefs defaultPrefs] interfaceSeparatorColor]];
}

static NSPoint DividerPoint(NVSplitView *split) {
    NSRect editorFrame = split.subviews.lastObject.frame;
    CGFloat inset = split.dividerThickness / 2;
    return split.isVertical ? NSMakePoint(NSMinX(editorFrame) - inset, NSMidY(editorFrame)) : NSMakePoint(NSMidX(editorFrame), NSMinY(editorFrame) - inset);
}

static NSEvent *DividerMouseEvent(NVSplitView *split, NSEventType type, NSPoint point, NSInteger clickCount) {
    return [NSEvent mouseEventWithType:type location:[split convertPoint:point toView:nil] modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                          windowNumber:split.window.windowNumber context:nil eventNumber:0 clickCount:clickCount pressure:type == NSEventTypeLeftMouseUp ? 0 : 1];
}

static NSEvent *DividerDoubleClick(NVSplitView *split) {
    return DividerMouseEvent(split, NSEventTypeLeftMouseDown, DividerPoint(split), 2);
}

static BOOL DividerIsDrawn(NVSplitView *split) {
    [split.window displayIfNeeded];
    NSBitmapImageRep *bitmap = [split bitmapImageRepForCachingDisplayInRect:split.bounds];
    [split.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [split cacheDisplayInRect:split.bounds toBitmapImageRep:bitmap];
    }];
    CGFloat scale = bitmap.pixelsWide / NSWidth(split.bounds);
    NSPoint divider = DividerPoint(split);
    NSPoint editor = split.isVertical ? NSMakePoint(divider.x + 2, divider.y) : NSMakePoint(divider.x, divider.y + 2);
    CGFloat (^brightness)(NSPoint) = ^CGFloat(NSPoint point) {
        NSInteger y = (split.isFlipped ? point.y : NSHeight(split.bounds) - point.y) * scale;
        return [[[bitmap colorAtX:point.x * scale y:y] colorUsingColorSpace:NSColorSpace.sRGBColorSpace] brightnessComponent];
    };
    return fabs(brightness(divider) - brightness(editor)) > 0.05;
}

//the split view tracks a drag from the queued events once it receives the mouse down; it only collapses a pane it sees dragged past the threshold step by step
static void DragDivider(NVSplitView *split, CGFloat position) {
    NSPoint start = DividerPoint(split);
    NSPoint end = split.isVertical ? NSMakePoint(position, start.y) : NSMakePoint(start.x, position);
    for (NSInteger step = 1; step <= 10; step++) {
        CGFloat fraction = step / 10.0;
        NSPoint point = NSMakePoint(start.x + (end.x - start.x) * fraction, start.y + (end.y - start.y) * fraction);
        [NSApp postEvent:DividerMouseEvent(split, NSEventTypeLeftMouseDragged, point, 1) atStart:NO];
    }
    [NSApp postEvent:DividerMouseEvent(split, NSEventTypeLeftMouseUp, end, 1) atStart:NO];
    [split mouseDown:DividerMouseEvent(split, NSEventTypeLeftMouseDown, start, 1)];
}

static void SnapshotWindow(NSWindow *window, NSString *name) {
    dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit", RTLD_LAZY);
    __block BOOL finished = NO;
    [(id)NSClassFromString(@"SCShareableContent") getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SCWindow *ownWindow = nil;
            for (SCWindow *candidate in content.windows)
                if (candidate.windowID == window.windowNumber) ownWindow = candidate;
            if (!ownWindow) {
                NSLog(@"NV acceptance: %@ not shareable (%lu windows, error %@)", name, (unsigned long)content.windows.count, error);
                finished = YES;
                return;
            }
            SCContentFilter *filter = [[NSClassFromString(@"SCContentFilter") alloc] initWithDesktopIndependentWindow:ownWindow];
            SCStreamConfiguration *configuration = [[NSClassFromString(@"SCStreamConfiguration") alloc] init];
            configuration.width = NSWidth(window.frame) * window.backingScaleFactor;
            configuration.height = NSHeight(window.frame) * window.backingScaleFactor;
            configuration.ignoreShadowsSingleWindow = YES;
            configuration.showsCursor = NO;
            [(id)NSClassFromString(@"SCScreenshotManager") captureImageWithFilter:filter configuration:configuration completionHandler:^(CGImageRef image, NSError *captureError) {
                if (!image) NSLog(@"NV acceptance: %@ capture failed: %@", name, captureError);
                if (image) {
                    NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithCGImage:image] autorelease];
                    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                        writeToFile:[acceptanceRoot stringByAppendingPathComponent:name] atomically:YES];
                }
                dispatch_async(dispatch_get_main_queue(), ^{ finished = YES; });
            }];
            [filter release];
            [configuration release];
        });
    }];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!finished && limit.timeIntervalSinceNow > 0) Pump(0.02);
    if (!finished) NSLog(@"NV acceptance: %@ capture timed out", name);
    Check(@"isolated window screenshot", [[NSFileManager defaultManager] fileExistsAtPath:[acceptanceRoot stringByAppendingPathComponent:name]]);
}

static void FinishAcceptance(NSString *filename) {
    NSDictionary *result = @{@"system": NSProcessInfo.processInfo.operatingSystemVersionString, @"dataRoot": acceptanceRoot,
                             @"checks": checks, @"urlRequests": @(requestCount), @"activationRefused": @(activationRefused)};
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL]
        writeToFile:[acceptanceRoot stringByAppendingPathComponent:filename] atomically:YES];
    [NSApp terminate:nil];
}

static BOOL CheckEditingCache(BOOL encrypted) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
    TemporaryFileCachePreparer *preparer;
    do {
        Pump(0.05);
        preparer = [[NSClassFromString(@"ODBEditor") sharedODBEditor] valueForKey:@"editingSpacePreparer"];
    } while ((preparer.isPreparing || !preparer.preparedCachePath ||
              (encrypted && ![preparer.preparedCachePath.lastPathComponent isEqualToString:@"NVProtectedEditingSpace"])) && limit.timeIntervalSinceNow > 0);
    NSString *cache = preparer.preparedCachePath;
    BOOL isolated = [cache hasPrefix:[acceptanceRoot stringByAppendingPathComponent:@"tmp/"]];
    Check(@"temporary editing cache is isolated", isolated);
    if (encrypted) {
        struct statfs volume;
        BOOL mounted = isolated && statfs(cache.fileSystemRepresentation, &volume) == 0 &&
            strcmp(volume.f_mntonname, cache.stringByResolvingSymlinksInPath.fileSystemRepresentation) == 0 &&
            strcmp(volume.f_fstypename, "hfs") == 0;
        Check(@"encrypted external editing uses isolated RAM disk", mounted);
        return mounted;
    }
    return isolated;
}

static void RunReopenAcceptance(void) {
    checks = [[NSMutableArray alloc] init];
    @try {
        AppController *app = (id)NSApp.delegate;
        NotationController *notation = [app valueForKey:@"notationController"];
        NSArray *notes = [notation valueForKey:@"allNotes"];
        CheckEditingCache(YES);
        NSDictionary *saved = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[acceptanceRoot stringByAppendingPathComponent:@"identity.json"]] options:0 error:NULL];
        NoteObject *found = nil;
        for (NoteObject *note in notes)
            if ([note->titleString isEqualToString:@"Renamed acceptance note"]) found = note;
        Check(@"encrypted database reopens via Keychain", notation.notationPrefs.doesEncryption && found && notes.count == 3);
        Check(@"externally edited content survives quit and reopen", found && [found->contentString.string containsString:@"Automatic file monitoring acceptance"]);
        Check(@"wrong password rejected after reopen", ![notation.notationPrefs canLoadPassphrase:@"wrong password"]);
        Check(@"window size restoration", fabs([app window].frame.size.width - 720) < 1);
        Check(@"quitting during full screen restores the previous layout on reopen", ![[GlobalPrefs defaultPrefs] horizontalLayout] && ![[NSUserDefaults standardUserDefaults] objectForKey:@"FullScreenSwitchedLayout"]);
        NVSplitView *split = [app valueForKey:@"splitView"];
        CGFloat stackedSize = ListPaneSize(split);
        [app switchViewLayout:nil];
        CGFloat sideBySideSize = ListPaneSize(split);
        [app switchViewLayout:nil];
        Check(@"notes list sizes for both layouts survive quit and reopen", fabs(stackedSize - 140) < 1 && fabs(sideBySideSize - 230) < 1);
        NSString *account = [NSString stringWithUTF8String:[notation.notationPrefs setKeychainIdentifier]];
        Check(@"temporary Keychain identity is retained", [account isEqualToString:saved[@"keychainAccount"]]);
        if ([account isEqualToString:saved[@"keychainAccount"]]) {
            [notation.notationPrefs setStoresPasswordInKeychain:NO];
            Check(@"temporary Keychain entry removed", [notation.notationPrefs currentKeychainItem] == NULL);
        }
        Check(@"no app-owned URL requests after reopen", requestCount == 0);
    } @catch (NSException *exception) {
        [checks addObject:@{@"check": @"reopen exception", @"passed": @NO, @"detail": exception.description}];
    }
    FinishAcceptance(@"reopen-result.json");
}

static void CheckExternalEditor(NoteObject *note) {
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    NSURL *editorURL = [workspace URLForApplicationWithBundleIdentifier:@"com.apple.TextEdit"];
    ExternalEditor *editor = [[[NSClassFromString(@"ExternalEditor") alloc] initWithBundleID:@"com.apple.TextEdit" resolvedURL:editorURL] autorelease];
    NVAcceptanceEditorSession *session = [[[NVAcceptanceEditorSession alloc] initWithDirectory:acceptanceRoot] autorelease];
    SEL selector = @selector(openURLs:withApplicationAtURL:configuration:completionHandler:);
    Method method = class_getInstanceMethod([NSWorkspace class], selector);
    IMP original = method_getImplementation(method);
    __block BOOL opened = NO;
    __block BOOL openingIsolatedInstance = NO;
    IMP isolated = imp_implementationWithBlock(^void(NSWorkspace *target, NSArray *URLs, NSURL *applicationURL,
        NSWorkspaceOpenConfiguration *configuration, void (^completion)(NSRunningApplication *, NSError *)) {
        if (!openingIsolatedInstance && [applicationURL isEqual:editorURL] &&
            [URLs isEqualToArray:@[[NSURL fileURLWithPath:note.noteFilePath]]]) {
            openingIsolatedInstance = YES;
            opened = [session openURLs:URLs withApplicationAtURL:editorURL workspace:target timeout:10];
            openingIsolatedInstance = NO;
            return;
        }
        ((void (*)(id, SEL, NSArray *, NSURL *, NSWorkspaceOpenConfiguration *, id))original)
            (target, selector, URLs, applicationURL, configuration, completion);
    });
    method_setImplementation(method, isolated);
    @try {
        Check(@"TextEdit external editor opens local note", [editor isInstalled] && [editor canEditNoteDirectly:note] &&
            [[NSClassFromString(@"ODBEditor") sharedODBEditor] editNote:note inEditor:editor context:nil] && opened);
    } @finally {
        method_setImplementation(method, original);
        imp_removeBlock(isolated);
        Check(@"temporary external editor closed", [session tearDown]);
    }
}

static BOOL WindowSnapshotShowsControlText(NSView *control, NSString *filename) {
    NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithData:[NSData dataWithContentsOfFile:[acceptanceRoot stringByAppendingPathComponent:filename]]] autorelease];
    if (!bitmap || !control.window) return NO;
    NSRect frame = NSInsetRect([control convertRect:control.bounds toView:nil], 6, 4);
    CGFloat scale = bitmap.pixelsWide / NSWidth(control.window.frame);
    NSInteger textPixels = 0;
    for (NSInteger y = MAX(0, bitmap.pixelsHigh - NSMaxY(frame) * scale); y < MIN(bitmap.pixelsHigh, bitmap.pixelsHigh - NSMinY(frame) * scale); y += 2) {
        for (NSInteger x = MAX(0, NSMinX(frame) * scale); x < MIN(bitmap.pixelsWide, NSMaxX(frame) * scale); x += 2) {
            NSColor *color = [[bitmap colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (MAX(color.redComponent, MAX(color.greenComponent, color.blueComponent)) < 0.45) textPixels++;
        }
    }
    return textPixels > 20;
}

static BOOL ShortcutIsFree(NSInteger keyCode, NSUInteger modifiers) {
    NVHotKey *probe = [[[NVHotKey alloc] initWithTarget:nil action:NULL] autorelease];
    BOOL free = [probe registerKeyCode:keyCode carbonModifiers:modifiers];
    [probe unregister];
    return free;
}

// Sent the way NSApplication delivers a key press, so shortcuts the menus would claim are tested too.
static void TypeKey(NSWindow *window, unsigned short keyCode, NSEventModifierFlags flags) {
    NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:NSProcessInfo.processInfo.systemUptime
                                  windowNumber:window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:keyCode];
    if (![window performKeyEquivalent:event]) [window sendEvent:event];
}

static void ClickView(NSView *view, NSPoint pointInView) {
    NSPoint point = [view convertPoint:pointInView toView:nil];
    for (NSEventType type = NSEventTypeLeftMouseDown; type <= NSEventTypeLeftMouseUp; type++) {
        [view.window sendEvent:[NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                              windowNumber:view.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1]];
    }
}

static void CheckShortcutRecorder(PrefsWindowController *preferences, NSWindow *prefsWindow) {
    GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
    [preferences switchViews:[[preferences valueForKey:@"items"] objectForKey:@"General"]];
    // A click in an inactive window only activates it, so the recorder is clicked once Settings is key.
    [NSApp activateIgnoringOtherApps:YES];
    [prefsWindow makeKeyAndOrderFront:nil];
    WaitForActivation(prefsWindow);
    NVShortcutRecorder *recorder = [preferences valueForKey:@"appShortcutRecorder"];
    NSView *generalPane = [preferences valueForKey:@"generalView"];
    Check(@"shortcut recorder fits inside the General pane", recorder.window == prefsWindow &&
          NSContainsRect(generalPane.bounds, [generalPane convertRect:recorder.bounds fromView:recorder]));
    const NSUInteger chord = cmdKey | optionKey | controlKey;
    BOOL saved = [prefs setAppActivationKeyCode:kVK_F19 modifiers:chord sender:nil];
    [recorder setKeyCode:prefs.appActivationKeyCode carbonModifiers:prefs.appActivationModifiers];
    Check(@"the bring-to-front shortcut is registered while not recording", saved && !ShortcutIsFree(kVK_F19, chord));
    ClickView(recorder, NSMakePoint(NSMidX(recorder.bounds) - 20, NSMidY(recorder.bounds)));
    Check(@"clicking the recorder starts recording and frees the current shortcut", recorder.recording && prefsWindow.firstResponder == recorder && ShortcutIsFree(kVK_F19, chord));
    TypeKey(prefsWindow, kVK_ANSI_N, 0);
    TypeKey(prefsWindow, kVK_ANSI_N, NSEventModifierFlagShift);
    Check(@"letters without Command, Option or Control are not recorded", recorder.recording && prefs.appActivationKeyCode == kVK_F19);
    BOOL wasRecording = recorder.recording;
    TypeKey(prefsWindow, kVK_Escape, 0);
    Check(@"Escape stops recording and keeps the shortcut", wasRecording && !recorder.recording && prefs.appActivationKeyCode == kVK_F19 && !ShortcutIsFree(kVK_F19, chord));
    ClickView(recorder, NSMakePoint(NSMidX(recorder.bounds) - 20, NSMidY(recorder.bounds)));
    TypeKey(prefsWindow, kVK_ANSI_N, NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagShift);
    Check(@"a recorded shortcut is saved, registered and shown in ⌃⌥⇧⌘ order", !recorder.recording && prefs.appActivationKeyCode == kVK_ANSI_N &&
          prefs.appActivationModifiers == (chord | shiftKey) && !ShortcutIsFree(kVK_ANSI_N, chord | shiftKey) && ShortcutIsFree(kVK_F19, chord) &&
          [recorder.accessibilityLabel hasPrefix:@"⌃⌥⇧⌘"]);
    NVHotKey *competitor = [[[NVHotKey alloc] initWithTarget:nil action:NULL] autorelease];
    [competitor registerKeyCode:kVK_F18 carbonModifiers:chord];
    ClickView(recorder, NSMakePoint(NSMidX(recorder.bounds) - 20, NSMidY(recorder.bounds)));
    TypeKey(prefsWindow, kVK_F18, NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl | NSEventModifierFlagFunction);
    Check(@"a shortcut already in use is refused and the previous one restored", prefs.appActivationKeyCode == kVK_ANSI_N && recorder.keyCode == kVK_ANSI_N &&
          !ShortcutIsFree(kVK_ANSI_N, chord | shiftKey));
    [competitor unregister];
    ClickView(recorder, NSMakePoint(NSMidX(recorder.bounds) - 20, NSMidY(recorder.bounds)));
    TypeKey(prefsWindow, kVK_F18, NSEventModifierFlagFunction);
    Check(@"a function key alone can be recorded", prefs.appActivationKeyCode == kVK_F18 && prefs.appActivationModifiers == 0 && !ShortcutIsFree(kVK_F18, 0) &&
          [recorder.accessibilityLabel isEqualToString:@"F18"]);
    for (NSString *appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        [prefsWindow setAppearance:[NSAppearance appearanceNamed:appearance]];
        Pump(0.2);
        SnapshotWindow(prefsWindow, [NSString stringWithFormat:@"settings-general-%@.png", [appearance isEqualToString:NSAppearanceNameAqua] ? @"light" : @"dark"]);
    }
    [prefsWindow setAppearance:nil];
    NSButton *clearButton = [recorder valueForKey:@"clearButton"];
    BOOL clearable = !clearButton.hidden && prefs.appActivationKeyCode >= 0;
    [clearButton performClick:nil];
    Check(@"the remove button clears the shortcut", clearable && prefs.appActivationKeyCode == -1 && recorder.keyCode == -1 && ShortcutIsFree(kVK_F18, 0) && clearButton.hidden);
    ClickView(recorder, NSMakePoint(NSMidX(recorder.bounds), NSMidY(recorder.bounds)));
    TypeKey(prefsWindow, kVK_ANSI_N, NSEventModifierFlagCommand | NSEventModifierFlagOption);
    ClickView(recorder, NSMakePoint(NSMidX(recorder.bounds), NSMidY(recorder.bounds)));
    BOOL recordedBeforeDelete = recorder.recording && prefs.appActivationKeyCode == kVK_ANSI_N;
    TypeKey(prefsWindow, kVK_Delete, 0);
    Check(@"Delete while recording removes the shortcut", recordedBeforeDelete && !recorder.recording && prefs.appActivationKeyCode == -1 && ShortcutIsFree(kVK_ANSI_N, cmdKey | optionKey));
}

static void CompleteDesktopAcceptance(AppController *app, NotationController *notation, NSWindow *window, LinkingEditor *editor) {
    @try {
        [NSApp hide:nil];
        NSDate *hideLimit = [NSDate dateWithTimeIntervalSinceNow:3];
        while ((!NSApp.isHidden || NSApp.isActive) && hideLimit.timeIntervalSinceNow > 0) Pump(0.05);
        [app bringFocusToControlField:nil];
        WaitForActivation(window);
        Pump(0.2);
        Check(@"activation restores search focus", window.visible && window.firstResponder != editor);
        NVHotKey *hotkey = [[[NVHotKey alloc] initWithTarget:[[[NVHotkeyRecorder alloc] init] autorelease] action:@selector(fired:)] autorelease];
        BOOL registered = [hotkey registerKeyCode:kVK_F20 carbonModifiers:cmdKey | optionKey | controlKey];
        EventHotKeyID identity = { 'NVhk', [[hotkey valueForKey:@"identifier"] unsignedIntValue] };
        EventRef event = NULL;
        OSStatus eventStatus = CreateEvent(NULL, kEventClassKeyboard, kEventHotKeyPressed, 0, 0, &event);
        if (eventStatus == noErr) {
            SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, sizeof(identity), &identity);
            eventStatus = SendEventToEventTarget(event, GetEventDispatcherTarget());
        }
        if (event) ReleaseEvent(event);
        Check(@"hotkey registration and Carbon event dispatch", registered && eventStatus == noErr && hotkeyCount == 1);
        Check(@"a shortcut another hot key owns is refused", !ShortcutIsFree(kVK_F20, cmdKey | optionKey | controlKey));
        [hotkey unregister];
        Check(@"an unregistered shortcut is released", ShortcutIsFree(kVK_F20, cmdKey | optionKey | controlKey));
        NoteObject *note = [app valueForKey:@"currentNote"];
        CheckExternalEditor(note);
        [notation.notationPrefs setNotesStorageFormat:SingleDatabaseFormat];
        Check(@"return to database storage", [notation flushAllNoteChanges]);
        CheckEditingCache(NO);
        [notation.notationPrefs forgetKeychainIdentifier];
        NSData *password = [@"sanitized runtime acceptance password" dataUsingEncoding:NSUTF8StringEncoding];
        [notation.notationPrefs setPassphraseData:password inKeychain:YES];
        Check(@"encryption Keychain round trip", [[notation.notationPrefs passwordDataFromKeychain] isEqualToData:password]);
        [notation.notationPrefs setDoesEncryption:YES];
        Check(@"encrypted database saved", [notation flushAllNoteChanges]);
        NSDictionary *saved = @{@"keychainAccount": [NSString stringWithUTF8String:[notation.notationPrefs setKeychainIdentifier]]};
        [[NSJSONSerialization dataWithJSONObject:saved options:0 error:NULL] writeToFile:[acceptanceRoot stringByAppendingPathComponent:@"identity.json"] atomically:YES];
        CheckEditingCache(YES);
        [app showPreferencesWindow:nil];
        Pump(0.1);
        Check(@"preferences window", [[NSApp windows] count] > 1);
        PrefsWindowController *preferences = [app valueForKey:@"prefsWindowController"];
        NSWindow *prefsWindow = [preferences valueForKey:@"window"];
        NSRect settingsFrame = prefsWindow.frame;
        BOOL stableFrame = YES, allItemsVisible = YES;
        for (NSToolbarItem *item in prefsWindow.toolbar.items) {
            [preferences switchViews:item];
            stableFrame &= NSEqualRects(settingsFrame, prefsWindow.frame);
            Pump(0.1);
            stableFrame &= NSEqualRects(settingsFrame, prefsWindow.frame);
            allItemsVisible &= prefsWindow.toolbar.visibleItems.count == 7 && [prefsWindow.toolbar.selectedItemIdentifier isEqualToString:item.itemIdentifier];
        }
        Check(@"all seven settings icons remain visible in every pane", allItemsVisible);
        Check(@"settings pane changes keep the window frame constant", stableFrame);
        Check(@"settings minimum width fits the toolbar", prefsWindow.contentMinSize.width >= 640 && NSWidth(prefsWindow.contentView.bounds) >= prefsWindow.contentMinSize.width);
        CheckShortcutRecorder(preferences, prefsWindow);
        [preferences switchViews:[[preferences valueForKey:@"items"] objectForKey:@"Fonts & Colors"]];
        NSView *fontsColorsPane = [preferences valueForKey:@"fontsColorsView"];
        NSButton *systemHighlightButton = [preferences valueForKey:@"systemHighlightColorButton"];
        GlobalPrefs *highlightPrefs = [GlobalPrefs defaultPrefs];
        NSColorWell *highlightWell = [preferences valueForKey:@"searchHighlightColorWell"];
        [highlightWell setColor:[NSColor systemPurpleColor]];
        [preferences changedSearchHighlightColorWell:highlightWell];
        BOOL customApplied = [highlightPrefs searchTermHighlightColorIsCustom];
        [systemHighlightButton performClick:nil];
        Check(@"Use System Color returns search highlighting to the system find color", customApplied && ![highlightPrefs searchTermHighlightColorIsCustom] &&
              [[highlightPrefs searchTermHighlightAttributes][NSBackgroundColorAttributeName] isEqual:[NSColor findHighlightColor]] &&
              [highlightWell.color isEqual:[NSColor findHighlightColor]] && !systemHighlightButton.enabled);
        Check(@"Use System Color fits inside the Fonts & Colors pane", systemHighlightButton.window == prefsWindow &&
              NSContainsRect(fontsColorsPane.bounds, [fontsColorsPane convertRect:systemHighlightButton.bounds fromView:systemHighlightButton]));
        NSView *bodyFontField = [preferences valueForKey:@"bodyTextFontField"];
        NSRect bodyFontFrame = bodyFontField.frame;
        BOOL fontRowClear = YES;
        for (NSView *sibling in bodyFontField.superview.subviews)
            if (sibling != bodyFontField && [sibling isKindOfClass:[NSButton class]] && NSIntersectsRect(bodyFontFrame, sibling.frame)) fontRowClear = NO;
        Check(@"body font field does not run under its Set button", fontRowClear);
        SnapshotWindow(prefsWindow, @"settings-fonts-colors.png");
        [preferences switchViews:[[preferences valueForKey:@"items"] objectForKey:@"Notes"]];
        NotationPrefsViewController *notesPreferences = [preferences notationPrefsViewController];
        NSView *notesView = [notesPreferences view];
        NSTabView *notesTabs = (NSTabView *)notesView.subviews.firstObject;
        NSView *storagePopup = [notesPreferences valueForKey:@"storageFormatPopupButton"];
        [notesTabs selectTabViewItemAtIndex:0];
        Check(@"Notes Storage exposes its storage format control", !storagePopup.hiddenOrHasHiddenAncestor && NSContainsRect(notesTabs.selectedTabViewItem.view.bounds, storagePopup.frame));
        for (NSString *appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
            [prefsWindow setAppearance:[NSAppearance appearanceNamed:appearance]];
            for (NSTabViewItem *tabItem in notesTabs.tabViewItems) {
                [notesTabs selectTabViewItem:tabItem];
                Pump(0.2);
                NSString *filename = [NSString stringWithFormat:@"settings-%@-%@.png", tabItem.identifier, [appearance isEqualToString:NSAppearanceNameAqua] ? @"light" : @"dark"];
                SnapshotWindow(prefsWindow, filename);
                if ([appearance isEqualToString:NSAppearanceNameAqua] && [tabItem.identifier isEqual:@"storage"])
                    Check(@"Notes Storage text renders at its control coordinates on first display", WindowSnapshotShowsControlText(storagePopup, filename));
            }
        }
        Check(@"Notes Security exposes encryption controls and hides Storage", [[notesPreferences valueForKey:@"enableEncryptionButton"] window] == prefsWindow && storagePopup.window == nil);
        [prefsWindow setAppearance:nil];
        [preferences switchViews:[[preferences valueForKey:@"items"] objectForKey:@"Display"]];
        Check(@"Display preferences exposes width controls", [[preferences valueForKey:@"displayView"] superview] == prefsWindow.contentView && [[preferences valueForKey:@"textWidthSlider"] isEnabled]);
        [preferences switchViews:[[preferences valueForKey:@"items"] objectForKey:@"Desktop"]];
        Check(@"Desktop preferences exposes Dock and menu bar controls", [[preferences valueForKey:@"desktopView"] superview] == prefsWindow.contentView && [preferences valueForKey:@"showDockIconButton"] && [preferences valueForKey:@"showMenuBarIconButton"]);
        Check(@"no app-owned URL requests with old preferences", requestCount == 0);
        if ([[GlobalPrefs defaultPrefs] horizontalLayout]) [app switchViewLayout:nil];
        SetListPaneSize([app valueForKey:@"splitView"], 140);
        [app switchViewLayout:nil];
        SetListPaneSize([app valueForKey:@"splitView"], 230);
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"FullScreenSwitchedLayout"];
        // Leaving full screen restores the frame the window was first shown with, so the size checked after reopen is set last.
        [window setFrame:NSMakeRect(window.frame.origin.x, window.frame.origin.y, 720, 520) display:YES];
    } @catch (NSException *exception) {
        [checks addObject:@{@"check": @"runtime exception", @"passed": @NO, @"detail": exception.description}];
    }
    FinishAcceptance(@"result.json");
}

static void BeginFullScreenAcceptance(AppController *app, NotationController *notation, NSWindow *window, LinkingEditor *editor) {
    BOOL originalLayout = [[GlobalPrefs defaultPrefs] horizontalLayout];
    BOOL originalSearchVisible = window.toolbar.visible;
    NSLog(@"NV full screen origin active=%d key=%d main=%d space=%d visible=%d mask=%lu behavior=%lu", NSApp.active, window.keyWindow, window.mainWindow, window.isOnActiveSpace, window.visible, window.styleMask, window.collectionBehavior);
    __block BOOL finished = NO;
    __block id enterObserver = nil;
    __block id exitObserver = nil;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    enterObserver = [center addObserverForName:NSWindowDidEnterFullScreenNotification object:window queue:nil usingBlock:^(NSNotification *notification) {
        [center removeObserver:enterObserver];
        enterObserver = nil;
        Check(@"full screen enters a Space", (window.styleMask & NSWindowStyleMaskFullScreen) != 0 && window.isOnActiveSpace);
        Check(@"full screen uses widescreen layout and preserves search visibility", [[GlobalPrefs defaultPrefs] horizontalLayout] && window.toolbar.visible == originalSearchVisible);
        Check(@"full screen applies maximum text width", editor.textContainer.size.width <= [[GlobalPrefs defaultPrefs] maxNoteBodyWidth] + 10);
        exitObserver = [center addObserverForName:NSWindowDidExitFullScreenNotification object:window queue:nil usingBlock:^(NSNotification *note) {
            [center removeObserver:exitObserver];
            exitObserver = nil;
            finished = YES;
            Check(@"full screen exits", (window.styleMask & NSWindowStyleMaskFullScreen) == 0);
            Check(@"full screen restores original layout and search visibility", [[GlobalPrefs defaultPrefs] horizontalLayout] == originalLayout && window.toolbar.visible == originalSearchVisible);
            Check(@"leaving full screen restores unrestricted editor margins", editor.textContainerInset.width == 3);
            BOOL horizontal = [[GlobalPrefs defaultPrefs] horizontalLayout];
            if (horizontal) [app switchViewLayout:nil];
            [app windowWillEnterFullScreen:nil];
            Check(@"full screen records its own layout switch", [[GlobalPrefs defaultPrefs] horizontalLayout] && [[NSUserDefaults standardUserDefaults] boolForKey:@"FullScreenSwitchedLayout"]);
            [app switchViewLayout:nil];
            [app switchViewLayout:nil];
            [app windowDidExitFullScreen:nil];
            Check(@"a layout chosen during full screen is kept on exit", [[GlobalPrefs defaultPrefs] horizontalLayout] && ![[NSUserDefaults standardUserDefaults] objectForKey:@"FullScreenSwitchedLayout"]);
            if ([[GlobalPrefs defaultPrefs] horizontalLayout] != horizontal) [app switchViewLayout:nil];
            [[NSRunLoop mainRunLoop] performBlock:^{ CompleteDesktopAcceptance(app, notation, window, editor); }];
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{ [window toggleFullScreen:nil]; });
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!finished) {
            finished = YES;
            if (enterObserver) [center removeObserver:enterObserver];
            if (exitObserver) [center removeObserver:exitObserver];
            Check(@"full screen transition completed", NO);
            CompleteDesktopAcceptance(app, notation, window, editor);
        }
    });
    [window toggleFullScreen:nil];
}

//text drawn on the accent-colored selection should be light; dark text there is what the light appearance used to produce
static BOOL RowHasDarkPixels(NSTableView *table, NSBitmapImageRep *bitmap, NSInteger row) {
    CGFloat scale = bitmap.pixelsWide / NSWidth(table.bounds);
    //the source-list style insets its rounded selection from the row edges, so only the cells are sampled
    NSRect rect = NSInsetRect([table frameOfCellAtColumn:0 row:row], 4, 4);
    for (NSInteger column = 1; column < table.numberOfColumns; column++)
        rect = NSUnionRect(rect, NSInsetRect([table frameOfCellAtColumn:column row:row], 4, 4));
    for (NSInteger y = NSMinY(rect) * scale; y < NSMaxY(rect) * scale; y++) {
        NSInteger pixelY = table.isFlipped ? y : bitmap.pixelsHigh - 1 - y;
        for (NSInteger x = NSMinX(rect) * scale; x < NSMaxX(rect) * scale; x++)
            if ([[[bitmap colorAtX:x y:pixelY] colorUsingColorSpace:NSColorSpace.sRGBColorSpace] brightnessComponent] < 0.3) return YES;
    }
    return NO;
}

//the line under an unselected row is drawn at the row's bottom edge, not above it where the old row-height arithmetic put it
static BOOL GridLineSitsAtRowBottom(NSTableView *table, NSBitmapImageRep *bitmap, NSInteger row) {
    CGFloat scale = bitmap.pixelsWide / NSWidth(table.bounds);
    NSRect rect = [table rectOfRow:row];
    NSInteger x = (NSMinX(rect) + 4) * scale;
    CGFloat (^brightness)(CGFloat) = ^CGFloat(CGFloat y) {
        NSInteger pixelY = MIN(bitmap.pixelsHigh - 1, (NSInteger)(y * scale));
        if (!table.isFlipped) pixelY = bitmap.pixelsHigh - 1 - pixelY;
        return [[[bitmap colorAtX:x y:pixelY] colorUsingColorSpace:NSColorSpace.sRGBColorSpace] brightnessComponent];
    };
    CGFloat background = brightness(NSMaxY(rect) - 6);
    return fabs(brightness(NSMaxY(rect) - 0.5) - background) > 0.05;
}

//the selected note row in each appearance, layout and focus state, so selection colors can also be compared by eye
static void SnapshotNoteListStates(AppController *app, NSWindow *window, NotesTableView *noteTable, NSTextView *editor, NoteObject *note) {
    GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
    BOOL originalLayout = [prefs horizontalLayout];
    BOOL focusedRowsAreLight = YES, gridFollowsRows = YES, dividersDrawn = YES;
    for (NSString *appearance in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]) {
        [window setAppearance:[NSAppearance appearanceNamed:appearance]];
        for (NSInteger horizontal = 0; horizontal < 2; horizontal++) {
            if ([prefs horizontalLayout] != horizontal) [app switchViewLayout:nil];
            [app revealNote:note options:NVEditNoteToReveal];
            for (NSInteger editorFocused = 0; editorFocused < 2; editorFocused++) {
                [window makeFirstResponder:editorFocused ? editor : noteTable];
                Pump(0.1);
                NSBitmapImageRep *bitmap = SnapshotView(noteTable, [NSString stringWithFormat:@"list-%@-%@-%@.png", [appearance isEqualToString:NSAppearanceNameAqua] ? @"light" : @"dark",
                                         horizontal ? @"horizontal" : @"vertical", editorFocused ? @"editor" : @"list"]);
                if (!editorFocused && RowHasDarkPixels(noteTable, bitmap, noteTable.selectedRow)) focusedRowsAreLight = NO;
                if (horizontal && !editorFocused && noteTable.numberOfRows > 2) gridFollowsRows &= GridLineSitsAtRowBottom(noteTable, bitmap, 1);
            }
            dividersDrawn &= DividerIsDrawn([app valueForKey:@"splitView"]);
            SnapshotWindow(window, [NSString stringWithFormat:@"window-%@-%@.png", [appearance isEqualToString:NSAppearanceNameAqua] ? @"light" : @"dark", horizontal ? @"horizontal" : @"vertical"]);
        }
    }
    if ([prefs horizontalLayout] != originalLayout) [app switchViewLayout:nil];
    [window setAppearance:nil];
    Check(@"focused note list selection uses light text in both appearances and layouts", focusedRowsAreLight);
    Check(@"note list grid lines sit on row boundaries in the sidebar layout", gridFollowsRows);
    Check(@"the divider between notes list and editor is drawn in both layouts and appearances", dividersDrawn);
}

static void RunAcceptance(void) {
    checks = [[NSMutableArray alloc] init];
    @try {
        AppController *app = (id)NSApp.delegate;
        NotationController *notation = [app valueForKey:@"notationController"];
        NSWindow *window = [app window];
        LinkingEditor *editor = [app valueForKey:@"textView"];
        NSArray *notes = [notation valueForKey:@"allNotes"];
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];
        WaitForActivation(window);
        Check(@"real app launch on macOS 26", app && window.visible && notes.count > 0);
        Check(@"retired sync-enabled archive stays inert", [[notation notationPrefs].syncServiceAccounts[@"Simplenote"][@"enabled"] boolValue] && !NSClassFromString(@"SimplenoteSession") && !NSClassFromString(@"SUUpdater"));
        NoteObject *note = notes.firstObject;
        [app searchForString:@"Retained legacy"];
        Check(@"search content", [[notation notesListDataSource] count] == 1);
        [app revealNote:note options:NVEditNoteToReveal | NVOrderFrontWindow];
        Check(@"editor focus", window.firstResponder == editor);
        NVSplitView *split = [app valueForKey:@"splitView"];
        BOOL originalLayout = [[GlobalPrefs defaultPrefs] horizontalLayout];
        [app toggleCollapse:nil];
        Check(@"notes list and search collapse together", ListPaneCollapsed(split) && !window.toolbar.visible && window.firstResponder == editor);
        NSTextField *windowTitle = [app valueForKey:@"windowTitleLabel"];
        Check(@"collapsed search preserves the selected note title", [windowTitle.stringValue isEqualToString:window.title] && [window.title isEqualToString:titleOfNote(note)]);
        [app switchViewLayout:nil];
        Check(@"collapsed notes list survives orientation change", ListPaneCollapsed(split) && !window.toolbar.visible);
        [app toggleCollapse:nil];
        Check(@"notes list and search expand together", !ListPaneCollapsed(split) && window.toolbar.visible);
        Check(@"widescreen divider is visible and draggable", DividerIsVisible(split));
        [app toggleCollapse:nil];
        [app switchViewLayout:nil];
        Check(@"collapsed notes list survives return to original orientation", ListPaneCollapsed(split) && [[GlobalPrefs defaultPrefs] horizontalLayout] == originalLayout);
        [app toggleCollapse:nil];
        [split mouseDown:DividerDoubleClick(split)];
        Check(@"divider double-click collapses notes list", ListPaneCollapsed(split) && !window.toolbar.visible);
        GlobalPrefs *displayPrefs = [GlobalPrefs defaultPrefs];
        NSString *beforeWidthChange = [[editor.string copy] autorelease];
        [displayPrefs setMaxNoteBodyWidth:320 sender:nil];
        [displayPrefs setManagesTextWidthInWindow:YES sender:nil];
        Check(@"editor text width is capped with centered margins", editor.textContainerInset.width >= 8 && editor.textContainer.size.width <= 330);
        Check(@"text width changes preserve note contents", [editor.string isEqualToString:beforeWidthChange]);
        [displayPrefs setManagesTextWidthInWindow:NO sender:nil];
        Check(@"disabling width limit restores editor margins", editor.textContainerInset.width == 3);
        [displayPrefs setMaxNoteBodyWidth:660 sender:nil];
        [split mouseDown:DividerDoubleClick(split)];
        Check(@"divider double-click expands the collapsed notes list", !ListPaneCollapsed(split) && window.toolbar.visible);
        CGFloat minimumListSize = [displayPrefs horizontalLayout] ? 100 : 60;
        SetListPaneSize(split, 150);
        DragDivider(split, minimumListSize - 10);
        Check(@"dragging the divider stops the notes list at its minimum size", !ListPaneCollapsed(split) && fabs(ListPaneSize(split) - minimumListSize) < 1);
        SetListPaneSize(split, 150);
        DragDivider(split, 2);
        BOOL draggedClosed = ListPaneCollapsed(split) && !window.toolbar.visible;
        [app toggleCollapse:nil];
        Check(@"dragging the divider closed collapses the notes list, which reopens at its earlier size",
              draggedClosed && !ListPaneCollapsed(split) && window.toolbar.visible && fabs(ListPaneSize(split) - 150) < 1);
        NSRect frameBeforeGrowth = window.frame;
        [window setFrame:NSInsetRect(frameBeforeGrowth, -40, -40) display:YES];
        BOOL keptWhileGrowing = fabs(ListPaneSize(split) - 150) < 1;
        [window setFrame:frameBeforeGrowth display:YES];
        Check(@"notes list keeps its size when the window is resized", keptWhileGrowing && fabs(ListPaneSize(split) - 150) < 1);
        SetListPaneSize(split, 140);
        [app switchViewLayout:nil];
        SetListPaneSize(split, 230);
        [app switchViewLayout:nil];
        CGFloat firstLayoutSize = ListPaneSize(split);
        [app switchViewLayout:nil];
        CGFloat secondLayoutSize = ListPaneSize(split);
        [app switchViewLayout:nil];
        Check(@"each layout remembers its own notes list size", fabs(firstLayoutSize - 140) < 1 && fabs(secondLayoutSize - 230) < 1);
        NSUserDefaults *layoutDefaults = [NSUserDefaults standardUserDefaults];
        NSArray *layoutKeys = @[@"NotesListHeight", @"NotesListWidth", @"NotesListCollapsed"];
        NSDictionary *savedLayout = [layoutDefaults dictionaryWithValuesForKeys:layoutKeys];
        for (NSString *key in layoutKeys) [layoutDefaults removeObjectForKey:key];
        [layoutDefaults setObject:@"2 153.335526 304.664474" forKey:@"RBSplitView H centralSplitView"];
        [layoutDefaults setObject:@"2 -212.25 180" forKey:@"RBSplitView V centralSplitView"];
        [AppController migrateLegacyNotesListLayoutInDefaults:layoutDefaults sideBySide:YES];
        Check(@"RBSplitView divider positions migrate to the notes list layout settings",
              [layoutDefaults doubleForKey:@"NotesListHeight"] == 153 && [layoutDefaults doubleForKey:@"NotesListWidth"] == 212 &&
              [layoutDefaults boolForKey:@"NotesListCollapsed"] && ![layoutDefaults objectForKey:@"RBSplitView H centralSplitView"] &&
              ![layoutDefaults objectForKey:@"RBSplitView V centralSplitView"]);
        for (NSString *key in layoutKeys) {
            id value = savedLayout[key];
            if (value == [NSNull null]) [layoutDefaults removeObjectForKey:key];
            else [layoutDefaults setObject:value forKey:key];
        }
        [displayPrefs setShowMenuBarIcon:YES sender:nil];
        NSStatusItem *menuBarItem = [app valueForKey:@"statusItem"];
        Check(@"menu bar icon exposes a native click action", menuBarItem.button.image && menuBarItem.button.target == app && menuBarItem.button.action == @selector(statusItemAction:));
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];
        WaitForActivation(window);
        Check(@"menu bar button keeps its target", menuBarItem.button.target == app && menuBarItem.button.action == @selector(statusItemAction:));
        Check(@"menu bar action is delivered", [NSApp sendAction:@selector(statusItemAction:) to:app from:menuBarItem.button]);
        // Restoring before the system has handed activation to another app lets that handoff land afterwards and deactivate the app.
        NSDate *hideLimit = [NSDate dateWithTimeIntervalSinceNow:3];
        while ((window.visible || NSApp.isActive) && hideLimit.timeIntervalSinceNow > 0) Pump(0.05);
        Check(@"menu bar action hides the note window", !window.visible);
        Check(@"menu bar button keeps its target", menuBarItem.button.target == app && menuBarItem.button.action == @selector(statusItemAction:));
        Check(@"menu bar action is delivered", [NSApp sendAction:@selector(statusItemAction:) to:app from:menuBarItem.button]);
        WaitForActivation(window);
        Pump(0.1);
        Check(@"menu bar action restores the note window and search focus", NSApp.isActive && !NSApp.isHidden && window.isKeyWindow && window.firstResponder == [[app valueForKey:@"field"] currentEditor]);
        NSMenu *menuBarMenu = [app valueForKey:@"statusMenu"];
        AcceptanceStatusMenuObserver *menuObserver = [[[AcceptanceStatusMenuObserver alloc] init] autorelease];
        menuBarMenu.delegate = menuObserver;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
            [menuBarMenu cancelTrackingWithoutAnimation];
        });
        [app showStatusMenu:nil];
        Check(@"menu bar context menu opens with recovery commands", menuObserver.opened && menuBarMenu.numberOfItems == 6);
        menuBarMenu.delegate = nil;
        [displayPrefs setShowDockIcon:NO sender:nil];
        NSDate *policyLimit = [NSDate dateWithTimeIntervalSinceNow:2];
        while (NSApp.activationPolicy != NSApplicationActivationPolicyAccessory && policyLimit.timeIntervalSinceNow > 0) Pump(0.05);
        Check(@"Dock can be hidden while the menu bar stays available", NSApp.activationPolicy == NSApplicationActivationPolicyAccessory && [app valueForKey:@"statusItem"] && displayPrefs.showMenuBarIcon);
        [displayPrefs setShowMenuBarIcon:NO sender:nil];
        policyLimit = [NSDate dateWithTimeIntervalSinceNow:2];
        while (NSApp.activationPolicy != NSApplicationActivationPolicyRegular && policyLimit.timeIntervalSinceNow > 0) Pump(0.05);
        Check(@"removing the last menu bar entry restores the Dock", NSApp.activationPolicy == NSApplicationActivationPolicyRegular && displayPrefs.showDockIcon && ![app valueForKey:@"statusItem"]);
        [app revealNote:note options:NVEditNoteToReveal | NVOrderFrontWindow];
        NSString *original = [[editor.string copy] autorelease];
        [displayPrefs setUseAutoPairing:YES sender:nil];
        [editor setSelectedRange:NSMakeRange(editor.string.length, 0)];
        NSUInteger pairStart = editor.string.length;
        [editor insertText:@"(" replacementRange:editor.selectedRange];
        Check(@"typing an opening character creates a pair", [editor.string hasSuffix:@"()"] && editor.selectedRange.location == pairStart + 1);
        [editor deleteBackward:nil];
        Check(@"backspace removes an empty pair together", [editor.string isEqualToString:original]);
        [editor setSelectedRange:NSMakeRange(0, MIN(5, editor.string.length))];
        NSString *selected = [editor.string substringWithRange:editor.selectedRange];
        [editor insertText:@"[" replacementRange:editor.selectedRange];
        Check(@"pairing wraps selection and preserves text", [editor.string hasPrefix:[NSString stringWithFormat:@"[%@]", selected]] && editor.selectedRange.length == selected.length);
        [editor.undoManager undo];
        Check(@"undo restores wrapped selection contents", [editor.string isEqualToString:original]);
        [displayPrefs setUseAutoPairing:NO sender:nil];
        [editor setSelectedRange:NSMakeRange(0, 0)];
        [editor insertParagraphAbove:nil];
        Check(@"paragraph above inserts before first paragraph", [editor.string hasPrefix:@"\n"] && editor.selectedRange.location == 0);
        [editor.undoManager undo];
        [editor setSelectedRange:NSMakeRange(0, 0)];
        NSEvent *paragraphKey = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:NSEventModifierFlagCommand timestamp:0 windowNumber:window.windowNumber context:nil characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36];
        Check(@"Command Return inserts a paragraph through the keyboard path", [editor performKeyEquivalent:paragraphKey] && editor.string.length > original.length);
        [editor.undoManager undo];
        Check(@"paragraph insertion undo preserves note", [editor.string isEqualToString:original]);
        [displayPrefs setRightToLeftEditing:YES sender:nil];
        Check(@"right to left editing applies paragraph direction", [[editor.textStorage attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL] baseWritingDirection] == NSWritingDirectionRightToLeft);
        [displayPrefs setRightToLeftEditing:NO sender:nil];
        [displayPrefs setShowWordCount:YES sender:nil];
        Check(@"word count is available as an optional footer", ![[app valueForKey:@"wordCountLabel"] isHidden] && [[[app valueForKey:@"wordCountLabel"] stringValue] hasSuffix:@" words"]);
        [displayPrefs setShowWordCount:NO sender:nil];
        NSEvent *optionEvent = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:NSEventModifierFlagOption timestamp:0 windowNumber:window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:58];
        [app flagsChanged:optionEvent];
        Check(@"holding Option reveals word count", ![[app valueForKey:@"wordCountLabel"] isHidden]);
        NSEvent *releaseEvent = [NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:58];
        [app flagsChanged:releaseEvent];
        Check(@"releasing Option hides temporary word count", [[app valueForKey:@"wordCountLabel"] isHidden]);
        for (NSString *task in @[@"Task @done(2026-10-07)", @"Task @done - 2026-10-07"]) {
            NSMutableAttributedString *doneText = [[[NSMutableAttributedString alloc] initWithString:task] autorelease];
            [doneText addStrikethroughNearDoneTagsForRange:NSMakeRange(0, doneText.length)];
            Check(@"dated TaskPaper completion marks strike task text", [[doneText attribute:NSStrikethroughStyleAttributeName atIndex:0 effectiveRange:NULL] integerValue] == NSUnderlineStyleSingle);
            Check(@"completion marker remains readable", ![doneText attribute:NSStrikethroughStyleAttributeName atIndex:[task rangeOfString:@"@done"].location effectiveRange:NULL]);
        }
        [editor setSelectedRange:NSMakeRange(editor.string.length, 0)];
        [editor insertText:@"\nAcceptance edit [[Project Alpha]] https://example.com" replacementRange:editor.selectedRange];
        Pump(0.2);
        Check(@"editing updates local model", [note->contentString.string containsString:@"Acceptance edit"]);
        [editor.undoManager undo];
        Check(@"undo restores content", [editor.string isEqualToString:original] && [note->contentString.string isEqualToString:original]);
        [editor setSelectedRange:NSMakeRange(editor.string.length, 0)];
        [editor insertText:@"\nPersisted acceptance edit" replacementRange:editor.selectedRange];
        Pump(0.2);
        Check(@"database flush", [notation flushAllNoteChanges]);
        NSMutableAttributedString *links = [[[NSMutableAttributedString alloc] initWithString:@"[[Project Alpha]] https://example.com/a%2Fb"] autorelease];
        [links addLinkAttributesForRange:NSMakeRange(0, links.length)];
        Check(@"wiki link", [[links attribute:NSLinkAttributeName atIndex:2 effectiveRange:NULL] isKindOfClass:[NSURL class]]);
        Check(@"encoded URL boundary", [[[links attribute:NSLinkAttributeName atIndex:20 effectiveRange:NULL] absoluteString] containsString:@"a%2Fb"]);
        CFUUIDBytes uuid = *[note uniqueNoteIDBytes];
        NSURL *identityLink = note.uniqueNoteLink;
        [note setTitleString:@"Renamed acceptance note"];
        [app interpretNVURL:identityLink];
        Check(@"UUID routing after rename", [app valueForKey:@"currentNote"] == note && [notation noteForUUIDBytes:&uuid] == note);
        NSPasteboard *pasteboard = [NSPasteboard pasteboardWithUniqueName];
        [pasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
        [pasteboard setString:@"Service acceptance\nSanitized selection" forType:NSPasteboardTypeString];
        NSString *serviceError = nil;
        [app createFromSelection:pasteboard userData:nil error:&serviceError];
        Check(@"Services selection creates note", !serviceError && [[notation valueForKey:@"allNotes"] count] == 2);
        [pasteboard releaseGlobally];
        NVFileReference exportDirectory;
        NVPathMakeReference((const UInt8 *)acceptanceRoot.fileSystemRepresentation, &exportDirectory, NULL);
        Check(@"text export", [note exportToDirectoryRef:&exportDirectory withFilename:@"Exported acceptance.txt" usingFormat:PlainTextFormat overwrite:NO] == noErr);
        Check(@"text import", [notation openFiles:@[[acceptanceRoot stringByAppendingPathComponent:@"Exported acceptance.txt"]]]);
        ExporterManager *exporter = [ExporterManager sharedManager];
        for (NSString *exportName in @[@"Export without extension", @"Custom export.log"]) {
            [exporter exportNotes:@[note] forWindow:window];
            Pump(0.4);
            NSSavePanel *panel = [exporter valueForKey:@"exportPanel"];
            [panel setDirectoryURL:[NSURL fileURLWithPath:acceptanceRoot isDirectory:YES]];
            [panel setNameFieldStringValue:exportName];
            NSPopUpButton *format = [exporter valueForKey:@"formatSelectorPopup"];
            [format selectItemWithTag:RTFTextFormat];
            [exporter formatSelectorChanged:format];
            [format selectItemWithTag:PlainTextFormat];
            [exporter formatSelectorChanged:format];
            Check(@"export format changes leave filename extensions unrestricted", panel.allowedContentTypes.count == 0 && panel.allowsOtherFileTypes);
            Check(@"export format changes keep custom filenames", [panel.nameFieldStringValue isEqualToString:exportName]);
            if ([exportName isEqualToString:@"Custom export.log"]) {
                [panel setNameFieldStringValue:@"Suggested.txt"];
                [format selectItemWithTag:RTFTextFormat];
                [exporter formatSelectorChanged:format];
                Check(@"export format changes update a format extension", [panel.nameFieldStringValue isEqualToString:@"Suggested.rtf"]);
                [format selectItemWithTag:PlainTextFormat];
                [exporter formatSelectorChanged:format];
                [panel setNameFieldStringValue:exportName];
            }
            [panel cancel:nil];
            NSDate *cancelLimit = [NSDate dateWithTimeIntervalSinceNow:3];
            while (window.attachedSheet && cancelLimit.timeIntervalSinceNow > 0) Pump(0.1);
            Check(@"export panel cancellation completes", !window.attachedSheet && ![exporter valueForKey:@"exportPanel"]);
            AcceptanceExportDestination *destination = [[[AcceptanceExportDestination alloc] init] autorelease];
            destination.URL = [NSURL fileURLWithPath:[acceptanceRoot stringByAppendingPathComponent:exportName]];
            [exporter exportPanelDidEnd:(id)destination returnCode:NSModalResponseOK contextInfo:(void *)[@[note] retain]];
            NSString *exportPath = [acceptanceRoot stringByAppendingPathComponent:exportName];
            NSDate *exportLimit = [NSDate dateWithTimeIntervalSinceNow:4];
            while (![[NSFileManager defaultManager] fileExistsAtPath:exportPath] && exportLimit.timeIntervalSinceNow > 0) Pump(0.1);
            Check(@"export honors the chosen filename and content", [[NSString stringWithContentsOfFile:exportPath encoding:NSUTF8StringEncoding error:NULL] isEqualToString:note->contentString.string]);
            if ([exporter valueForKey:@"exportPanel"]) [panel cancel:nil];
            Pump(0.1);
        }
        Check(@"additional fork editors are recognized", [[NSSet setWithArray:@[@"com.sublimetext.2", @"com.metaclassy.byword", @"jp.informationarchitects.WriterForMacOSX"]] isSubsetOfSet:[ExternalEditorListController ODBAppIdentifiers]]);
        [notation.notationPrefs setNotesStorageFormat:PlainTextFormat];
        Check(@"individual file persistence", [notation flushAllNoteChanges] && [[NSFileManager defaultManager] fileExistsAtPath:note.noteFilePath]);
        NSArray *tagNotes = [notation notesAtIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)]];
        NoteObject *firstTagged = tagNotes[0], *secondTagged = tagNotes[1];
        [firstTagged setLabelString:@"shared, unique-one"];
        [secondTagged setLabelString:@"SHARED, unique-two"];
        [app searchForString:@""];
        [[app valueForKey:@"notesTableView"] selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];
        [app tagNote:nil];
        NSDate *tagSheetLimit = [NSDate dateWithTimeIntervalSinceNow:3];
        while (!window.attachedSheet && tagSheetLimit.timeIntervalSinceNow > 0) Pump(0.05);
        NSTokenField *tagField = [app valueForKey:@"multiTagField"];
        Check(@"multiple notes expose a shared-tag editor", window.attachedSheet && tagField && [[tagField objectValue] count] == 1);
        [tagField setObjectValue:@[@"new-tag"]];
        if (window.attachedSheet) [NSApp endSheet:window.attachedSheet returnCode:NSAlertFirstButtonReturn];
        tagSheetLimit = [NSDate dateWithTimeIntervalSinceNow:3];
        while ((window.attachedSheet || [app valueForKey:@"multiTagField"]) && tagSheetLimit.timeIntervalSinceNow > 0) Pump(0.05);
        Check(@"shared-tag sheet closes", !window.attachedSheet && ![app valueForKey:@"multiTagField"]);
        Check(@"shared-tag changes preserve unique tags", [labelsOfNote(firstTagged) containsString:@"unique-one"] && [labelsOfNote(secondTagged) containsString:@"unique-two"] && [labelsOfNote(firstTagged) containsString:@"new-tag"] && ![labelsOfNote(secondTagged).lowercaseString containsString:@"shared"]);
        [firstTagged setLabelString:@""];
        [secondTagged setLabelString:@""];
        [app revealNote:note options:NVEditNoteToReveal];
        NSMenuItem *findCommand = FindMenuCommand(NSApp.mainMenu);
        Check(@"Find menu targets the note editor from search focus", findCommand && findCommand.target == editor);
        NSPasteboard *findPasteboard = [NSPasteboard pasteboardWithName:NSPasteboardNameFind];
        NSString *savedFindString = [[[findPasteboard stringForType:NSPasteboardTypeString] copy] autorelease];
        NSMenuItem *nextMatch = [[[NSMenuItem alloc] initWithTitle:@"Next" action:@selector(performFindPanelAction:) keyEquivalent:@""] autorelease];
        nextMatch.tag = NSTextFinderActionNextMatch;
        [app searchForString:@"Retained"];
        [[app valueForKey:@"notesTableView"] deselectAll:nil];
        Check(@"Find is disabled when no note is selected", ![editor validateMenuItem:findCommand] && [editor validateMenuItem:nextMatch]);
        [NSApp sendAction:findCommand.action to:findCommand.target from:findCommand];
        Pump(0.3);
        Check(@"Find does nothing when no note is selected", ![app selectedNoteObject] && !editor.enclosingScrollView.isFindBarVisible);
        [editor performFindPanelAction:nextMatch];
        Pump(0.2);
        Check(@"Find Next selects a note when none is selected", [app selectedNoteObject] != nil);
        [app searchForString:@""];
        [app revealNote:note options:NVEditNoteToReveal];
        NSPasteboard *clipboard = [NSPasteboard generalPasteboard];
        NSMutableDictionary *savedClipboard = [NSMutableDictionary dictionary];
        for (NSString *type in clipboard.types) {
            NSData *data = [clipboard dataForType:type];
            if (data) savedClipboard[type] = data;
        }
        [clipboard declareTypes:@[NSPasteboardTypeString] owner:nil];
        [clipboard setString:@"Clipboard only" forType:NSPasteboardTypeString];
        [findPasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
        [findPasteboard setString:@"Shared find text" forType:NSPasteboardTypeString];
        [NSApp sendAction:findCommand.action to:findCommand.target from:findCommand];
        Pump(0.3);
        Check(@"Find opens the find bar for the selected note", editor.enclosingScrollView.isFindBarVisible);
        Check(@"Find keeps the shared find text", [[findPasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"Shared find text"]);
        [clipboard declareTypes:savedClipboard.allKeys owner:nil];
        for (NSString *type in savedClipboard) [clipboard setData:savedClipboard[type] forType:type];
        NSView *findBar = editor.enclosingScrollView.findBarView;
        [app revealNote:secondTagged options:NVEditNoteToReveal];
        Pump(0.3);
        Check(@"Find bar survives switching notes", editor.enclosingScrollView.isFindBarVisible && editor.enclosingScrollView.findBarView == findBar);
        [app revealNote:note options:NVEditNoteToReveal];
        NSMenuItem *useSelection = [[[NSMenuItem alloc] initWithTitle:@"Use Selection" action:@selector(performFindPanelAction:) keyEquivalent:@""] autorelease];
        useSelection.tag = NSTextFinderActionSetSearchString;
        [editor setSelectedRange:[editor.string rangeOfString:@"Retained" options:NSCaseInsensitiveSearch]];
        [editor performFindPanelAction:useSelection];
        [editor setSelectedRange:NSMakeRange(0, 0)];
        [editor performFindPanelAction:nextMatch];
        Pump(0.2);
        Check(@"Find searches the newly displayed note", editor.selectedRange.length && [[editor.string substringWithRange:editor.selectedRange] localizedCaseInsensitiveContainsString:@"Retained"]);
        [editor clearFindPanel];
        if (savedFindString) {
            [findPasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
            [findPasteboard setString:savedFindString forType:NSPasteboardTypeString];
        }
        [window makeFirstResponder:[app valueForKey:@"field"]];
        [editor setContinuousSpellCheckingEnabled:YES];
        Check(@"spelling preference stays enabled without editor focus", editor.isContinuousSpellCheckingEnabled && displayPrefs.checkSpellingAsYouType);
        [editor setAutomaticTextReplacementEnabled:YES];
        [editor setAutomaticQuoteSubstitutionEnabled:YES];
        [editor setAutomaticDashSubstitutionEnabled:YES];
        [editor setSmartInsertDeleteEnabled:YES];
        Check(@"native substitution changes persist", displayPrefs.useTextReplacement && displayPrefs.useSmartQuotes && displayPrefs.useSmartDashes && displayPrefs.useSmartInsertDelete);
        [displayPrefs setUseTextReplacement:NO sender:nil];
        [displayPrefs setUseSmartQuotes:NO sender:nil];
        [displayPrefs setUseSmartDashes:NO sender:nil];
        [displayPrefs setUseSmartInsertDelete:NO sender:nil];
        Check(@"preference changes update native editing behavior", !editor.isAutomaticTextReplacementEnabled && !editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled && !editor.smartInsertDeleteEnabled);
        [app bringFocusToControlField:nil];
        WaitForActivation(window);
        Pump(0.2);
        Check(@"activation finishes with the search field focused", window.firstResponder == [[app valueForKey:@"field"] currentEditor]);
        [app revealNote:note options:NVEditNoteToReveal];
        NSString *filename = note.noteFilePath;
        NSTask *externalWriter = [[[NSTask alloc] init] autorelease];
        externalWriter.launchPath = @"/usr/bin/python3";
        externalWriter.arguments = @[@"-c", @"import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('Automatic file monitoring acceptance\\n')", filename];
        [externalWriter launch];
        [externalWriter waitUntilExit];
        NSDate *monitoringLimit = [NSDate dateWithTimeIntervalSinceNow:6];
        while (![note->contentString.string containsString:@"Automatic file monitoring acceptance"] && monitoringLimit.timeIntervalSinceNow > 0)
            Pump(0.1);
        Check(@"automatic local directory monitoring", [note->contentString.string containsString:@"Automatic file monitoring acceptance"]);
        [app searchForString:@""];
        [app revealNote:note options:NVEditNoteToReveal | NVOrderFrontWindow];
        [window setFrame:NSMakeRect(window.frame.origin.x, window.frame.origin.y, 720, 520) display:YES];
        Check(@"window resizing", fabs(window.frame.size.width - 720) < 1);
        DualField *searchField = [app valueForKey:@"field"];
        NSRect originalFrame = window.frame;
        [app searchForString:@"jjjj"];
        for (NSNumber *width in @[@410, @960]) {
            NSRect frame = originalFrame;
            frame.size.width = width.doubleValue;
            [window setFrame:frame display:YES];
            Pump(0.05);
            NSRect fieldFrame = [searchField convertRect:searchField.bounds toView:nil];
            NSButton *closeButton = [window standardWindowButton:NSWindowCloseButton];
            NSRect buttonFrame = [closeButton convertRect:closeButton.bounds toView:nil];
            Check([NSString stringWithFormat:@"compact search fills a %@-point window below its title", width],
                  NSWidth(fieldFrame) >= NSWidth(window.frame) - 48 && NSHeight(fieldFrame) == 23 && NSMaxY(fieldFrame) < NSMinY(buttonFrame));
            NSRect titleFrame = [windowTitle convertRect:windowTitle.bounds toView:nil];
            Check(@"window title stays centered and draggable while resizing", fabs(NSMidX(titleFrame) - NSWidth(window.frame) / 2) < 1 && windowTitle.mouseDownCanMoveWindow);
            NSTextView *fieldEditor = (id)searchField.currentEditor;
            NSRect editingFrame = [searchField convertRect:fieldEditor.bounds fromView:fieldEditor];
            NSRect iconFrame = [searchField.cell snapbackButtonRectForBounds:searchField.bounds];
            NSRect clearFrame = [searchField.cell clearButtonRectForBounds:searchField.bounds];
            Check(@"search editing stays between its icons while resizing", [fieldEditor.string isEqualToString:@"jjjj"] &&
                  NSMinX(editingFrame) >= NSMaxX(iconFrame) && NSMaxX(editingFrame) <= NSMinX(clearFrame) &&
                  NSContainsRect(searchField.bounds, editingFrame));
        }
        [window setFrame:originalFrame display:YES];
        [app searchForString:@""];
        [app revealNote:note options:NVEditNoteToReveal];
        GlobalPrefs *appearancePrefs = [GlobalPrefs defaultPrefs];
        NotesTableView *noteTable = [app valueForKey:@"notesTableView"];
        Check(@"expanded note list retains visible rows", noteTable.numberOfRows == 3 && !noteTable.isHiddenOrHasHiddenAncestor && noteTable.visibleRect.size.height > 60);
        Check(@"note list rows are drawn inside the split view", RowIsDrawnWithin([app valueForKey:@"splitView"], noteTable, 0));
        Check(@"sorted and unsorted note list headers share one title position", HeaderTitlesShareVerticalCentre(noteTable));
        NSRect frameBeforeLayoutSwitch = window.frame;
        [app switchViewLayout:nil];
        BOOL widescreenHidesHeader = noteTable.headerView == nil;
        [app switchViewLayout:nil];
        Check(@"layout switches toggle the note list header without resizing the window", widescreenHidesHeader && noteTable.headerView &&
              NSEqualRects(window.frame, frameBeforeLayoutSwitch) && RowIsDrawnWithin([app valueForKey:@"splitView"], noteTable, 0));
        [note setLabelString:@"alpha beta"];
        if (!ColumnIsSet(NoteLabelsColumn, [appearancePrefs tableColumnsBitmap]))
            [noteTable addPermanentTableColumn:[noteTable noteAttributeColumnForIdentifier:NoteLabelsColumnString]];
        SnapshotNoteListStates(app, window, noteTable, editor, note);
        NSDictionary *highlight = [appearancePrefs searchTermHighlightAttributes];
        Check(@"search highlight defaults to the system find color with readable text",
              [highlight[NSBackgroundColorAttributeName] isEqual:[NSColor findHighlightColor]] && [highlight[NSForegroundColorAttributeName] isEqual:[NSColor blackColor]]);
        NSMenuItem *settingsItem = MenuItemWithAction(NSApp.mainMenu, @selector(showPreferencesWindow:));
        NSMenuItem *spellingItem = nil;
        NSMenu *editMenu = MenuItemWithAction(NSApp.mainMenu, @selector(toggleContinuousSpellChecking:)).menu.supermenu;
        for (NSMenuItem *item in editMenu.itemArray)
            if (item.submenu && [item.submenu indexOfItemWithTarget:nil andAction:@selector(toggleContinuousSpellChecking:)] != -1) spellingItem = item;
        NSInteger afterSpellingIndex = spellingItem ? [editMenu indexOfItem:spellingItem] + 1 : editMenu.numberOfItems;
        NSMenuItem *afterSpelling = afterSpellingIndex < editMenu.numberOfItems ? [editMenu itemAtIndex:afterSpellingIndex] : nil;
        Check(@"app menu opens Settings", [settingsItem.title isEqualToString:@"Settings…"]);
        Check(@"edit menu has Spelling and Grammar", [spellingItem.title isEqualToString:@"Spelling and Grammar"]);
        NSTextField *emptyLabel = [[app valueForKey:@"editorStatusView"] valueForKey:@"labelText"];
        NSMenuItem *boldItem = MenuItemWithAction(NSApp.mainMenu, @selector(bold:));
        NSFont *boldTitleFont = [boldItem.attributedTitle attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL];
        Check(@"empty editor label and styled Format menu titles use system fonts",
              [emptyLabel.font.familyName isEqualToString:[NSFont systemFontOfSize:12].familyName] &&
              [boldTitleFont.familyName isEqualToString:[NSFont menuFontOfSize:0].familyName] &&
              ([[NSFontManager sharedFontManager] traitsOfFont:boldTitleFont] & NSBoldFontMask));
        Check(@"Substitutions follows Spelling and Grammar",
              afterSpelling.submenu && [afterSpelling.submenu indexOfItemWithTarget:nil andAction:@selector(toggleAutomaticQuoteSubstitution:)] != -1);
        [appearancePrefs setColorScheme:2 sender:nil];
        Check(@"low contrast colors apply to editor and note list", [editor.backgroundColor isEqual:[appearancePrefs backgroundTextColor]] && [noteTable.backgroundColor isEqual:editor.backgroundColor]);
        [appearancePrefs setAlternatingRows:YES sender:nil];
        [appearancePrefs setShowNoteListGrid:NO sender:nil];
        Check(@"note row appearance options take effect", noteTable.usesAlternatingRowBackgroundColors && noteTable.gridStyleMask == NSTableViewGridNone);
        NSMenu *sortMenu = [noteTable menuForColumnSorting];
        BOOL directionShown = NO;
        for (NSMenuItem *item in sortMenu.itemArray)
            if (item.state == NSControlStateValueOn) directionShown = [item.title hasSuffix:@"↓"] || [item.title hasSuffix:@"↑"];
        Check(@"sort menu exposes current direction", directionShown);
        [appearancePrefs setUseThemedScrollbars:YES sender:nil];
        Check(@"themed overlay scrollbars apply to list and editor", [noteTable.enclosingScrollView.verticalScroller isKindOfClass:[NVOverlayScroller class]] && [editor.enclosingScrollView.verticalScroller isKindOfClass:[NVOverlayScroller class]] && editor.enclosingScrollView.scrollerStyle == NSScrollerStyleOverlay);
        Check(@"scrollbars retain native interaction and elasticity", editor.enclosingScrollView.verticalScroller.controlSize == NSControlSizeRegular && editor.enclosingScrollView.verticalScrollElasticity == NSScrollElasticityAllowed && editor.enclosingScrollView.verticalScroller.target == editor.enclosingScrollView);
        [appearancePrefs setUseThemedScrollbars:NO sender:nil];
        Check(@"turning off themed scrollbars restores system style", [editor.enclosingScrollView.verticalScroller class] == [NSScroller class] && editor.enclosingScrollView.scrollerStyle == [NSScroller preferredScrollerStyle]);
        [appearancePrefs setColorScheme:3 sender:nil];
        [appearancePrefs setForegroundTextColor:[NSColor whiteColor] sender:nil];
        [appearancePrefs setBackgroundTextColor:[NSColor colorWithCalibratedWhite:0.12 alpha:1] sender:nil];
        Snapshot(window, @"custom-dark.png");
        Check(@"fixed dark custom colors use the dark appearance", [window.appearance.name isEqualToString:NSAppearanceNameDarkAqua]);
        NSBitmapImageRep *listBitmap = [noteTable bitmapImageRepForCachingDisplayInRect:noteTable.bounds];
        [noteTable cacheDisplayInRect:noteTable.bounds toBitmapImageRep:listBitmap];
        [[listBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[acceptanceRoot stringByAppendingPathComponent:@"note-list.png"] atomically:YES];
        [app renameNote:nil];
        NSTextView *inlineEditor = (id)noteTable.currentEditor;
        Check(@"native inline editor uses readable custom colors", inlineEditor && [inlineEditor.textColor isEqual:[appearancePrefs foregroundTextColor]] && [inlineEditor.backgroundColor isEqual:[appearancePrefs backgroundTextColor]]);
        [noteTable abortEditing];
        [app bringFocusToControlField:nil];
        WaitForActivation(window);
        NSDate *focusLimit = [NSDate dateWithTimeIntervalSinceNow:2];
        while (![[app valueForKey:@"field"] currentEditor] && focusLimit.timeIntervalSinceNow > 0) Pump(0.05);
        NSTextView *searchEditor = (id)[[app valueForKey:@"field"] currentEditor];
        Check(@"search editing resets native field editor styling", searchEditor && !searchEditor.drawsBackground && [searchEditor.insertionPointColor isEqual:[appearancePrefs foregroundTextColor]]);
        [appearancePrefs setForegroundTextColor:[NSColor textColor] sender:nil];
        [appearancePrefs setBackgroundTextColor:[NSColor textBackgroundColor] sender:nil];
        Check(@"dynamic custom colors follow the system appearance", window.appearance == nil);
        [appearancePrefs setColorScheme:0 sender:nil];
        NSColor *storedTextColor = editor.textStorage.length ? [editor.textStorage attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:NULL] : [NSColor textColor];
        Check(@"system colors give note text a dynamic color", [editor.typingAttributes[NSForegroundColorAttributeName] isEqual:[NSColor textColor]] && [storedTextColor isEqual:[NSColor textColor]]);
        [appearancePrefs setShowNoteListGrid:YES sender:nil];
        [window makeFirstResponder:editor];
        [window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]];
        Snapshot(window, @"light.png");
        [app searchForString:@"jjjj"];
        [searchField.currentEditor setSelectedRange:NSMakeRange(4, 0)];
        Pump(0.1);
        NSRect focusedTextFrame = [searchField convertRect:searchField.currentEditor.bounds fromView:searchField.currentEditor];
        Check(@"focusing search reserves room for both icons", NSMinX(focusedTextFrame) >= NSMaxX([searchField.cell snapbackButtonRectForBounds:searchField.bounds]) &&
              NSMaxX(focusedTextFrame) <= NSMinX([searchField.cell clearButtonRectForBounds:searchField.bounds]));
        SnapshotWindow(window, @"compact-window-light.png");
        [window makeFirstResponder:nil];
        SnapshotView(searchField, @"compact-field-unfocused.png");
        NSPoint searchPoint = [searchField convertPoint:NSMakePoint(NSMidX(searchField.bounds), NSMidY(searchField.bounds)) toView:nil];
        NSEvent *searchClick = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:searchPoint modifierFlags:0 timestamp:0
            windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSEvent *searchRelease = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:searchPoint modifierFlags:0 timestamp:0
            windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
        [NSApp postEvent:searchRelease atStart:YES];
        [searchField mouseDown:searchClick];
        NSRect clickedTextFrame = [searchField convertRect:searchField.currentEditor.bounds fromView:searchField.currentEditor];
        Check(@"clicking search text begins editing beside the icon", searchField.currentEditor && fabs(NSMinX(clickedTextFrame) - NSMinX(focusedTextFrame)) < 1);
        NSRect clearButton = [searchField.cell clearButtonRectForBounds:searchField.bounds];
        NSPoint clearPoint = [searchField convertPoint:NSMakePoint(NSMidX(clearButton), NSMidY(clearButton)) toView:nil];
        NSEvent *clearClick = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:clearPoint modifierFlags:0 timestamp:0
            windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        NSEvent *clearRelease = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:clearPoint modifierFlags:0 timestamp:0
            windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:0];
        [NSApp postEvent:clearRelease atStart:YES];
        [searchField mouseDown:clearClick];
        Check(@"clicking the aligned clear button clears search", searchField.stringValue.length == 0);
        [window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
        [app searchForString:@"jjjj"];
        [searchField.currentEditor setSelectedRange:NSMakeRange(4, 0)];
        Pump(0.2);
        SnapshotWindow(window, @"compact-window-dark.png");
        [app searchForString:@""];
        [app revealNote:note options:NVEditNoteToReveal];
        Snapshot(window, @"dark.png");
        Check(@"light and dark rendering", [[NSFileManager defaultManager] fileExistsAtPath:[acceptanceRoot stringByAppendingPathComponent:@"dark.png"]]);
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];
        WaitForActivation(window);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
            BeginFullScreenAcceptance(app, notation, window, editor);
        });
    } @catch (NSException *exception) {
        [checks addObject:@{@"check": @"runtime exception", @"passed": @NO, @"detail": exception.description}];
        FinishAcceptance(@"result.json");
    }
}

__attribute__((constructor)) static void ConfigureIsolatedLaunch(void) {
    @autoreleasepool {
        const char *root = getenv("NV_ISOLATED_ROOT");
        if (!root) return;
        NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
        if (![identifier hasPrefix:@"net.notational.velocity.development"])
            exit(78);
        acceptanceRoot = [[NSString stringWithUTF8String:root] copy];
        if (getenv("NV_AUTOMATED_ACCEPTANCE") && !getenv("NV_REOPEN_ACCEPTANCE") &&
            [[[NSWorkspace sharedWorkspace].frontmostApplication bundleIdentifier] isEqualToString:@"com.apple.loginwindow"]) {
            NSDictionary *result = @{@"checks": @[], @"externalPrerequisite": @"An unlocked desktop is required for UI acceptance."};
            [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL]
                writeToFile:[acceptanceRoot stringByAppendingPathComponent:@"result.json"] atomically:YES];
            exit(75);
        }
        NSString *directory = [acceptanceRoot stringByAppendingPathComponent:@"notes"];
        NVFileReference reference;
        if (NVPathMakeReference((const UInt8 *)directory.fileSystemRepresentation, &reference, NULL) != noErr)
            exit(78);
        NSData *alias = [NSData aliasDataForFSRef:&reference];
        if (!alias) exit(78);
        [[NSUserDefaults standardUserDefaults] setVolatileDomain:@{@"DirectoryAlias": alias,
            @"TriedToImportBlor": @YES, @"SUEnableAutomaticChecks": @YES,
            @"SUAutomaticallyUpdate": @YES, @"ShouldHideSecureTextEntryWarning": @YES}
            forName:NSArgumentDomain];
        [NSURLProtocol registerClass:[NVRequestRecorder class]];
        if (getenv("NV_AUTOMATED_ACCEPTANCE")) {
            [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *notification) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    [[NSRunLoop mainRunLoop] performBlock:^{
                        if (getenv("NV_REOPEN_ACCEPTANCE")) RunReopenAcceptance();
                        else RunAcceptance();
                    }];
                });
            }];
        }
    }
}
