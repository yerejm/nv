/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


#import "AppController.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "AlienNoteImporter.h"
#import "AppController_Importing.h"
#import "NotationPrefs.h"
#import "PrefsWindowController.h"
#import "NoteAttributeColumn.h"
#import "NotationDirectoryManager.h"
#import "NotationFileManager.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"
#import "EncodingsManager.h"
#import "ExporterManager.h"
#import "ExternalEditorListController.h"
#import "NSData_transformations.h"
#import "BufferUtils.h"
#import "LinkingEditor.h"
#import "EmptyView.h"
#import "DualField.h"
#import "AugmentedScrollView.h"
#import "BookmarksController.h"
#import "MultiplePageView.h"
#import "InvocationRecorder.h"
#import "SecureTextEntryManager.h"
#import "LabelsListController.h"
#import "NSString_CustomTruncation.h"

@interface NVWindowTitleLabel : NSTextField
@end

@implementation NVWindowTitleLabel
- (BOOL)mouseDownCanMoveWindow { return YES; }
@end

//the nib archives Lucida Grande in the styled Format menu titles, so each keeps its style in the menu font
static void NVUseMenuFontForStyledTitles(NSMenu *menu) {
    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    for (NSMenuItem *item in menu.itemArray) {
        if (item.submenu) NVUseMenuFontForStyledTitles(item.submenu);
        if (!item.attributedTitle.length) continue;
        NSMutableAttributedString *title = [item.attributedTitle mutableCopy];
        [title removeAttribute:@"NSOriginalFont" range:NSMakeRange(0, title.length)];
        [item.attributedTitle enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, title.length) options:0 usingBlock:^(NSFont *font, NSRange range, BOOL *stop) {
            NSFontTraitMask traits = font ? [fontManager traitsOfFont:font] & (NSBoldFontMask | NSItalicFontMask) : 0;
            [title addAttribute:NSFontAttributeName value:[fontManager convertFont:[NSFont menuFontOfSize:0] toHaveTrait:traits] range:range];
        }];
        item.attributedTitle = title;
    }
}

@implementation AppController

//an instance of this class is designated in the nib as the delegate of the window, nstextfield and two nstextviews

static NSString *NVFullScreenSwitchedLayoutKey = @"FullScreenSwitchedLayout";

- (instancetype)init {
    if ((self = [super init])) {
		
		windowUndoManager = [[NSUndoManager alloc] init];
		
		isCreatingANote = isFilteringFromTyping = typedStringIsCached = NO;
		typedString = @"";
		
    }
    return self;
}

- (void)awakeFromNib {
    [textView configureFindMenu:NSApp.mainMenu];
    NVUseMenuFontForStyledTitles(NSApp.mainMenu);
	prefsController = [GlobalPrefs defaultPrefs];
	

	
	NSView *dualSV = [field superview];
	dualFieldItem = [[NSToolbarItem alloc] initWithItemIdentifier:@"DualField"];
	[dualFieldItem setView:dualSV];
	[dualSV setTranslatesAutoresizingMaskIntoConstraints:NO];
    [field setTranslatesAutoresizingMaskIntoConstraints:NO];
    [NSLayoutConstraint activateConstraints:@[
        [dualSV.widthAnchor constraintGreaterThanOrEqualToConstant:50],
        [dualSV.heightAnchor constraintEqualToConstant:23],
        [field.leadingAnchor constraintEqualToAnchor:dualSV.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:dualSV.trailingAnchor],
        [field.topAnchor constraintEqualToAnchor:dualSV.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:dualSV.bottomAnchor]]];

    [dualFieldItem setLabel:NSLocalizedString(@"Search or Create", @"placeholder text in search/create field")];
	
	toolbar = [[NSToolbar alloc] initWithIdentifier:@"NVToolbar"];
	[toolbar setAllowsUserCustomization:NO];
	[toolbar setAutosavesConfiguration:NO];
	[toolbar setDisplayMode:NSToolbarDisplayModeIconOnly];

	[toolbar setVisible:![[NSUserDefaults standardUserDefaults] boolForKey:@"ToolbarHidden"]];
	[toolbar setDelegate:self];
    [window setToolbarStyle:NSWindowToolbarStyleExpanded];
	[window setToolbar:toolbar];
    windowTitleLabel = [NVWindowTitleLabel labelWithString:window.title];
    windowTitleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    windowTitleLabel.alignment = NSTextAlignmentCenter;
    windowTitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSView *titleView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(window.frame) - 84, 32)];
    [titleView addSubview:windowTitleLabel];
    NSTitlebarAccessoryViewController *titleAccessory = [[NSTitlebarAccessoryViewController alloc] init];
    titleAccessory.view = titleView;
    titleAccessory.layoutAttribute = NSLayoutAttributeRight;
    window.titleVisibility = NSWindowTitleHidden;
    [window addTitlebarAccessoryViewController:titleAccessory];

	[NSApp setDelegate:self];
	[notesTableView setDelegate:self];
	[window setDelegate:self];
    [self _updateWindowTitleLayout];
	[field setDelegate:self];
	[textView setDelegate:self];
    modifierMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent *(NSEvent *event) {
        if (event.window == self->window) [self flagsChanged:event];
        return event;
    }];
	[splitView setDelegate:self];
	
	//set up temporary FastListDataSource containing false visible notes
		
	//this will not make a difference

	

	
	outletObjectAwoke(self);
}

//really need make AppController a subclass of NSWindowController and stick this junk in windowDidLoad
- (void)setupViewsAfterAppAwakened {
	static BOOL awakenedViews = NO;
	if (!awakenedViews) {
		if ([[NSUserDefaults standardUserDefaults] boolForKey:NVFullScreenSwitchedLayoutKey]) {
			//the app last quit while full screen was showing its own layout instead of the user's
			[prefsController setHorizontalLayout:NO sender:self];
			[[NSUserDefaults standardUserDefaults] removeObjectForKey:NVFullScreenSwitchedLayoutKey];
		}
		[self _restoreNotesListLayout];
		
		[splitSubview addSubview:editorStatusView positioned:NSWindowAbove relativeTo:splitSubview];
		[editorStatusView setFrame:[[textView enclosingScrollView] frame]];
        NSScrollView *editorScroll = [textView enclosingScrollView];
        wordCountLabel = [NSTextField labelWithString:@""];
        [wordCountLabel setFont:[NSFont systemFontOfSize:11]];
        [wordCountLabel setAlignment:NSTextAlignmentRight];
        [wordCountLabel setDrawsBackground:YES];
        [wordCountLabel setTranslatesAutoresizingMaskIntoConstraints:NO];
        [wordCountLabel setHidden:YES];
        [editorScroll addSubview:wordCountLabel];
        [NSLayoutConstraint activateConstraints:@[
            [wordCountLabel.trailingAnchor constraintEqualToAnchor:editorScroll.trailingAnchor constant:-24],
            [wordCountLabel.bottomAnchor constraintEqualToAnchor:editorScroll.bottomAnchor constant:-4],
            [wordCountLabel.widthAnchor constraintEqualToConstant:170],
            [wordCountLabel.heightAnchor constraintEqualToConstant:18]]];
		
		[notesTableView restoreColumns];
		
		[field setNextKeyView:textView];
		[textView setNextKeyView:field];
		[window setAutorecalculatesKeyViewLoop:NO];
		
		[self setEmptyViewState:YES];
		
		awakenedViews = YES;
	}
}

//what a hack
void outletObjectAwoke(id sender) {
	static NSMutableSet *awokenOutlets = nil;
	if (!awokenOutlets) awokenOutlets = [[NSMutableSet alloc] initWithCapacity:5];
	
	[awokenOutlets addObject:sender];
	
	AppController* appDelegate = (AppController*)[NSApp delegate];
	
	if (appDelegate && [awokenOutlets containsObject:appDelegate] &&
		[awokenOutlets containsObject:appDelegate->notesTableView] &&
		[awokenOutlets containsObject:appDelegate->textView] &&
		[awokenOutlets containsObject:appDelegate->editorStatusView] &&
		[awokenOutlets containsObject:appDelegate->splitView]) {
		
		[appDelegate setupViewsAfterAppAwakened];
	}
}

static void *NVEffectiveAppearanceContext = &NVEffectiveAppearanceContext;

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != NVEffectiveAppearanceContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    //colors derived from dynamic system colors are resolved once, so they must be rebuilt for the new appearance
    [prefsController resetAppearanceDependentAttributes];
    [self updateInterfaceAppearance];
}

- (void)runDelayedUIActionsAfterLaunch {
    [self updateDesktopPresence];
    [self updateInterfaceAppearance];
    [NSApp addObserver:self forKeyPath:@"effectiveAppearance" options:0 context:NVEffectiveAppearanceContext];
	[[prefsController bookmarksController] setAppController:self];
	[[prefsController bookmarksController] restoreWindowFromSave];
	[[prefsController bookmarksController] updateBookmarksUI];
	[self updateNoteMenus];
	[textView setupFontMenu];
	[prefsController registerAppActivationKeystrokeWithTarget:self selector:@selector(toggleNVActivation:)];
	[notationController updateLabelConnectionsAfterDecoding];
	[notationController checkIfNotationIsTrashed];
	[[SecureTextEntryManager sharedInstance] checkForIncompatibleApps];
	
	[NSApp setServicesProvider:self];
}

//mounting can block until an unreachable server times out, so it runs in the background behind a cancellable panel;
//a mount that finishes after cancelling or timing out is ignored
- (void)_mountVolumeForAliasData:(NSData *)aliasData {
	NSString *location = [[[NSFileManager defaultManager] pathCopiedFromAliasData:aliasData] stringByAbbreviatingWithTildeInPath];
	NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 96) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	NSProgressIndicator *spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 54, 16, 16)];
	[spinner setStyle:NSProgressIndicatorStyleSpinning];
	[spinner setControlSize:NSControlSizeSmall];
	[spinner startAnimation:nil];
	NSTextField *label = [NSTextField labelWithString:location ? [NSString stringWithFormat:NSLocalizedString(@"Connecting to %@…", @"shown while mounting the notes folder's volume"), location] :
						  NSLocalizedString(@"Connecting to the notes folder…", nil)];
	[label setFrame:NSMakeRect(46, 52, 334, 20)];
	[label setLineBreakMode:NSLineBreakByTruncatingMiddle];
	NSButton *cancel = [NSButton buttonWithTitle:NSLocalizedString(@"Cancel", nil) target:self action:@selector(_cancelVolumeMount:)];
	[cancel setKeyEquivalent:@"\e"];
	[cancel setFrame:NSMakeRect(300, 12, 86, 32)];
	[[panel contentView] addSubview:spinner];
	[[panel contentView] addSubview:label];
	[[panel contentView] addSubview:cancel];
	[panel center];

	__block BOOL waiting = YES;
	NSData *bookmark = [aliasData copy];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NVFileReference ref;
		[bookmark fsRefAsAliasMountingVolume:&ref];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (waiting) [self _stopVolumeMountPanel];
		});
	});
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
		if (waiting) [self _stopVolumeMountPanel];
	});
	[NSApp runModalForWindow:panel];
	waiting = NO;
	[panel orderOut:nil];
}

