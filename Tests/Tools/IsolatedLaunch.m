#import <Cocoa/Cocoa.h>
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

static void Check(NSString *name, BOOL passed) {
    [checks addObject:@{@"check": name, @"passed": @(passed)}];
    NSLog(@"NV acceptance: %@ %@", passed ? @"PASS" : @"FAIL", name);
}

static void Pump(NSTimeInterval seconds) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([limit timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static void Snapshot(NSWindow *window, NSString *name) {
    [window displayIfNeeded];
    NSView *view = [window contentView];
    NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[acceptanceRoot stringByAppendingPathComponent:name] atomically:YES];
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
        NSString *original = [[editor.string copy] autorelease];
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
        [notation.notationPrefs setNotesStorageFormat:PlainTextFormat];
        Check(@"individual file persistence", [notation flushAllNoteChanges] && [[NSFileManager defaultManager] fileExistsAtPath:note.noteFilePath]);
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
        NSTextView *searchEditor = (id)[[app valueForKey:@"field"] currentEditor];
        Check(@"search editing resets native field editor styling", searchEditor && !searchEditor.drawsBackground && [searchEditor.insertionPointColor isEqual:[appearancePrefs foregroundTextColor]]);
        [appearancePrefs setForegroundTextColor:[NSColor textColor] sender:nil];
        [appearancePrefs setBackgroundTextColor:[NSColor textBackgroundColor] sender:nil];
        [appearancePrefs setColorScheme:0 sender:nil];
        [appearancePrefs setShowNoteListGrid:YES sender:nil];
        [window makeFirstResponder:editor];
        [window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]];
        Snapshot(window, @"light.png");
        [window setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
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
