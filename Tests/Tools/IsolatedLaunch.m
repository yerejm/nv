#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import "NVFileReference.h"
#import "NVArchive.h"
#import "NSData_transformations.h"
#import "AppController.h"
#import "AppController_Importing.h"
#import "NotationPrefs.h"
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
#import "PTHotKeyCenter.h"
#import "PTHotKey.h"
#import "PTKeyCombo.h"
#import "DualField.h"
#import "AugmentedScrollView.h"
#import "RBSplitView/RBSplitView.h"
#import "TemporaryFileCachePreparer.h"
#import "AcceptanceEditorSession.h"
#include <sys/mount.h>
#include <dlfcn.h>
#include <objc/runtime.h>

@interface AppController (ServiceAcceptance)
- (void)createFromSelection:(NSPasteboard *)pasteboard userData:(NSString *)userData error:(NSString **)error;
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

static void Pump(NSTimeInterval seconds) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([limit timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static void SnapshotView(NSView *view, NSString *name) {
    [view.window displayIfNeeded];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view.effectiveAppearance performAsCurrentDrawingAppearance:^{
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    }];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[acceptanceRoot stringByAppendingPathComponent:name] atomically:YES];
}

static void Snapshot(NSWindow *window, NSString *name) {
    SnapshotView(window.contentView, name);
}