- (void)_stopVolumeMountPanel {
	[NSApp stopModal];
	//stopModal only ends the modal loop once it receives another event
	[NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0
									windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:YES];
}

- (void)_cancelVolumeMount:(id)sender {
	[NSApp stopModal];
}

- (void)applicationDidFinishLaunching:(NSNotification*)aNote {
	
    NSDate *before = [NSDate date];
	prefsWindowController = [[PrefsWindowController alloc] init];
	
	OSStatus err = noErr;
	NotationController *newNotation = nil;
	NSData *aliasData = [prefsController aliasDataForDefaultDirectory];
	
	NSString *subMessage = @"";
	NSString *location = nil, *reason = nil;
	
	//if the option key is depressed, go straight to picking a new notes folder location
	if (kCGEventFlagMaskAlternate == (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & (CGEventFlags)NSEventModifierFlagDeviceIndependentFlagsMask)) {
		goto showOpenPanel;
	}
	
	if (aliasData) {
		NVFileReference mountedRef;
		if (![aliasData fsRefAsAlias:&mountedRef]) [self _mountVolumeForAliasData:aliasData];
	    newNotation = [[NotationController alloc] initWithAliasData:aliasData error:&err];
	    subMessage = NSLocalizedString(@"Please choose a different folder in which to store your notes.",nil);
	} else {
	    newNotation = [[NotationController alloc] initWithDefaultDirectoryReturningError:&err];
	    subMessage = NSLocalizedString(@"Please choose a folder in which your notes will be stored.",nil);
	}
	//no need to display an alert if the error wasn't real
	if (err == kPassCanceledErr)
		goto showOpenPanel;
	
	location = (aliasData ? [[NSFileManager defaultManager] pathCopiedFromAliasData:aliasData] : NSLocalizedString(@"your Application Support directory",nil));
	if (!location) { //fscopyaliasinfo sucks
		NVFileReference locationRef;
		if ([aliasData fsRefAsAlias:&locationRef] && (location = [[NSFileManager defaultManager] displayNameAtPath:[[NSFileManager defaultManager] pathWithFSRef:&locationRef]]) != nil) {

		} else {
			location = NSLocalizedString(@"its current location",nil);
		}
	}
	
	while (!newNotation) {
	    location = [location stringByAbbreviatingWithTildeInPath];
	    reason = [NSString reasonStringFromCarbonFSError:err];
		
	    if (NVRunAlert(NSAlertStyleWarning, [NSString stringWithFormat:NSLocalizedString(@"Unable to initialize notes database in \n%@ because %@.",nil), location, reason], subMessage, NSLocalizedString(@"Choose another folder",nil), NSLocalizedString(@"Quit",nil), NULL) == NSAlertFirstButtonReturn) {
			//show nsopenpanel, defaulting to current default notes dir
			NVFileReference notesDirectoryRef;
		showOpenPanel:
			if (![prefsWindowController getNewNotesRefFromOpenPanel:&notesDirectoryRef returnedPath:&location]) {
				//they cancelled the open panel, or it was unable to get the path/NVFileReference of the file
				goto terminateApp;
			} else if ((newNotation = [[NotationController alloc] initWithDirectoryRef:&notesDirectoryRef error:&err])) {
				//have to make sure alias data is saved from setNotationController
				[newNotation setAliasNeedsUpdating:YES];
				break;
			}
	    } else {
			goto terminateApp;
	    }
	}
	
	[self setNotationController:newNotation];
	
	NSLog(@"load time: %g, ",[[NSDate date] timeIntervalSinceDate:before]);
	
	//import old database(s) here if necessary
	[AlienNoteImporter importBlorOrHelpFilesIfNecessaryIntoNotation:newNotation];
	
	if (pathsToOpenOnLaunch) {
		[notationController openFiles:pathsToOpenOnLaunch];
		pathsToOpenOnLaunch = nil;
	}
	
	if (URLToInterpretOnLaunch) {
		[self interpretNVURL:URLToInterpretOnLaunch];
		URLToInterpretOnLaunch = nil;
	}
	
	//tell us..
	[prefsController registerWithTarget:self forChangesInSettings:
	 @selector(setAliasDataForDefaultDirectory:sender:),  //when someone wants to load a new database
	 @selector(setSortedTableColumnKey:reversed:sender:),  //when sorting prefs changed
	 @selector(setNoteBodyFont:sender:),  //when to tell notationcontroller to restyle its notes
	 @selector(setForegroundTextColor:sender:),  //ditto
     @selector(setBackgroundTextColor:sender:),
     @selector(setShowWordCount:sender:),
     @selector(setShowDockIcon:sender:), @selector(setShowMenuBarIcon:sender:),
	 @selector(setTableFontSize:sender:),  //when to tell notationcontroller to regenerate the (now potentially too-short) note-body previews
	 @selector(addTableColumn:sender:),  //ditto
	 @selector(removeTableColumn:sender:),  //ditto
	 @selector(setTableColumnsShowPreview:sender:),  //when to tell notationcontroller to generate or disable note-body previews
	 @selector(setConfirmNoteDeletion:sender:),  //whether "delete note" should have an ellipsis
	 @selector(setAutoCompleteSearches:sender:), nil];   //when to tell notationcontroller to build its title-prefix connections
	
	[self performSelector:@selector(runDelayedUIActionsAfterLaunch) withObject:nil afterDelay:0.0];
			
	return;
terminateApp:
	[NSApp terminate:self];
}

- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
	NSMutableArray *paths = [NSMutableArray array];
	for (NSURL *url in urls) {
		if ([url isFileURL]) {
			[paths addObject:[url path]];
		} else if ([[url scheme] caseInsensitiveCompare:@"nv"] == NSOrderedSame) {
			if (notationController) {
				if (![self interpretNVURL:url])
					NSBeep();
			} else {
				URLToInterpretOnLaunch = url;
			}
		} else {
			NSBeep();
		}
	}
	if (![paths count]) return;
	
	if (notationController) {
		[notationController openFiles:paths];
	} else {
		if (!pathsToOpenOnLaunch) pathsToOpenOnLaunch = [[NSMutableArray alloc] init];
		[pathsToOpenOnLaunch addObjectsFromArray:paths];
	}
}

- (void)setNotationController:(NotationController*)newNotation {
	
    if (newNotation) {
		if (notationController) {
			[notationController closeAllResources];
		}
		
		//the replaced notation stays alive until its successor is fully installed
		NotationController *oldNotation NS_VALID_UNTIL_END_OF_SCOPE = notationController;
		notationController = newNotation;
		
		if (oldNotation) {
			[notesTableView abortEditing];
			[prefsController setLastSearchString:[self fieldSearchString] selectedNote:currentNote 
						scrollOffsetForTableView:notesTableView sender:self];
			//if we already had a notation, appController should already be bookmarksController's delegate
			[[prefsController bookmarksController] performSelector:@selector(updateBookmarksUI) withObject:nil afterDelay:0.0];
		}
		[notationController setSortColumn:[notesTableView noteAttributeColumnForIdentifier:[prefsController sortedTableColumnKey]]];
		[notesTableView setDataSource:[notationController notesListDataSource]];
		[notesTableView setLabelsListSource:[notationController labelsListDataSource]];
		[notationController setDelegate:self];
		
		//allow resolution of UUIDs to NoteObjects from saved searches
		[[prefsController bookmarksController] setDataSource:notationController];
		
		//update the list using the new notation and saved settings
		[self restoreListStateUsingPreferences];
		
		//window's undomanager could be referencing actions from the old notation object
		[[window undoManager] removeAllActions];
		[notationController setUndoManager:[window undoManager]];
		
		if ([notationController aliasNeedsUpdating]) {
			[prefsController setAliasDataForDefaultDirectory:[notationController aliasDataForNoteDirectory] sender:self];
		}
		if ([prefsController tableColumnsShowPreview] || [prefsController horizontalLayout]) {
			[self _forceRegeneratePreviewsForTitleColumn];
			[notesTableView setNeedsDisplay:YES];
		}
		if ([[notationController notationPrefs] secureTextEntry]) {
			[[SecureTextEntryManager sharedInstance] enableSecureTextEntry];
		} else {
			[[SecureTextEntryManager sharedInstance] disableSecureTextEntry];
		}
		
		[field selectText:nil];
    }
}

- (BOOL)applicationOpenUntitledFile:(NSApplication *)sender {
    if (![prefsController quitWhenClosingWindow]) {
        [self bringFocusToControlField:nil];
        return YES;
    }
    
    return NO;
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
	return [itemIdentifier isEqualToString:@"DualField"] ? dualFieldItem : nil;
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar*)theToolbar {
	return [self toolbarDefaultItemIdentifiers:theToolbar];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)theToolbar {
	return @[@"DualField"];
}

- (void)_setWindowTitle:(NSString *)title {
    [window setTitle:title];
    [windowTitleLabel setStringValue:title];
}

- (void)_updateWindowTitleLayout {
    NSView *titleView = windowTitleLabel.superview;
    [titleView setFrameSize:NSMakeSize(MAX(0, NSWidth(window.frame) - 84), 32)];
    NSButton *closeButton = [window standardWindowButton:NSWindowCloseButton];
    NSRect buttonFrame = [titleView convertRect:closeButton.bounds fromView:closeButton];
    [windowTitleLabel setFrame:NSMakeRect(0, NSMidY(buttonFrame) - 9, MAX(0, NSWidth(window.frame) - 168), 18)];
}

- (void)windowDidResize:(NSNotification *)notification {
    [self _updateWindowTitleLayout];
}

- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
	SEL selector = [menuItem action];
    if (selector == @selector(toggleDockIcon:)) {
        [menuItem setState:[prefsController showDockIcon] ? NSControlStateValueOn : NSControlStateValueOff];
        return YES;
    }
	NSInteger numberSelected = [notesTableView numberOfSelectedRows];
	if (selector == @selector(toggleCollapse:))
		return currentNote != nil || [splitView isLeadingPaneCollapsed];
	
	if (selector == @selector(printNote:) || 
		selector == @selector(deleteNote:) ||
		selector == @selector(exportNote:) || 
		selector == @selector(tagNote:)) {
		
		return (numberSelected > 0);
		
	} else if (selector == @selector(renameNote:) ||
			   selector == @selector(copyNoteLink:)) {
		
		return (numberSelected == 1);
		
	} else if (selector == @selector(revealNote:)) {
	
		return (numberSelected == 1) && [notationController currentNoteStorageFormat] != SingleDatabaseFormat;
		
	} else if (selector == @selector(fixFileEncoding:)) {
		
		return (currentNote != nil && storageFormatOfNote(currentNote) == PlainTextFormat && ![currentNote contentsWere7Bit]);
	} else if (selector == @selector(editNoteExternally:)) {
		
		return (numberSelected > 0) && [[menuItem representedObject] canEditAllNotes:
										[notationController notesAtIndexes:[notesTableView selectedRowIndexes]]];
	}
	
	return YES;
}

- (void)updateNoteMenus {
	NSMenu *notesMenu = [[[NSApp mainMenu] itemWithTag:NOTES_MENU_ID] submenu];
	
	NSInteger menuIndex = [notesMenu indexOfItemWithTarget:self andAction:@selector(deleteNote:)];
	NSMenuItem *deleteItem = nil;
	if (menuIndex > -1 && (deleteItem = [notesMenu itemAtIndex:menuIndex]))	{
		NSString *trailingQualifier = [prefsController confirmNoteDeletion] ? NSLocalizedString(@"...", @"ellipsis character") : @"";
		[deleteItem setTitle:[NSString stringWithFormat:@"%@%@", 
							  NSLocalizedString(@"Delete", nil), trailingQualifier]];
	}
	
	[notesMenu setSubmenu:[[ExternalEditorListController sharedInstance] addEditNotesMenu] forItem:[notesMenu itemWithTag:88]];
	
	NSMenu *viewMenu = [[[NSApp mainMenu] itemWithTag:VIEW_MENU_ID] submenu];
    NSInteger wordCountIndex = [viewMenu indexOfItemWithTarget:self andAction:@selector(toggleWordCount:)];
    NSMenuItem *wordItem = wordCountIndex == -1 ? [viewMenu addItemWithTitle:NSLocalizedString(@"Show Word Count", nil) action:@selector(toggleWordCount:) keyEquivalent:@""] : [viewMenu itemAtIndex:wordCountIndex];
    [wordItem setTarget:self];
    [wordItem setState:[prefsController showWordCount]];
	NSInteger collapseIndex = [viewMenu indexOfItemWithTarget:self andAction:@selector(toggleCollapse:)];
	NSMenuItem *collapseItem;
	if (collapseIndex == -1) {
		collapseItem = [viewMenu addItemWithTitle:@"" action:@selector(toggleCollapse:) keyEquivalent:@"n"];
		[collapseItem setTarget:self];
		[collapseItem setKeyEquivalentModifierMask:NSEventModifierFlagCommand | NSEventModifierFlagOption];
	} else {
		collapseItem = [viewMenu itemAtIndex:collapseIndex];
	}
	[collapseItem setTitle:[splitView isLeadingPaneCollapsed] ?
		NSLocalizedString(@"Expand Notes List", nil) : NSLocalizedString(@"Collapse Notes List", nil)];
	
	menuIndex = [viewMenu indexOfItemWithTarget:notesTableView andAction:@selector(toggleNoteBodyPreviews:)];
	NSMenuItem *bodyPreviewItem = nil;
	if (menuIndex > -1 && (bodyPreviewItem = [viewMenu itemAtIndex:menuIndex])) {
		[bodyPreviewItem setTitle: [prefsController tableColumnsShowPreview] ? 
		 NSLocalizedString(@"Hide Note Previews in Title", @"menu item in the View menu to turn off note-body previews in the Title column") : 
		 NSLocalizedString(@"Show Note Previews in Title", @"menu item in the View menu to turn on note-body previews in the Title column")];
	}
	menuIndex = [viewMenu indexOfItemWithTarget:self andAction:@selector(switchViewLayout:)];
	NSMenuItem *switchLayoutItem = nil;
	if (menuIndex > -1 && (switchLayoutItem = [viewMenu itemAtIndex:menuIndex])) {
		[switchLayoutItem setTitle:[prefsController horizontalLayout] ? 
		 NSLocalizedString(@"Switch to Vertical Layout", @"title of alternate view layout menu item") : 
		 NSLocalizedString(@"Switch to Horizontal Layout", @"title of view layout menu item")];		
	}
}

- (void)_forceRegeneratePreviewsForTitleColumn {
	[notationController regeneratePreviewsForColumn:[notesTableView noteAttributeColumnForIdentifier:NoteTitleColumnString]	
								visibleFilteredRows:[notesTableView rowsInRect:[notesTableView visibleRect]] forceUpdate:YES];
}

- (void)updateInterfaceAppearance {
    [window setAppearance:nil];
    //dynamic colors follow the system appearance; fixed ones pick the appearance that suits them
    if ([prefsController colorScheme] != 0 && [[prefsController backgroundTextColor] type] != NSColorTypeCatalog) {
        NSColor *background = [[prefsController backgroundTextColor] colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
        CGFloat brightness = background.redComponent * 0.299 + background.greenComponent * 0.587 + background.blueComponent * 0.114;
        [window setAppearance:[NSAppearance appearanceNamed:brightness < 0.5 ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua]];
    }
    [window setBackgroundColor:[prefsController backgroundTextColor]];
    [splitView setSeparatorColor:[prefsController interfaceSeparatorColor]];
    [editorStatusView updateInterfaceColors];
    [field setTextColor:[prefsController foregroundTextColor]];
    [field setNeedsDisplay:YES];
    ResetFontRelatedTableAttributes();
    [notationController regenerateAllPreviews];
    [notesTableView reloadDataIfNotEditing];
    [splitView setNeedsDisplay:YES];
    [self updateWordCount];
}

- (void)tableView:(NSTableView *)table willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if ([cell respondsToSelector:@selector(setTextColor:)])
        [cell setTextColor:[cell isHighlighted] && [notesTableView isActiveStyle] ? [NSColor alternateSelectedControlTextColor] : [prefsController foregroundTextColor]];
}

static NSString *NVNotesListSizeKey(BOOL sideBySide) {
	return sideBySide ? @"NotesListWidth" : @"NotesListHeight";
}

//RBSplitView stored "<pane count> <list size> <editor size>" for each orientation, with a negative size for a collapsed pane
+ (void)migrateLegacyNotesListLayoutInDefaults:(NSUserDefaults *)defaults sideBySide:(BOOL)sideBySide {
	for (NSNumber *layout in @[@NO, @YES]) {
		NSString *legacyKey = [layout boolValue] ? @"RBSplitView V centralSplitView" : @"RBSplitView H centralSplitView";
		NSArray *parts = [[defaults stringForKey:legacyKey] componentsSeparatedByString:@" "];
		if ([parts count] == 3 && ![defaults objectForKey:NVNotesListSizeKey([layout boolValue])]) {
			double size = [[parts objectAtIndex:1] doubleValue];
			[defaults setDouble:floor(fabs(size)) forKey:NVNotesListSizeKey([layout boolValue])];
			if ([layout boolValue] == sideBySide && ![defaults objectForKey:@"NotesListCollapsed"])
				[defaults setBool:size <= 0.0 forKey:@"NotesListCollapsed"];
		}
		[defaults removeObjectForKey:legacyKey];
	}
}

- (void)_restoreNotesListLayout {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[[self class] migrateLegacyNotesListLayoutInDefaults:defaults sideBySide:[prefsController horizontalLayout]];
	[self _configureDividerForCurrentLayout];
	changingViewLayout = YES;
	[splitView setLeadingPaneCollapsed:[defaults boolForKey:@"NotesListCollapsed"]];
	changingViewLayout = NO;
}

- (void)_saveNotesListLayout {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults setDouble:[splitView expandedLeadingPaneSize] forKey:NVNotesListSizeKey([splitView isVertical])];
	[defaults setBool:[splitView isLeadingPaneCollapsed] forKey:@"NotesListCollapsed"];
}

- (void)_configureDividerForCurrentLayout {
	BOOL sideBySide = [prefsController horizontalLayout];
	changingViewLayout = YES;
	[splitView setVertical:sideBySide];
	[splitView adjustSubviews];
	CGFloat size = [[NSUserDefaults standardUserDefaults] doubleForKey:NVNotesListSizeKey(sideBySide)];
	if (size <= 0.0) {
		NSSize splitSize = [splitView bounds].size;
		size = round((sideBySide ? splitSize.width : splitSize.height) / 3.0);
	}
	[splitView setExpandedLeadingPaneSize:size];
	changingViewLayout = NO;
}

- (IBAction)switchViewLayout:(id)sender {
	if (sender != self) [self _setFullScreenSwitchedLayout:NO];
	ViewLocationContext ctx = [notesTableView viewingLocation];
	ctx.pivotRowWasEdge = NO;
	[notesTableView noteFirstVisibleRow];
	
	[self _saveNotesListLayout];
	[prefsController setHorizontalLayout:![prefsController horizontalLayout] sender:self];
	[notationController updateDateStringsIfNecessary];
	[self _configureDividerForCurrentLayout];
	[notationController regenerateAllPreviews];
	
	[notesTableView setViewingLocation:ctx];
	[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];
	
	[self updateNoteMenus];
}

- (void)createFromSelection:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error {
	if (!notationController || ![self addNotesFromPasteboard:pboard]) {
		*error = NSLocalizedString(@"Error: Couldn't create a note from the selection.", @"error message to set during a Service call when adding a note failed");
	}
}



- (IBAction)renameNote:(id)sender {
    //edit the first selected note	
	[notesTableView editRowAtColumnWithIdentifier:NoteTitleColumnString];
}

- (void)deleteAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo {

	id retainedDeleteObj = (__bridge_transfer id)contextInfo;
	
	if (returnCode == NSAlertFirstButtonReturn) {
		//delete! nil-msgsnd-checking
		
		//ensure that there are no pending edits in the tableview, 
		//lest editing end with the same field editor and a different selected note
		//resulting in the renaming of notes in adjacent rows
		[notesTableView abortEditing];
		
		if ([retainedDeleteObj isKindOfClass:[NSArray class]]) {
			[notationController removeNotes:retainedDeleteObj];
		} else if ([retainedDeleteObj isKindOfClass:[NoteObject class]]) {
			[notationController removeNote:retainedDeleteObj];
		}
		
		if ([[alert suppressionButton] state] == NSControlStateValueOn) {
			[prefsController setConfirmNoteDeletion:NO sender:self];
		}
	}
}