static void SnapshotWindow(NSWindow *window, NSString *name) {
    dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit", RTLD_LAZY);
    __block BOOL finished = NO;
    [(id)NSClassFromString(@"SCShareableContent") getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SCWindow *ownWindow = nil;
            for (SCWindow *candidate in content.windows)
                if (candidate.windowID == window.windowNumber) ownWindow = candidate;
            if (!ownWindow) { finished = YES; return; }
            SCContentFilter *filter = [[NSClassFromString(@"SCContentFilter") alloc] initWithDesktopIndependentWindow:ownWindow];
            SCStreamConfiguration *configuration = [[NSClassFromString(@"SCStreamConfiguration") alloc] init];
            configuration.width = NSWidth(window.frame) * window.backingScaleFactor;
            configuration.height = NSHeight(window.frame) * window.backingScaleFactor;
            configuration.ignoreShadowsSingleWindow = YES;
            configuration.showsCursor = NO;
            [(id)NSClassFromString(@"SCScreenshotManager") captureImageWithFilter:filter configuration:configuration completionHandler:^(CGImageRef image, NSError *captureError) {
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
    Check(@"isolated window screenshot", [[NSFileManager defaultManager] fileExistsAtPath:[acceptanceRoot stringByAppendingPathComponent:name]]);
}

static void FinishAcceptance(NSString *filename) {
    NSDictionary *result = @{@"system": NSProcessInfo.processInfo.operatingSystemVersionString, @"dataRoot": acceptanceRoot,
                             @"checks": checks, @"urlRequests": @(requestCount)};
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

static void CompleteDesktopAcceptance(AppController *app, NotationController *notation, NSWindow *window, LinkingEditor *editor) {
    @try {
        [NSApp hide:nil];
        [app bringFocusToControlField:nil];
        Pump(0.2);
        Check(@"activation restores search focus", window.visible && window.firstResponder != editor);
        PTHotKeyCenter *center = [NSClassFromString(@"PTHotKeyCenter") sharedCenter];
        PTHotKey *hotkey = [[[NSClassFromString(@"PTHotKey") alloc] init] autorelease];
        hotkey.name = @"NV isolated acceptance";
        hotkey.keyCombo = [NSClassFromString(@"PTKeyCombo") keyComboWithKeyCode:90 modifiers:cmdKey | optionKey | controlKey];
        hotkey.target = [[[NVHotkeyRecorder alloc] init] autorelease];
        hotkey.action = @selector(fired:);
        BOOL registered = [center registerHotKey:hotkey];
        NSNumber *keyID = [[[center valueForKey:@"mHotKeyMap"] allKeysForObject:hotkey] firstObject];
        EventHotKeyID identity = { 'PTHk', keyID.unsignedIntValue };
        EventRef event = NULL;
        OSStatus eventStatus = CreateEvent(NULL, kEventClassKeyboard, kEventHotKeyPressed, 0, 0, &event);
        if (eventStatus == noErr && keyID) {
            SetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, sizeof(identity), &identity);
            eventStatus = SendEventToEventTarget(event, GetEventDispatcherTarget());
        }
        if (event) ReleaseEvent(event);
        Check(@"hotkey registration and Carbon event dispatch", registered && eventStatus == noErr && hotkeyCount == 1);
        [center unregisterHotKey:hotkey];
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
        [preferences switchViews:[[preferences valueForKey:@"items"] objectForKey:@"Display"]];
        Check(@"Display preferences exposes width controls", [[preferences valueForKey:@"window"] contentView] == [preferences valueForKey:@"displayView"] && [[preferences valueForKey:@"textWidthSlider"] isEnabled]);
        [preferences switchViews:[[preferences valueForKey:@"items"] objectForKey:@"Desktop"]];
        Check(@"Desktop preferences exposes Dock and menu bar controls", [[preferences valueForKey:@"window"] contentView] == [preferences valueForKey:@"desktopView"] && [preferences valueForKey:@"showDockIconButton"] && [preferences valueForKey:@"showMenuBarIconButton"]);
        Check(@"no app-owned URL requests with old preferences", requestCount == 0);
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
        Pump(0.2);
        Check(@"real app launch on macOS 26", app && window.visible && notes.count > 0);
        Check(@"retired sync-enabled archive stays inert", [[notation notationPrefs].syncServiceAccounts[@"Simplenote"][@"enabled"] boolValue] && !NSClassFromString(@"SimplenoteSession") && !NSClassFromString(@"SUUpdater"));
        NoteObject *note = notes.firstObject;
        [app searchForString:@"Retained legacy"];
        Check(@"search content", [[notation notesListDataSource] count] == 1);
        [app revealNote:note options:NVEditNoteToReveal | NVOrderFrontWindow];
        Check(@"editor focus", window.firstResponder == editor);
        RBSplitView *split = [app valueForKey:@"splitView"];
        RBSplitSubview *listPane = [split subviewAtPosition:0];
        BOOL originalLayout = [[GlobalPrefs defaultPrefs] horizontalLayout];
        [app toggleCollapse:nil];
        Check(@"notes list and search collapse together", listPane.isCollapsed && !window.toolbar.visible && window.firstResponder == editor);
        NSTextField *windowTitle = [app valueForKey:@"windowTitleLabel"];
        Check(@"collapsed search preserves the selected note title", [windowTitle.stringValue isEqualToString:window.title] && [window.title isEqualToString:titleOfNote(note)]);
        [app switchViewLayout:nil];
        Check(@"collapsed notes list survives orientation change", listPane.isCollapsed && !window.toolbar.visible);
        [app toggleCollapse:nil];
        Check(@"notes list and search expand together", !listPane.isCollapsed && window.toolbar.visible);
        Check(@"widescreen divider is visible and draggable", split.divider != nil && split.dividerThickness >= 5);
        [app toggleCollapse:nil];
        [app switchViewLayout:nil];
        Check(@"collapsed notes list survives return to original orientation", listPane.isCollapsed && [[GlobalPrefs defaultPrefs] horizontalLayout] == originalLayout);
        [app toggleCollapse:nil];
        NSRect paneFrame = listPane.frame;
        NSPoint dividerPoint = split.isVertical ? NSMakePoint(NSMaxX(paneFrame) + 2, NSMidY(paneFrame)) : NSMakePoint(NSMidX(paneFrame), NSMaxY(paneFrame) + 2);
        NSEvent *doubleClick = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:[split convertPoint:dividerPoint toView:nil]
            modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:2 pressure:1];
        [split mouseDown:doubleClick];
        Check(@"divider double-click collapses notes list", listPane.isCollapsed && !window.toolbar.visible);
        GlobalPrefs *displayPrefs = [GlobalPrefs defaultPrefs];
        NSString *beforeWidthChange = [[editor.string copy] autorelease];
        [displayPrefs setMaxNoteBodyWidth:320 sender:nil];
        [displayPrefs setManagesTextWidthInWindow:YES sender:nil];
        Check(@"editor text width is capped with centered margins", editor.textContainerInset.width >= 8 && editor.textContainer.size.width <= 330);
        Check(@"text width changes preserve note contents", [editor.string isEqualToString:beforeWidthChange]);
        [displayPrefs setManagesTextWidthInWindow:NO sender:nil];
        Check(@"disabling width limit restores editor margins", editor.textContainerInset.width == 3);
        [displayPrefs setMaxNoteBodyWidth:660 sender:nil];
        [app toggleCollapse:nil];
        [displayPrefs setShowMenuBarIcon:YES sender:nil];
        NSStatusItem *menuBarItem = [app valueForKey:@"statusItem"];
        Check(@"menu bar icon exposes a native click action", menuBarItem.button.image && menuBarItem.button.target == app && menuBarItem.button.action == @selector(statusItemAction:));
        [NSApp activateIgnoringOtherApps:YES];
        [window makeKeyAndOrderFront:nil];
        Pump(0.2);
        Check(@"menu bar button keeps its target", menuBarItem.button.target == app && menuBarItem.button.action == @selector(statusItemAction:));
        Check(@"menu bar action is delivered", [NSApp sendAction:@selector(statusItemAction:) to:app from:menuBarItem.button]);
        NSDate *hideLimit = [NSDate dateWithTimeIntervalSinceNow:2];
        while (window.visible && hideLimit.timeIntervalSinceNow > 0) Pump(0.05);
        Check(@"menu bar action hides the note window", !window.visible);
        Check(@"menu bar button keeps its target", menuBarItem.button.target == app && menuBarItem.button.action == @selector(statusItemAction:));
        Check(@"menu bar action is delivered", [NSApp sendAction:@selector(statusItemAction:) to:app from:menuBarItem.button]);
        NSDate *showLimit = [NSDate dateWithTimeIntervalSinceNow:2];
        while ((!NSApp.isActive || !window.isKeyWindow) && showLimit.timeIntervalSinceNow > 0) Pump(0.05);
        Pump(0.1);
        Check(@"menu bar action restores the note window and search focus", NSApp.isActive && window.isKeyWindow && window.firstResponder == [[app valueForKey:@"field"] currentEditor]);
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
        NSTokenField *tagField = [app valueForKey:@"multiTagField"];
        Check(@"multiple notes expose a shared-tag editor", window.attachedSheet && tagField && [[tagField objectValue] count] == 1);
        [tagField setObjectValue:@[@"new-tag"]];
        [NSApp endSheet:window.attachedSheet returnCode:NSAlertFirstButtonReturn];
        Pump(0.2);
        Check(@"shared-tag changes preserve unique tags", [labelsOfNote(firstTagged) containsString:@"unique-one"] && [labelsOfNote(secondTagged) containsString:@"unique-two"] && [labelsOfNote(firstTagged) containsString:@"new-tag"] && ![labelsOfNote(secondTagged).lowercaseString containsString:@"shared"]);
        [firstTagged setLabelString:@""];
        [secondTagged setLabelString:@""];
        [app revealNote:note options:NVEditNoteToReveal];
        NSMenuItem *findCommand = FindMenuCommand(NSApp.mainMenu);
        Check(@"Find menu targets the note editor from search focus", findCommand && findCommand.target == editor);
        [app searchForString:@"Retained"];
        [[app valueForKey:@"notesTableView"] deselectAll:nil];
        [NSApp sendAction:findCommand.action to:findCommand.target from:findCommand];
        Pump(0.3);
        Check(@"Find opens and selects a note when nothing is selected", [app selectedNoteObject] && editor.enclosingScrollView.isFindBarVisible);
        Check(@"Find starts with the global search text", [[[NSPasteboard pasteboardWithName:NSPasteboardNameFind] stringForType:NSPasteboardTypeString] isEqualToString:@"Retained"]);
        [app searchForString:@""];
        [app revealNote:note options:NVEditNoteToReveal];
        NSPasteboard *clipboard = [NSPasteboard generalPasteboard];
        NSMutableDictionary *savedClipboard = [NSMutableDictionary dictionary];
        for (NSString *type in clipboard.types) {
            NSData *data = [clipboard dataForType:type];
            if (data) savedClipboard[type] = data;
        }
        [clipboard declareTypes:@[NSPasteboardTypeString] owner:nil];
        [clipboard setString:@"Retained" forType:NSPasteboardTypeString];
        [NSApp sendAction:findCommand.action to:findCommand.target from:findCommand];
        Check(@"Find uses clipboard text when global search is empty", [[[NSPasteboard pasteboardWithName:NSPasteboardNameFind] stringForType:NSPasteboardTypeString] isEqualToString:@"Retained"]);
        [clipboard declareTypes:savedClipboard.allKeys owner:nil];
        for (NSString *type in savedClipboard) [clipboard setData:savedClipboard[type] forType:type];
        NSView *findBar = editor.enclosingScrollView.findBarView;
        [app revealNote:secondTagged options:NVEditNoteToReveal];
        Pump(0.3);
        Check(@"Find bar survives switching notes", editor.enclosingScrollView.isFindBarVisible && editor.enclosingScrollView.findBarView == findBar);
        NSMenuItem *nextMatch = [[[NSMenuItem alloc] initWithTitle:@"Next" action:@selector(performFindPanelAction:) keyEquivalent:@""] autorelease];
        nextMatch.tag = NSTextFinderActionNextMatch;
        [app revealNote:note options:NVEditNoteToReveal];
        [editor setSelectedRange:NSMakeRange(0, 0)];
        [editor performFindPanelAction:nextMatch];
        Pump(0.2);
        Check(@"Find searches the newly displayed note", editor.selectedRange.length && [[editor.string substringWithRange:editor.selectedRange] localizedCaseInsensitiveContainsString:@"Retained"]);
        [editor clearFindPanel];
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
        NSBitmapImageRep *listBitmap = [noteTable bitmapImageRepForCachingDisplayInRect:noteTable.bounds];
        [noteTable cacheDisplayInRect:noteTable.bounds toBitmapImageRep:listBitmap];
        [[listBitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[acceptanceRoot stringByAppendingPathComponent:@"note-list.png"] atomically:YES];
        [app renameNote:nil];
        NSTextView *inlineEditor = (id)noteTable.currentEditor;
        Check(@"native inline editor uses readable custom colors", inlineEditor && [inlineEditor.textColor isEqual:[appearancePrefs foregroundTextColor]] && [inlineEditor.backgroundColor isEqual:[appearancePrefs backgroundTextColor]]);
        [noteTable abortEditing];
        [app bringFocusToControlField:nil];
        NSDate *focusLimit = [NSDate dateWithTimeIntervalSinceNow:2];
        while (![[app valueForKey:@"field"] currentEditor] && focusLimit.timeIntervalSinceNow > 0) Pump(0.05);
        NSTextView *searchEditor = (id)[[app valueForKey:@"field"] currentEditor];
        Check(@"search editing resets native field editor styling", searchEditor && !searchEditor.drawsBackground && [searchEditor.insertionPointColor isEqual:[appearancePrefs foregroundTextColor]]);
        [appearancePrefs setForegroundTextColor:[NSColor textColor] sender:nil];
        [appearancePrefs setBackgroundTextColor:[NSColor textBackgroundColor] sender:nil];
        [appearancePrefs setColorScheme:0 sender:nil];
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