- (IBAction)deleteNote:(id)sender {
		
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	if ([indexes count] > 0) {
		id deleteObj = [indexes count] > 1 ? (id)([notationController notesAtIndexes:indexes]) : (id)([notationController noteObjectAtFilteredIndex:[indexes firstIndex]]);
		
		if ([prefsController confirmNoteDeletion]) {
			NSString *warningSingleFormatString = NSLocalizedString(@"Delete the note titled quotemark%@quotemark?", @"alert title when asked to delete a note");
			NSString *warningMultipleFormatString = NSLocalizedString(@"Delete %d notes?", @"alert title when asked to delete multiple notes");
			NSString *warnString = currentNote ? [NSString stringWithFormat:warningSingleFormatString, titleOfNote(currentNote)] : 
			[NSString stringWithFormat:warningMultipleFormatString, [indexes count]];
			
			NSAlert *alert = NVMakeAlert(warnString, NSLocalizedString(@"Press Command-Z to undo this action later.", @"informational delete-this-note? text"), NSLocalizedString(@"Delete", @"name of delete button"), NSLocalizedString(@"Cancel", @"name of cancel button"), nil);
			[alert setShowsSuppressionButton:YES];
			
			NVBeginAlertSheet(alert, window, self, @selector(deleteAlertDidEnd:returnCode:contextInfo:), (__bridge_retained void *)deleteObj);
		} else {
			//just delete the notes outright			
			if ([indexes count] > 1) [notationController removeNotes:deleteObj];
			else [notationController removeNote:deleteObj];
		}
	}
}

- (IBAction)copyNoteLink:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	if ([indexes count] == 1) {
		[[[[[notationController notesAtIndexes:indexes] lastObject] 
		   uniqueNoteLink] absoluteString] copyItemToPasteboard:nil];
	}
}

- (IBAction)exportNote:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	NSArray *notes = [notationController notesAtIndexes:indexes];
	
	[notationController synchronizeNoteChanges:nil];
	[[ExporterManager sharedManager] exportNotes:notes forWindow:window];
}

- (IBAction)revealNote:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	NSString *path = nil;
	
	if ([indexes count] != 1 || !(path = [[notationController noteObjectAtFilteredIndex:[indexes lastIndex]] noteFilePath])) {
		NSBeep();
		return;
	}
	[[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
}

- (IBAction)editNoteExternally:(id)sender {
	ExternalEditor *ed = [sender representedObject];
	if ([ed isKindOfClass:[ExternalEditor class]]) {
		NSIndexSet *indexes = [notesTableView selectedRowIndexes];

		if (kCGEventFlagMaskAlternate == (CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState) & (CGEventFlags)NSEventModifierFlagDeviceIndependentFlagsMask)) {
			//allow changing the default editor directly from Notes menu
			[[ExternalEditorListController sharedInstance] setDefaultEditor:ed];
		}
		//force-write any queued changes to disk in case notes are being stored as separate files which might be opened directly by the method below
		[notationController synchronizeNoteChanges:nil];
		
		[[notationController notesAtIndexes:indexes] makeObjectsPerformSelector:@selector(editExternallyUsingEditor:) withObject:ed];
	} else {
		NSBeep();
	}
}

- (IBAction)printNote:(id)sender {
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	[MultiplePageView printNotes:[notationController notesAtIndexes:indexes] forWindow:window];
}

- (IBAction)tagNote:(id)sender {
	//if single note, add the tag column if necessary and then begin editing
	
	NSIndexSet *indexes = [notesTableView selectedRowIndexes];
	
	if ([indexes count] > 1) {
        NSArray *notes = [notationController notesAtIndexes:indexes];
        NSMutableArray *shared = [NSMutableArray arrayWithArray:[labelsOfNote(notes.firstObject) labelCompatibleWords]];
        for (NoteObject *note in notes) {
            NSSet *tags = [NSSet setWithArray:[[labelsOfNote(note) labelCompatibleWords] valueForKey:@"lowercaseString"]];
            for (NSString *tag in [shared copy])
                if (![tags containsObject:tag.lowercaseString]) [shared removeObject:tag];
        }
        NSAlert *alert = NVMakeAlert(NSLocalizedString(@"Edit Shared Tags", nil), NSLocalizedString(@"Edit tags shared by the selected notes. Other tags are kept.", nil), NSLocalizedString(@"Apply", nil), NSLocalizedString(@"Cancel", nil), nil);
        NSTokenField *tags = [[NSTokenField alloc] initWithFrame:NSMakeRect(0, 0, 380, 55)];
        [tags setTokenizingCharacterSet:[NSCharacterSet labelSeparatorCharacterSet]];
        [tags setObjectValue:shared];
        [tags setDelegate:self];
        [tags setAccessibilityLabel:NSLocalizedString(@"Shared tags", nil)];
        [alert setAccessoryView:tags];
        [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
            if (response == NSAlertFirstButtonReturn)
                [self applySharedTags:[tags objectValue] toNotes:notes originalSharedTags:shared];
        }];
		[window.attachedSheet makeFirstResponder:tags];
	} else if ([indexes count] == 1) {
		[notesTableView editRowAtColumnWithIdentifier:NoteLabelsColumnString];		
	}
}

- (NSArray *)tokenField:(NSTokenField *)tokenField completionsForSubstring:(NSString *)substring indexOfToken:(NSInteger)index indexOfSelectedItem:(NSInteger *)selectedIndex {
    return [[notationController labelsListDataSource] labelTitlesPrefixedByString:substring indexOfSelectedItem:selectedIndex minusWordSet:[NSSet setWithArray:[tokenField objectValue] ?: @[]]];
}

- (void)applySharedTags:(NSArray *)tags toNotes:(NSArray *)notes originalSharedTags:(NSArray *)sharedTags {
    NSSet *oldShared = [NSSet setWithArray:[sharedTags valueForKey:@"lowercaseString"]];
    for (NoteObject *note in notes) {
        NSMutableArray *result = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSString *tag in [labelsOfNote(note) labelCompatibleWords])
            if (![oldShared containsObject:tag.lowercaseString]) { [result addObject:tag]; [seen addObject:tag.lowercaseString]; }
        for (NSString *value in tags)
            for (NSString *tag in [value labelCompatibleWords])
                if (tag.length && ![seen containsObject:tag.lowercaseString]) { [result addObject:tag]; [seen addObject:tag.lowercaseString]; }
        [note setLabelString:[result componentsJoinedByString:@", "]];
    }
}

- (void)noteImporter:(AlienNoteImporter*)importer importedNotes:(NSArray*)notes {
	
	[notationController addNotes:notes];
}
- (IBAction)importNotes:(id)sender {
	AlienNoteImporter *importer = [[AlienNoteImporter alloc] init];
	[importer importNotesFromDialogAroundWindow:window receptionDelegate:self];
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
    if ([selectorString isEqualToString:SEL_STR(setShowDockIcon:sender:)] ||
        [selectorString isEqualToString:SEL_STR(setShowMenuBarIcon:sender:)]) {
        [self updateDesktopPresence];
        return;
    }
    if ([selectorString isEqualToString:SEL_STR(setShowWordCount:sender:)]) {
        [self updateWordCount];
        [self updateNoteMenus];
        return;
    }
    if ([selectorString isEqualToString:SEL_STR(setAliasDataForDefaultDirectory:sender:)]) {
		//defaults changed for the database location -- load the new one!
		
		OSStatus err = noErr;
		NotationController *newNotation = nil;
		NSData *newData = [prefsController aliasDataForDefaultDirectory];
		if (newData) {
			if ((newNotation = [[NotationController alloc] initWithAliasData:newData error:&err])) {
				[self setNotationController:newNotation];
			} else {
				
				//set alias data back
				NSData *oldData = [notationController aliasDataForNoteDirectory];
				[prefsController setAliasDataForDefaultDirectory:oldData sender:self];
				
				//display alert with err--could not set notation directory 
				NSString *location = [[[NSFileManager defaultManager] pathCopiedFromAliasData:newData] stringByAbbreviatingWithTildeInPath];
				NSString *oldLocation = [[[NSFileManager defaultManager] pathCopiedFromAliasData:oldData] stringByAbbreviatingWithTildeInPath]; 
				NSString *reason = [NSString reasonStringFromCarbonFSError:err];
				NVRunAlert(NSAlertStyleWarning, [NSString stringWithFormat:NSLocalizedString(@"Unable to initialize notes database in \n%@ because %@.",nil), location, reason], [NSString stringWithFormat:NSLocalizedString(@"Reverting to current location of %@.",nil), oldLocation], NSLocalizedString(@"OK",nil), NULL, NULL);
			}
		}
    } else if ([selectorString isEqualToString:SEL_STR(setSortedTableColumnKey:reversed:sender:)]) {
		NoteAttributeColumn *oldSortCol = [notationController sortColumn];
		NoteAttributeColumn *newSortCol = [notesTableView noteAttributeColumnForIdentifier:[prefsController sortedTableColumnKey]];
		BOOL changedColumns = oldSortCol != newSortCol;
		
		ViewLocationContext ctx = {0};
		if (changedColumns) {
			ctx = [notesTableView viewingLocation];
			ctx.pivotRowWasEdge = NO;
		}
		
		[notationController setSortColumn:newSortCol];
		
		if (changedColumns) [notesTableView setViewingLocation:ctx];
		
	} else if ([selectorString isEqualToString:SEL_STR(setNoteBodyFont:sender:)]) {
		
		[notationController restyleAllNotes];
		if (currentNote) {
			[self contentsUpdatedForNote:currentNote];
		}
    } else if ([selectorString isEqualToString:SEL_STR(setForegroundTextColor:sender:)]) {
        [self updateInterfaceAppearance];
		
		[notationController setForegroundTextColor:[prefsController foregroundTextColor]];
		if (currentNote) {
			[self contentsUpdatedForNote:currentNote];
		} 
    } else if ([selectorString isEqualToString:SEL_STR(setBackgroundTextColor:sender:)]) {
        [self updateInterfaceAppearance];
	} else if ([selectorString isEqualToString:SEL_STR(setTableFontSize:sender:)] || [selectorString isEqualToString:SEL_STR(setTableColumnsShowPreview:sender:)]) {
		
		ResetFontRelatedTableAttributes();
		[notesTableView updateTitleDereferencorState];
		[[notationController labelsListDataSource] invalidateCachedLabelImages];
		[self _forceRegeneratePreviewsForTitleColumn];
				
		if ([selectorString isEqualToString:SEL_STR(setTableColumnsShowPreview:sender:)]) [self updateNoteMenus];
		
		[notesTableView performSelector:@selector(reloadData) withObject:nil afterDelay:0];
	} else if ([selectorString isEqualToString:SEL_STR(addTableColumn:sender:)] || [selectorString isEqualToString:SEL_STR(removeTableColumn:sender:)]) {
		
		ResetFontRelatedTableAttributes();
		[self _forceRegeneratePreviewsForTitleColumn];
		[notesTableView performSelector:@selector(reloadDataIfNotEditing) withObject:nil afterDelay:0];
		
	} else if ([selectorString isEqualToString:SEL_STR(setConfirmNoteDeletion:sender:)]) {
		[self updateNoteMenus];
	} else if ([selectorString isEqualToString:SEL_STR(setAutoCompleteSearches:sender:)]) {
		if ([prefsController autoCompleteSearches])
			[notationController updateTitlePrefixConnections];
	}
	
}

- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn {
    if (tableView == notesTableView) {
		//this sets global prefs options, which ultimately calls back to us
		[notesTableView setStatusForSortedColumn:tableColumn];
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldShowCellExpansionForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
	return ![[tableColumn identifier] isEqualToString:NoteTitleColumnString];
}

- (IBAction)showHelpDocument:(id)sender {
	NSString *path = nil;
	
	switch ([sender tag]) {
		case 1:		//shortcuts
			path = [[NSBundle mainBundle] pathForResource:NSLocalizedString(@"Excruciatingly Useful Shortcuts", nil) ofType:@"nvhelp" inDirectory:nil];
		case 2:		//acknowledgments
			if (!path) path = [[NSBundle mainBundle] pathForResource:@"Acknowledgments" ofType:@"txt" inDirectory:nil];
			[[NSWorkspace sharedWorkspace] openURLs:@[[NSURL fileURLWithPath:path]] withApplicationAtURL:[[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:@"com.apple.TextEdit"] configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
			break;
		case 3:		//product site
			[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:NSLocalizedString(@"SiteURL", nil)]];
			break;
		case 4:		//development site
			[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"http://notational.net/development"]];
			break;
		default:
			NSBeep();
	}
}

- (void)applicationWillBecomeActive:(NSNotification *)aNotification {
	if (!activationRequested) {
		previousActiveApplication = nil;
		activatedFromAnotherSpace = NO;
	}
	activationRequested = NO;
}

- (void)applicationDidBecomeActive:(NSNotification *)aNotification {
    if (pendingSearchFocus)
        [self performSelector:@selector(selectSearchAfterActivation) withObject:nil afterDelay:0];
	[notationController checkJournalExistence];
	
    if ([notationController currentNoteStorageFormat] != SingleDatabaseFormat)
		[notationController performSelector:@selector(synchronizeNotesFromDirectory) withObject:nil afterDelay:0.0];
		
	[notationController updateDateStringsIfNecessary];
}

- (void)applicationWillResignActive:(NSNotification *)aNotification {
	//sync note files when switching apps so user doesn't have to guess when they'll be updated
	[notationController synchronizeNoteChanges:nil];
}

- (void)updateDesktopPresence {
    if ([prefsController showMenuBarIcon] && !statusItem) {
        statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
        statusItem.button.image = [NSImage imageWithSystemSymbolName:@"note.text" accessibilityDescription:NSLocalizedString(@"Notational Velocity", nil)];
        statusItem.button.image.template = YES;
        statusItem.button.toolTip = NSLocalizedString(@"Notational Velocity — click to show or hide; right-click for commands", nil);
        statusItem.button.target = self;
        statusItem.button.action = @selector(statusItemAction:);
        [statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
        if (!statusMenu) {
            statusMenu = [[NSMenu alloc] initWithTitle:NSLocalizedString(@"Notational Velocity", nil)];
            NSArray *titles = @[NSLocalizedString(@"Show Notational Velocity", nil),
                                NSLocalizedString(@"Add New Note from Clipboard", nil),
                                NSLocalizedString(@"Settings…", nil),
                                NSLocalizedString(@"Show Dock Icon", nil)];
            SEL actions[] = {@selector(bringFocusToControlField:), @selector(createNoteFromStatusClipboard:),
                             @selector(showPreferencesWindow:), @selector(toggleDockIcon:)};
            for (NSUInteger index = 0; index < titles.count; index++)
                [[statusMenu addItemWithTitle:titles[index] action:actions[index] keyEquivalent:@""] setTarget:self];
            [statusMenu addItem:[NSMenuItem separatorItem]];
            [[statusMenu addItemWithTitle:NSLocalizedString(@"Quit Notational Velocity", nil) action:@selector(terminate:) keyEquivalent:@""] setTarget:NSApp];
        }
    } else if (![prefsController showMenuBarIcon] && statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
        statusItem = nil;
    }
    NSApplicationActivationPolicy policy = [prefsController showDockIcon] ? NSApplicationActivationPolicyRegular : NSApplicationActivationPolicyAccessory;
    if (NSApp.activationPolicy != policy) {
        BOOL wasActive = NSApp.isActive;
        if (![NSApp setActivationPolicy:policy]) {
            [prefsController setShowDockIcon:NSApp.activationPolicy == NSApplicationActivationPolicyRegular sender:self];
            return;
        }
        if (wasActive) {
            [NSApp activate];
            if (window.visible) [window makeKeyAndOrderFront:nil];
        }
    }
}

- (IBAction)statusItemAction:(id)sender {
    NSEvent *event = NSApp.currentEvent;
    if (event.type == NSEventTypeRightMouseUp || (event.modifierFlags & NSEventModifierFlagControl))
        [self showStatusMenu:sender];
    else if (NSApp.isActive && window.isMainWindow) {
        [notationController synchronizeNoteChanges:nil];
        [window orderOut:sender];
        [[NSRunningApplication currentApplication] hide];
    } else [self bringFocusToControlField:sender];
}

- (IBAction)showStatusMenu:(id)sender {
    [statusMenu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSMinY(statusItem.button.bounds)) inView:statusItem.button];
}

- (IBAction)toggleDockIcon:(id)sender {
    [prefsController setShowDockIcon:![prefsController showDockIcon] sender:self];
    [self updateDesktopPresence];
}

- (IBAction)createNoteFromStatusClipboard:(id)sender {
    [self bringFocusToControlField:sender];
    [NSApp sendAction:@selector(paste:) to:notesTableView from:sender];
    pendingSearchFocus = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(selectSearchAfterActivation) object:nil];
}

- (NSMenu *)applicationDockMenu:(NSApplication *)sender {
	static NSMenu *dockMenu = nil;
	if (!dockMenu) {
		dockMenu = [[NSMenu alloc] init];
		[[dockMenu addItemWithTitle:NSLocalizedString(@"Add New Note from Clipboard", @"menu item title in dock menu")
							 action:@selector(paste:) keyEquivalent:@""] setTarget:notesTableView];
	}
	return dockMenu;
}

- (void)cancel:(id)sender {
	//fallback for when other views are hidden/removed during toolbar collapse
	[self cancelOperation:sender];
}

- (void)cancelOperation:(id)sender {
	//simulate a search for nothing
	
	[field setStringValue:@""];
	typedStringIsCached = NO;
	
	[notationController filterNotesFromString:@""];
	
	[notesTableView deselectAll:sender];
	[self _expandToolbar];
	
	[field selectText:sender];
	[[field cell] setShowsClearButton:NO];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)aTextView doCommandBySelector:(SEL)command {
	if (control == (NSControl*)field) {
		
		//backwards-searching is slow enough as it is, so why not just check this first?
		if (command == @selector(deleteBackward:))
			return NO;
		
		if (command == @selector(moveDown:) || command == @selector(moveUp:) ||
			//catch shift-up/down selection behavior
			command == @selector(moveDownAndModifySelection:) ||
			command == @selector(moveUpAndModifySelection:) ||
			command == @selector(moveToBeginningOfDocumentAndModifySelection:) ||
			command == @selector(moveToEndOfDocumentAndModifySelection:)) {
			
			BOOL singleSelection = ([notesTableView numberOfRows] == 1 && [notesTableView numberOfSelectedRows] == 1);
			[notesTableView keyDown:[window currentEvent]];
			
			NSUInteger strLen = [[aTextView string] length];
			if (!singleSelection && [aTextView selectedRange].length != strLen) {
				[aTextView setSelectedRange:NSMakeRange(0, strLen)];
			}
			
			return YES;
		}
		
		if ((command == @selector(insertTab:) || command == @selector(insertTabIgnoringFieldEditor:))) {
			
			if (![[aTextView string] length]) {
				return YES;
			}
			if (!currentNote && [notationController preferredSelectedNoteIndex] != NSNotFound && [prefsController autoCompleteSearches]) {
				//if the current note is deselected and re-searching would auto-complete this search, then allow tab to trigger it
				[self searchForString:[self fieldSearchString]];
				return YES;
			} else if ([textView isHidden]) {
				return YES;
			}
			
			[window makeFirstResponder:textView];
			
			//don't eat the tab!
			return NO;
		}
		if (command == @selector(moveToBeginningOfDocument:)) {
		    [notesTableView selectRowAndScroll:0];
		    return YES;
		}
		if (command == @selector(moveToEndOfDocument:)) {
		    [notesTableView selectRowAndScroll:[notesTableView numberOfRows]-1];
		    return YES;
		}
		
		if (command == @selector(moveToBeginningOfLine:) || command == @selector(moveToLeftEndOfLine:)) {
			[aTextView moveToBeginningOfDocument:nil];
			return YES;
		}
		if (command == @selector(moveToEndOfLine:) || command == @selector(moveToRightEndOfLine:)) {
			[aTextView moveToEndOfDocument:nil];
			return YES;
		}
		
		if (command == @selector(moveToBeginningOfLineAndModifySelection:) || command == @selector(moveToLeftEndOfLineAndModifySelection:)) {
			
			if ([aTextView respondsToSelector:@selector(moveToBeginningOfDocumentAndModifySelection:)]) {
				[(id)aTextView performSelector:@selector(moveToBeginningOfDocumentAndModifySelection:)];
				return YES;
			}
		}
		if (command == @selector(moveToEndOfLineAndModifySelection:) || command == @selector(moveToRightEndOfLineAndModifySelection:)) {
			if ([aTextView respondsToSelector:@selector(moveToEndOfDocumentAndModifySelection:)]) {
				[(id)aTextView performSelector:@selector(moveToEndOfDocumentAndModifySelection:)];
				return YES;
			}
		}
		
		//we should make these two commands work for linking editor as well
		if (command == @selector(deleteToMark:)) {
			[aTextView deleteWordBackward:nil];
			return YES;
		}
		if (command == NSSelectorFromString(@"noop:")) {
			//control-U is not set to anything by default, so we have to check the event itself for noops
			NSEvent *event = [window currentEvent];
			if ([event modifierFlags] & NSEventModifierFlagControl) {
				if ([event firstCharacterIgnoringModifiers] == 'u') {
					//in 1.1.1 this deleted the entire line, like tcsh. this is more in-line with bash
					[aTextView deleteToBeginningOfLine:nil];
					return YES;
				}
			}
		}
		
	} else if (control == (NSControl*)notesTableView) {
		if (command == @selector(insertNewline:)) {
			//hit return in cell
			[window makeFirstResponder:textView];
			return YES;
		}
	} else
		NSLog(@"%@/%@ got %@", [control description], [aTextView description], NSStringFromSelector(command));
	
	return NO;
}

- (void)_setCurrentNote:(NoteObject*)aNote {
	//save range of old current note
	//we really only want to save the insertion point position if it's currently invisible
	//how do we test that?
	BOOL wasAutomatic = NO;
	NSRange currentRange = [textView selectedRangeWasAutomatic:&wasAutomatic];
	if (!wasAutomatic) [currentNote setSelectedRange:currentRange];
	
	//regenerate content cache before switching to new note
	[currentNote updateContentCacheCStringIfNecessary];
	
	
	currentNote = aNote;
}

- (void)setNeedsWordCountUpdate {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateWordCount) object:nil];
    [self performSelector:@selector(updateWordCount) withObject:nil afterDelay:0.2];
}

- (void)updateWordCount {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateWordCount) object:nil];
    BOOL visible = currentNote && !textView.hidden && ([prefsController showWordCount] || temporaryWordCount);
    [wordCountLabel setHidden:!visible];
    NSScrollView *scroll = textView.enclosingScrollView;
    CGFloat footerInset = visible ? 24 : 0;
    if (scroll.automaticallyAdjustsContentInsets || scroll.contentInsets.bottom != footerInset) {
        [scroll setAutomaticallyAdjustsContentInsets:NO];
        [scroll setContentInsets:NSEdgeInsetsMake(0, 0, footerInset, 0)];
    }
    if (!visible) return;
    __block NSUInteger count = 0;
    [textView.string enumerateSubstringsInRange:NSMakeRange(0, textView.string.length)
        options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
        usingBlock:^(NSString *substring, NSRange range, NSRange enclosingRange, BOOL *stop) { count++; }];
    [wordCountLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"%lu words", nil), (unsigned long)count]];
    [wordCountLabel setTextColor:[prefsController interfaceSecondaryColor]];
    [wordCountLabel setBackgroundColor:[prefsController backgroundTextColor]];
}

- (IBAction)toggleWordCount:(id)sender {
    [prefsController setShowWordCount:![prefsController showWordCount] sender:nil];
}

- (void)flagsChanged:(NSEvent *)event {
    temporaryWordCount = (event.modifierFlags & NSEventModifierFlagOption) != 0;
    [self updateWordCount];
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
    [self _updateWindowTitleLayout];
    [self selectSearchAfterActivation];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    temporaryWordCount = NO;
    [self updateWordCount];
}

- (NoteObject*)selectedNoteObject {
	return currentNote;
}

- (NSString*)fieldSearchString {
	NSString *typed = [self typedString];
	if (typed) return typed;
	
	if (!currentNote) return [field stringValue];
	
	return nil;
}

- (NSString*)typedString {
	if (typedStringIsCached)
		return typedString;
	
	return nil;
}

- (void)cacheTypedStringIfNecessary:(NSString*)aString {
	if (!typedStringIsCached) {
		typedString = [(aString ? aString : [field stringValue]) copy];
		typedStringIsCached = YES;
	}
}

//from fieldeditor
- (void)controlTextDidChange:(NSNotification *)aNotification {
	
	if ([aNotification object] == field) {
		typedStringIsCached = NO;
		isFilteringFromTyping = YES;
		
		NSTextView *fieldEditor = [[aNotification userInfo] objectForKey:@"NSFieldEditor"];
		NSString *fieldString = [fieldEditor string];
		
		BOOL didFilter = [notationController filterNotesFromString:fieldString];
		
		if ([fieldString length] > 0) {
			[field setSnapbackString:nil];
			

			NSUInteger preferredNoteIndex = [notationController preferredSelectedNoteIndex];
			
			//lastLengthReplaced depends on textView:shouldChangeTextInRange:replacementString: being sent before controlTextDidChange: runs			
			if ([prefsController autoCompleteSearches] && preferredNoteIndex != NSNotFound && ([field lastLengthReplaced] > 0)) {
				
				[notesTableView selectRowAndScroll:preferredNoteIndex];
				
				if (didFilter) { 
					//current selection may be at the same row, but note at that row may have changed
					[self displayContentsForNoteAtIndex:preferredNoteIndex];
				}
				
				NSAssert(currentNote != nil, @"currentNote must not--cannot--be nil!");
				
				NSRange typingRange = [fieldEditor selectedRange];
				
				//fill in the remaining characters of the title and select
				if ([field lastLengthReplaced] > 0 && typingRange.location < [titleOfNote(currentNote) length]) {
					
					[self cacheTypedStringIfNecessary:fieldString];
					
					NSAssert([fieldString isEqualToString:[fieldEditor string]], @"I don't think it makes sense for fieldString to change");
					
					NSString *remainingTitle = [titleOfNote(currentNote) substringFromIndex:typingRange.location];
					typingRange.length = [fieldString length] - typingRange.location;
					typingRange.length = MAX(typingRange.length, 0U);
					
					[fieldEditor replaceCharactersInRange:typingRange withString:remainingTitle];
					typingRange.length = [remainingTitle length];
					[fieldEditor setSelectedRange:typingRange];
				}
				
			} else {
				//auto-complete is off, search string doesn't prefix any title, or part of the search string is being removed
				goto selectNothing;
			}
		} else {
			//selecting nothing; nothing typed
		selectNothing:
			isFilteringFromTyping = NO;
			[notesTableView deselectAll:nil];
			
			//reloadData could have already de-selected us, and hence this notification would not be sent from -deselectAll:
			[self processChangedSelectionForTable:notesTableView];
		}
		
		isFilteringFromTyping = NO;
	}
}

- (void)tableViewSelectionIsChanging:(NSNotification *)aNotification {
	
	BOOL allowMultipleSelection = NO;
	NSEvent *event = [window currentEvent];
    
	NSEventType type = [event type];
	//do not allow drag-selections unless a modifier is pressed
	if (type == NSEventTypeLeftMouseDragged || type == NSEventTypeLeftMouseDown) {
		NSEventModifierFlags flags = [event modifierFlags];
		if ((flags & NSEventModifierFlagShift) || (flags & NSEventModifierFlagCommand)) {
			allowMultipleSelection = YES;
		}
	}
	
	if (allowMultipleSelection != [notesTableView allowsMultipleSelection]) {
		//we may need to hack some hidden NSTableView instance variables to improve mid-drag flags-changing
		
		[notesTableView setAllowsMultipleSelection:allowMultipleSelection];
		
		//we need this because dragging a selection back to the same note will nto trigger a selectionDidChange notification
		[self performSelector:@selector(setTableAllowsMultipleSelection) withObject:nil afterDelay:0];
	}
    
	if ([window firstResponder] != notesTableView) {
		//occasionally changing multiple selection ability in-between selecting multiple items causes total deselection
		[window makeFirstResponder:notesTableView];
	}
	
	[self processChangedSelectionForTable:[aNotification object]];
}

- (void)setTableAllowsMultipleSelection {
	[notesTableView setAllowsMultipleSelection:YES];
}

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification {
	NSEventType type = [[window currentEvent] type];
	if (type != NSEventTypeKeyDown && type != NSEventTypeKeyUp) {
		[self performSelector:@selector(setTableAllowsMultipleSelection) withObject:nil afterDelay:0];
	}
	
	[self processChangedSelectionForTable:[aNotification object]];
}

- (void)processChangedSelectionForTable:(NSTableView*)table {
	NSInteger selectedRow = [table selectedRow];
	NSInteger numberSelected = [table numberOfSelectedRows];
	
	NSTextView *fieldEditor = (NSTextView*)[field currentEditor];
	
	if (table == (NSTableView*)notesTableView) {
		
		if (selectedRow > -1 && numberSelected == 1) {
			//if it is uncached, cache the typed string only if we are selecting a note
			
			[self cacheTypedStringIfNecessary:[fieldEditor string]];
			
			//add snapback-button here?
			if (!isFilteringFromTyping && !isCreatingANote)
				[field setSnapbackString:typedString];
			
			if ([self displayContentsForNoteAtIndex:selectedRow]) {
				
				[[field cell] setShowsClearButton:YES];
				
				//there doesn't seem to be any situation in which a note will be selected
				//while the user is typing and auto-completion is disabled, so should be OK

				if (!isFilteringFromTyping) {
					if ([toolbar isVisible]) {
						if (fieldEditor) {
							//the field editor has focus--select text, too
							[fieldEditor setString:titleOfNote(currentNote)];
							NSUInteger strLen = [titleOfNote(currentNote) length];
							if (strLen != [fieldEditor selectedRange].length)
								[fieldEditor setSelectedRange:NSMakeRange(0, strLen)];
						} else {
							//this could be faster
							[field setStringValue:titleOfNote(currentNote)];
						}
					} else {
						[self _setWindowTitle:titleOfNote(currentNote)];
					}
				}
			}
			return;
		}
	} else { //tags
	}
	
	if (!isFilteringFromTyping) {
		if (currentNote) {
			//selected nothing and something is currently selected
			
			[self _setCurrentNote:nil];
			[field setShowsDocumentIcon:NO];
			
			if (typedStringIsCached) {
				//restore the un-selected state, but only if something had been first selected to cause that state to be saved
				[field setStringValue:typedString];
			}
			[textView noteFindContentWillChange];
			[textView setString:@""];
		}
		[self _expandToolbar];
		
		if (!currentNote) {
			if (selectedRow == -1 && (!fieldEditor || [window firstResponder] != fieldEditor)) {
				//don't select the field if we're already there
				[window makeFirstResponder:field];
				fieldEditor = (NSTextView*)[field currentEditor];
			}
			if (fieldEditor && [fieldEditor selectedRange].length)
				[fieldEditor setSelectedRange:NSMakeRange([[fieldEditor string] length], 0)];
			
			
			//remove snapback-button from dual field here?
			[field setSnapbackString:nil];
			
			if (!numberSelected && savedSelectedNotes) {
				//savedSelectedNotes needs to be empty after de-selecting all notes, 
				//to ensure that any delayed list-resorting does not re-select savedSelectedNotes

				savedSelectedNotes = nil;
			}
		}
	}
	[self setEmptyViewState:currentNote == nil];
	[field setShowsDocumentIcon:currentNote != nil];
	[[field cell] setShowsClearButton:currentNote != nil || [[field stringValue] length]];
}

- (void)setEmptyViewState:(BOOL)state {
	BOOL enable = state;
    if (state) [textView clearFindPanel];
	[textView setHidden:enable];
	[editorStatusView setHidden:!enable];
    [self updateWordCount];
	
	if (enable) {
		[editorStatusView setLabelStatus:[notesTableView numberOfSelectedRows]];
	}
}

- (BOOL)displayContentsForNoteAtIndex:(NSInteger)noteIndex {
	NoteObject *note = [notationController noteObjectAtFilteredIndex:noteIndex];
	if (note != currentNote) {
		[self setEmptyViewState:NO];
		[field setShowsDocumentIcon:YES];
		
		//actually load the new note
		[self _setCurrentNote:note];
		
		NSRange firstFoundTermRange = NSMakeRange(NSNotFound,0);
		NSRange noteSelectionRange = [currentNote lastSelectedRange];
		
		if (noteSelectionRange.location == NSNotFound || 
			NSMaxRange(noteSelectionRange) > [[note contentString] length]) {
			//revert to the top; selection is invalid
			noteSelectionRange = NSMakeRange(0,0);
		}
		
		
		if (![textView didRenderFully]) { 
			[textView setNeedsDisplayInRect:[textView visibleRect] avoidAdditionalLayout:YES];
		}
		
		//restore string
		[textView noteFindContentWillChange];
		[[textView textStorage] setAttributedString:[note contentString]];
        if ([prefsController rightToLeftEditing]) [textView updateWritingDirection];
        [self updateWordCount];
		
		
		//highlight terms--delay this, too
		if ((unsigned)noteIndex != [notationController preferredSelectedNoteIndex])
			firstFoundTermRange = [textView highlightTermsTemporarilyReturningFirstRange:typedString avoidHighlight:
								   ![prefsController highlightSearchTerms]];
		
		//if there was nothing selected, select the first found range
		if (!noteSelectionRange.length && firstFoundTermRange.location != NSNotFound)
			noteSelectionRange = firstFoundTermRange;
		
		//select and scroll
		[textView setAutomaticallySelectedRange:noteSelectionRange];
		[textView scrollRangeToVisible:noteSelectionRange];
		
		return YES;
	}
	
	return NO;
}

//from linkingeditor
- (void)textDidChange:(NSNotification *)aNotification {
	id textObject = [aNotification object];
	
	if (textObject == textView) {
		[currentNote setContentString:[textView textStorage]];
        if (![wordCountLabel isHidden]) [self setNeedsWordCountUpdate];
	}
}

- (void)textDidBeginEditing:(NSNotification *)aNotification {
	if ([aNotification object] == textView) {
		[textView removeHighlightedTerms];
	    [self createNoteIfNecessary];
	}
}

- (void)textDidEndEditing:(NSNotification *)aNotification {
	if ([aNotification object] == textView) {
		
		//we need to set this here as we could return to searching before changing notes
		//and the next time the note would change would be when searching had triggered it
		//which would be too late
		[currentNote updateContentCacheCStringIfNecessary];
	}
}

- (NSMenu *)textView:(NSTextView *)view menu:(NSMenu *)menu forEvent:(NSEvent *)event atIndex:(NSUInteger)charIndex {
	NSInteger idx;
	if ((idx = [menu indexOfItemWithTarget:nil andAction:NSSelectorFromString(@"_removeLinkFromMenu:")]) > -1)
		[menu removeItemAtIndex:idx];
	if ((idx = [menu indexOfItemWithTarget:nil andAction:@selector(orderFrontLinkPanel:)]) > -1)
		[menu removeItemAtIndex:idx];
	return menu;
}

- (NSArray *)textView:(NSTextView *)aTextView completions:(NSArray *)words 
  forPartialWordRange:(NSRange)charRange indexOfSelectedItem:(NSInteger *)anIndex {
	
	NSArray *noteTitles = [notationController noteTitlesPrefixedByString:[[aTextView string] substringWithRange:charRange]
													 indexOfSelectedItem:anIndex];
	return noteTitles;
}


- (IBAction)fieldAction:(id)sender {
	
	[self createNoteIfNecessary];
	[window makeFirstResponder:textView];
	
}

- (NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)sender {
	
	if ([sender firstResponder] == textView) {
		if (currentNote) {
			NSLog(@"windowWillReturnUndoManager should not be called when textView is first responder");
		}
		
		NSUndoManager *undoMan = [self undoManagerForTextView:textView];
		if (undoMan) 
			return undoMan;
	}
	return windowUndoManager;
}

- (NSUndoManager *)undoManagerForTextView:(NSTextView *)aTextView {
    if (aTextView == textView && currentNote)
		return [currentNote undoManager];
    
    return nil;
}

- (NoteObject*)createNoteIfNecessary {
    
    if (!currentNote) {
		//this assertion not yet valid until labels list changes notes list
		NSAssert([notesTableView numberOfSelectedRows] != 1, @"cannot create a note when one is already selected");
		
		[textView setTypingAttributes:[prefsController noteBodyAttributes]];
		[textView setFont:[prefsController noteBodyFont]];
		
		isCreatingANote = YES;
		NSString *title = [[field stringValue] length] ? [field stringValue] : NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
		NSAttributedString *attributedContents = [textView textStorage] ? [textView textStorage] : [[NSAttributedString alloc] initWithString:@"" attributes:
																									 [prefsController noteBodyAttributes]];		
		NoteObject *note = [[NoteObject alloc] initWithNoteBody:attributedContents title:title delegate:notationController
														  format:[notationController currentNoteStorageFormat] labels:nil];
		[notationController addNewNote:note];
		
		isCreatingANote = NO;
		return note;
    }
    
    return currentNote;
}

- (void)restoreListStateUsingPreferences {
	//to be invoked after loading a notationcontroller
	
	NSString *searchString = [prefsController lastSearchString];
	if ([searchString length])
		[self searchForString:searchString];
	else
		[notationController refilterNotes];
		
	CFUUIDBytes bytes = [prefsController UUIDBytesOfLastSelectedNote];
	NSUInteger idx = [self revealNote:[notationController noteForUUIDBytes:&bytes] options:NVDoNotChangeScrollPosition];
	//scroll using saved scrollbar position
	[notesTableView scrollRowToVisible:NSNotFound == idx ? 0 : idx withVerticalOffset:[prefsController scrollOffsetOfLastSelectedNote]];
}

- (NSUInteger)revealNote:(NoteObject*)note options:(NSUInteger)opts {
	if (note) {
		NSUInteger selectedNoteIndex = [notationController indexInFilteredListForNoteIdenticalTo:note];
		
		if (selectedNoteIndex == NSNotFound) {
			NSLog(@"Note was not visible--showing all notes and trying again");
			[self cancelOperation:nil];
			
			selectedNoteIndex = [notationController indexInFilteredListForNoteIdenticalTo:note];
		}
		
		if (selectedNoteIndex != NSNotFound) {
			if (opts & NVDoNotChangeScrollPosition) { //select the note only
				[notesTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selectedNoteIndex] byExtendingSelection:NO];
			} else {
				[notesTableView selectRowAndScroll:selectedNoteIndex];
			}
		}
		
		if (opts & NVEditNoteToReveal) {
			[window makeFirstResponder:textView];
		}
		if (opts & NVOrderFrontWindow) {
			//for external url-handling, often the app will already have been brought to the foreground
			if (![NSApp isActive]) {
				[self captureActivationOrigin];
				//nv: links and scripts reveal notes from other apps, where cooperative activation can leave focus behind
				[NSApp activateIgnoringOtherApps:YES];
			}
			if (![window isKeyWindow])
				[window makeKeyAndOrderFront:nil];
		}
		return selectedNoteIndex;
	} else {
		[notesTableView deselectAll:self];
		return NSNotFound;
	}
}

- (void)notation:(NotationController*)notation revealNote:(NoteObject*)note options:(NSUInteger)opts {
	[self revealNote:note options:opts];
}

- (void)notation:(NotationController*)notation revealNotes:(NSArray*)notes {
	
	NSIndexSet *indexes = [notation indexesOfNotes:notes];
	if ([notes count] != [indexes count]) {
		[self cancelOperation:nil];
		
		indexes = [notation indexesOfNotes:notes];
	}
	if ([indexes count]) {
		[notesTableView selectRowIndexes:indexes byExtendingSelection:NO];
		[notesTableView scrollRowToVisible:[indexes firstIndex]];
	}
}

- (void)searchForString:(NSString*)string {
	
	if (string) {
		
		//problem: this won't work when the toolbar (and consequently the searchfield) is hidden;
		//and neither will the controlTextDidChange implementation
		[self _expandToolbar];
		
		[window makeFirstResponder:field];
		NSTextView* fieldEditor = (NSTextView*)[field currentEditor];
		NSRange fullRange = NSMakeRange(0, [[fieldEditor string] length]);
		if ([fieldEditor shouldChangeTextInRange:fullRange replacementString:string]) {
			[fieldEditor replaceCharactersInRange:fullRange withString:string];
			[fieldEditor didChangeText];
		} else {
			NSLog(@"I shouldn't change text?");
		}
	}
}

- (void)bookmarksController:(BookmarksController*)controller restoreNoteBookmark:(NoteBookmark*)aBookmark inBackground:(BOOL)inBG {
	if (aBookmark) {
		[self searchForString:[aBookmark searchString]];
		[self revealNote:[aBookmark noteObject] options:!inBG ? NVOrderFrontWindow : 0];
	}
}



- (void)splitViewWillTrackDivider:(NVSplitView *)sender {
	//if upon the first mousedown, the top selected index is visible, snap to it when resizing
	[notesTableView noteFirstVisibleRow];
}

- (void)splitViewDidDoubleClickDivider:(NVSplitView *)sender {
	[self toggleCollapse:sender];
}

- (CGFloat)splitView:(NSSplitView *)sender constrainMinCoordinate:(CGFloat)proposedMin ofSubviewAt:(NSInteger)dividerIndex {
	return proposedMin + ([prefsController horizontalLayout] ? 100.0 : 60.0);
}

- (CGFloat)splitView:(NSSplitView *)sender constrainMaxCoordinate:(CGFloat)proposedMax ofSubviewAt:(NSInteger)dividerIndex {
	return proposedMax - 100.0;
}

//window resizing goes to the editor while it has room, as the notes list keeps the size the user chose
- (BOOL)splitView:(NSSplitView *)sender shouldAdjustSizeOfSubview:(NSView *)subview {
	if (subview != [[sender subviews] firstObject]) return YES;
	NSSize size = [sender bounds].size;
	CGFloat listSize = [sender isVertical] ? NSWidth([subview frame]) : NSHeight([subview frame]);
	return ([sender isVertical] ? size.width : size.height) - listSize - [sender dividerThickness] < 100.0;
}

//mail.app-like resizing behavior wrt item selections
- (void)splitViewDidResizeSubviews:(NSNotification *)notification {
	//problem: don't do this if the horizontal splitview is being resized; in horizontal layout, only do this when resizing the window
	if (![prefsController horizontalLayout]) {
		[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];
	}
}

- (NSSize)windowWillResize:(NSWindow *)window toSize:(NSSize)proposedFrameSize {
	if ([prefsController horizontalLayout]) {
		[notesTableView makeFirstPreviouslyVisibleRowVisibleIfNecessary];
	}
	return proposedFrameSize;
}

//full screen's own switch to the widescreen layout is undone on exit unless the user has chosen a layout since
- (void)_setFullScreenSwitchedLayout:(BOOL)switched {
    fullScreenSwitchedLayout = switched;
    if (switched) [[NSUserDefaults standardUserDefaults] setBool:YES forKey:NVFullScreenSwitchedLayoutKey];
    else [[NSUserDefaults standardUserDefaults] removeObjectForKey:NVFullScreenSwitchedLayoutKey];
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
    fullScreenSearchVisible = [toolbar isVisible];
    fullScreenEditorFocused = [window firstResponder] == textView;
    if (![prefsController horizontalLayout]) {
        [self switchViewLayout:self];
        [self _setFullScreenSwitchedLayout:YES];
    }
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
    [toolbar setVisible:fullScreenSearchVisible];
    [textView updateTextWidth];
    if (fullScreenEditorFocused) [window makeFirstResponder:textView];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification {
    if (fullScreenSwitchedLayout && [prefsController horizontalLayout])
        [self switchViewLayout:self];
    [self _setFullScreenSwitchedLayout:NO];
    [toolbar setVisible:fullScreenSearchVisible];
    [textView updateTextWidth];
    if (fullScreenEditorFocused) [window makeFirstResponder:textView];
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)failedWindow {
    [self windowDidExitFullScreen:[NSNotification notificationWithName:NSWindowDidExitFullScreenNotification object:failedWindow]];
}

- (void)_expandToolbar {
    [splitView setLeadingPaneCollapsed:NO];
    if (![toolbar isVisible]) {
        [self _setWindowTitle:NSLocalizedString(@"Notation", @"window title when no note is selected")];
        [window toggleToolbarShown:nil];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"ToolbarHidden"];
    }
}

- (void)_collapseToolbar {
	if ([toolbar isVisible]) {
		if (currentNote)
			[self _setWindowTitle:titleOfNote(currentNote)];
		[window toggleToolbarShown:nil];
		[[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"ToolbarHidden"];
	}
}

- (void)tableViewColumnDidResize:(NSNotification *)aNotification {
	NoteAttributeColumn *col = [[aNotification userInfo] objectForKey:@"NSTableColumn"];
	if ([[col identifier] isEqualToString:NoteTitleColumnString]) {
		[notationController regeneratePreviewsForColumn:col visibleFilteredRows:[notesTableView rowsInRect:[notesTableView visibleRect]] forceUpdate:NO];
		
	 	[NSObject cancelPreviousPerformRequestsWithTarget:notesTableView selector:@selector(reloadDataIfNotEditing) object:nil];
		[notesTableView performSelector:@selector(reloadDataIfNotEditing) withObject:nil afterDelay:0.0];
	}
}

- (BOOL)splitView:(NSSplitView *)sender canCollapseSubview:(NSView *)subview {
	return subview == [[sender subviews] firstObject] && currentNote != nil;
}

- (IBAction)toggleCollapse:(id)sender {
	if ([splitView isLeadingPaneCollapsed]) [splitView setLeadingPaneCollapsed:NO];
	else if (currentNote) [splitView setLeadingPaneCollapsed:YES];
}

- (void)splitView:(NVSplitView *)sender leadingPaneDidCollapse:(BOOL)collapsed {
	if (changingViewLayout) return;
	if (collapsed) {
		[self _collapseToolbar];
		[window makeFirstResponder:textView];
	} else {
		[self _expandToolbar];
	}
	[self updateNoteMenus];
}


//the notationcontroller must call notationListShouldChange: first 
//if it's going to do something that could mess up the tableview's field eidtor
- (BOOL)notationListShouldChange:(NotationController*)someNotation {
	
	if (someNotation == notationController) {
		if ([notesTableView currentEditor])
			return NO;
	}
	
	return YES;
}

- (void)notationListMightChange:(NotationController*)someNotation {
	
	if (!isFilteringFromTyping) {
		if (someNotation == notationController) {
			//deal with one notation at a time
			
			if ([notesTableView numberOfSelectedRows] > 0) {
				NSIndexSet *indexSet = [notesTableView selectedRowIndexes];
					
				savedSelectedNotes = [someNotation notesAtIndexes:indexSet];
			}
			
			listUpdateViewCtx = [notesTableView viewingLocation];
		}
	}
}

- (void)notationListDidChange:(NotationController*)someNotation {
	
	if (someNotation == notationController) {
		//deal with one notation at a time

		[notesTableView reloadData];
		
		if (!isFilteringFromTyping) {
			if (savedSelectedNotes) {
				NSIndexSet *indexes = [someNotation indexesOfNotes:savedSelectedNotes];
				savedSelectedNotes = nil;
				
				[notesTableView selectRowIndexes:indexes byExtendingSelection:NO];
			}
			
			[notesTableView setViewingLocation:listUpdateViewCtx];
		}
	}
}

- (void)titleUpdatedForNote:(NoteObject*)aNoteObject {
    if (aNoteObject == currentNote) {
		if ([toolbar isVisible]) {
			[field setStringValue:titleOfNote(currentNote)];
		} else {
			[self _setWindowTitle:titleOfNote(currentNote)];
		}
    }
	[[prefsController bookmarksController] updateBookmarksUI];
}

- (void)contentsUpdatedForNote:(NoteObject*)aNoteObject {
	if (aNoteObject == currentNote) {
		
		[textView noteFindContentWillChange];
        [[textView textStorage] setAttributedString:[aNoteObject contentString]];
        [self updateWordCount];
	}
}

- (void)rowShouldUpdate:(NSInteger)affectedRow {
	NSRect rowRect = [notesTableView rectOfRow:affectedRow];
	NSRect visibleRect = [notesTableView visibleRect];
	
	if (NSContainsRect(visibleRect, rowRect) || NSIntersectsRect(visibleRect, rowRect)) {
		[notesTableView setNeedsDisplayInRect:rowRect];
	}
}

- (IBAction)fixFileEncoding:(id)sender {
	if (currentNote) {
		[notationController synchronizeNoteChanges:nil];
		
		[[EncodingsManager sharedManager] showPanelForNote:currentNote];
	}
}

- (void)windowWillClose:(NSNotification *)aNotification {
    if ([prefsController quitWhenClosingWindow])
		[NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {	
	if (notationController) {
		//only save the state if the notation instance has actually loaded; i.e., don't save last-selected-note if we quit from a PW dialog
		BOOL wasAutomatic = NO;
		NSRange currentRange = [textView selectedRangeWasAutomatic:&wasAutomatic];
		if (!wasAutomatic) [currentNote setSelectedRange:currentRange];
		
		[currentNote updateContentCacheCStringIfNecessary];
		
		[prefsController setLastSearchString:[self fieldSearchString] selectedNote:currentNote 
					scrollOffsetForTableView:notesTableView sender:self];
		
		[prefsController saveCurrentBookmarksFromSender:self];
	}
	
	[[NSApp windows] makeObjectsPerformSelector:@selector(close)];
	[notationController stopFileNotifications];
	
    if ([notationController flushAllNoteChanges])
		[notationController closeJournal];
	else
		NSLog(@"Could not flush database, so not removing journal");
	
    [self _saveNotesListLayout];
    [prefsController synchronize];
}

- (void)dealloc {
    if (statusItem) [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
    if (modifierMonitor) [NSEvent removeMonitor:modifierMonitor];
	
}

- (IBAction)showPreferencesWindow:(id)sender {
	[prefsWindowController showWindow:sender];
}

- (IBAction)toggleNVActivation:(id)sender {
	
	if ([NSApp isActive] && [window isMainWindow]) {
		if (!activatedFromAnotherSpace || [previousActiveApplication isTerminated] ||
			![previousActiveApplication activateWithOptions:0]) {
			[NSApp hide:sender];
		}
		previousActiveApplication = nil;
		activatedFromAnotherSpace = NO;
		return;
	}
	[self bringFocusToControlField:sender];
}

- (IBAction)bringFocusToControlField:(id)sender {
    pendingSearchFocus = YES;
	[self _expandToolbar];
	
	if (![NSApp isActive]) {
		[self captureActivationOrigin];
		//the hot key and menu bar icon must take focus from the frontmost app, which cooperative activation can decline
		[NSApp activateIgnoringOtherApps:YES];
	}
	if (![window isMainWindow]) [window makeKeyAndOrderFront:sender];
	
	[self setEmptyViewState:currentNote == nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(selectSearchAfterActivation) object:nil];
    if ([NSApp isActive] && window.isKeyWindow) [self selectSearchAfterActivation];
    else [self performSelector:@selector(selectSearchAfterActivation) withObject:nil afterDelay:0];
}

- (void)selectSearchAfterActivation {
    if (pendingSearchFocus && [NSApp isActive] && window.isKeyWindow) {
        pendingSearchFocus = NO;
        [field selectText:nil];
    }
}

- (void)captureActivationOrigin {
	previousActiveApplication = [[NSWorkspace sharedWorkspace] frontmostApplication];
	activatedFromAnotherSpace = ![window isOnActiveSpace];
	activationRequested = YES;
}

- (NSWindow*)window {
	return window;
}

@end
