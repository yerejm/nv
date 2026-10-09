#import "AppController_Importing.h"
#import "AppController.h"
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


#import "PrefsWindowController.h"
#import "NotationPrefsViewController.h"
#import "ExternalEditorListController.h"
#import "NSData_transformations.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"
#import "NSBezierPath_NV.h"
#import "NotationPrefs.h"
#import "GlobalPrefs.h"

#define SYSTEM_LIST_FONT_SIZE 12.0f

@implementation PrefsWindowController

- (id)init {
    if ((self = [super init])) {
		prefsController = [GlobalPrefs defaultPrefs];
		fontPanelWasOpen = NO;
		
		[prefsController registerWithTarget:self forChangesInSettings:
		 @selector(resolveNoteBodyFontFromNotationPrefsFromSender:), 
		 @selector(setCheckSpellingAsYouType:sender:), 
		 @selector(setConfirmNoteDeletion:sender:),
         @selector(setUseSmartQuotes:sender:), @selector(setUseSmartDashes:sender:), @selector(setUseSmartInsertDelete:sender:),
         @selector(setShowDockIcon:sender:), @selector(setShowMenuBarIcon:sender:), nil];
    }
    return self;
}

- (void)showWindow:(id)sender {
	if (!window) {
		if (!NVLoadNib(@"Preferences", self))  {
			NSLog(@"Failed to load Preferences.nib");
			return;
		}
	}
	
	if (![window isVisible])
		[window center];
	
	[window makeKeyAndOrderFront:self];
}

- (void)windowWillClose:(NSNotification *)aNotification {
	[prefsController performSelector:@selector(synchronize) withObject:nil afterDelay:0.0];
	
	[[NSFontPanel sharedFontPanel] close];
}
- (void)windowDidResignMain:(NSNotification *)aNotification {
	//hide the font panel--don't want to confuse people into thinking it will affect some other part of the program
	fontPanelWasOpen = [[NSFontPanel sharedFontPanel] isVisible];
	[[NSFontPanel sharedFontPanel] orderOut:nil];
}
- (void)windowDidBecomeMain:(NSNotification *)aNotification {
	if (fontPanelWasOpen) {
		[self changeBodyFont:self];
	}
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
	NSLog(@"I need an update: %@", [menu description]);
}

- (BOOL)shortcutRecorder:(NVShortcutRecorder *)recorder shouldChangeToKeyCode:(NSInteger)keyCode carbonModifiers:(NSUInteger)modifiers {
	return [prefsController setAppActivationKeyCode:keyCode modifiers:modifiers sender:self];
}

//so pressing the current shortcut records it instead of hiding the app
- (void)shortcutRecorderDidBeginRecording:(NVShortcutRecorder *)recorder {
	[prefsController setAppActivationShortcutSuspended:YES];
}

- (void)shortcutRecorderDidEndRecording:(NVShortcutRecorder *)recorder {
	[prefsController setAppActivationShortcutSuspended:NO];
}

- (IBAction)changeBodyFont:(id)sender {
	[[NSFontManager sharedFontManager] setSelectedFont:[prefsController noteBodyFont] isMultiple:NO];
    [[NSFontManager sharedFontManager] orderFrontFontPanel:self];
}

- (void)changeFont:(id)sender {
	NSFontManager *fontMan = [NSFontManager sharedFontManager];
	NSFont *panelFont = [fontMan convertFont:[fontMan selectedFont]];
	
	if (([fontMan traitsOfFont:panelFont] & NSItalicFontMask) == NSItalicFontMask ||
	([fontMan traitsOfFont:panelFont] & NSBoldFontMask) == NSBoldFontMask) {
		//revert the font--using a bold or italic variant as the default could cause some notes to lose styles
		
		[self performSelector:@selector(changeBodyFont:) withObject:sender afterDelay:0.0];
		NSBeep();
	} else {
		[prefsController setNoteBodyFont:panelFont sender:self];
	
		[self previewNoteBodyFont];
	}
}

- (NSFontPanelModeMask)validModesForFontPanel:(NSFontPanel *)fontPanel {
	
	return NSFontPanelSizeModeMask | NSFontPanelCollectionModeMask;
}

- (void)previewNoteBodyFont {

	if (!centerStyle) {
		centerStyle = [[NSMutableParagraphStyle alloc] init];
		[centerStyle setAlignment:NSTextAlignmentCenter];
	}

	NSFont *font = [prefsController noteBodyFont];
	NSDictionary *attributes = [NSDictionary dictionaryWithObjectsAndKeys:font ? font : [NSFont systemFontOfSize:12.0],
		NSFontAttributeName, [NSColor textColor], NSForegroundColorAttributeName, centerStyle, NSParagraphStyleAttributeName, nil];

	NSString *fontNameAndSize = font ? [NSString stringWithFormat:@"%@ %g", [font displayName], [font pointSize]] : @"Unknown";
	NSAttributedString *attributedString = [[NSAttributedString alloc] initWithString:fontNameAndSize attributes:attributes];
	
	[[bodyTextFontField cell] setAttributedStringValue:attributedString];
    [bodyTextFontField updateCell:[bodyTextFontField cell]];
	
	[attributedString autorelease];
	
}

//changing the scheme re-sends both colors to every observer, so a dragged color well should only do it once
- (void)_selectCustomColorScheme {
    if ([prefsController colorScheme] != 3) [prefsController setColorScheme:3 sender:self];
    [colorSchemeButton selectItemAtIndex:3];
}

- (IBAction)changedBackgroundTextColorWell:(id)sender {
	[self _selectCustomColorScheme];
	[prefsController setBackgroundTextColor:[backgroundColorWell color] sender:self];
}

- (IBAction)changedTextWidth:(id)sender {
    [prefsController setMaxNoteBodyWidth:round([textWidthSlider doubleValue]) sender:self];
    [textWidthLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Maximum text width: %.0f pt", nil), [prefsController maxNoteBodyWidth]]];
}

- (IBAction)changedTextWidthLimit:(id)sender {
    [prefsController setManagesTextWidthInWindow:[sender state] == NSControlStateValueOn sender:self];
}
- (IBAction)changedForegroundTextColorWell:(id)sender {
	[self _selectCustomColorScheme];
	[prefsController setForegroundTextColor:[foregroundColorWell color] sender:self];
}

- (IBAction)changedColorScheme:(id)sender {
    [prefsController setColorScheme:[sender indexOfSelectedItem] sender:self];
}
- (IBAction)changedAlternatingRows:(id)sender {
    [prefsController setAlternatingRows:[sender state] == NSControlStateValueOn sender:self];
}
- (IBAction)changedNoteListGrid:(id)sender {
    [prefsController setShowNoteListGrid:[sender state] == NSControlStateValueOn sender:self];
}
- (IBAction)changedThemedScrollbars:(id)sender {
    [prefsController setUseThemedScrollbars:[sender state] == NSControlStateValueOn sender:self];
}
- (IBAction)changedAutoPairing:(id)sender {
    [prefsController setUseAutoPairing:[sender state] == NSControlStateValueOn sender:self];
}
- (IBAction)changedDesktopPresence:(id)sender {
    BOOL enabled = [sender state] == NSControlStateValueOn;
    if (sender == showDockIconButton) [prefsController setShowDockIcon:enabled sender:self];
    else [prefsController setShowMenuBarIcon:enabled sender:self];
    [showDockIconButton setState:[prefsController showDockIcon]];
    [showMenuBarIconButton setState:[prefsController showMenuBarIcon]];
}
- (IBAction)changedSmartSubstitutions:(id)sender {
    BOOL enabled = [sender state] == NSControlStateValueOn;
    if (sender == smartQuotesButton) [prefsController setUseSmartQuotes:enabled sender:self];
    else if (sender == smartDashesButton) [prefsController setUseSmartDashes:enabled sender:self];
    else [prefsController setUseSmartInsertDelete:enabled sender:self];
}
- (IBAction)changedWritingDirection:(id)sender {
    [prefsController setRightToLeftEditing:[sender state] == NSControlStateValueOn sender:self];
}
- (IBAction)changedSearchHighlightColorWell:(id)sender {
	[prefsController setSearchTermHighlightColor:[searchHighlightColorWell color] sender:self];
	[systemHighlightColorButton setEnabled:YES];
}
- (IBAction)useSystemSearchHighlightColor:(id)sender {
	[prefsController useSystemSearchTermHighlightColorFromSender:self];
	[searchHighlightColorWell setColor:[prefsController searchTermHighlightColorRaw:YES]];
	[systemHighlightColorButton setEnabled:NO];
}
- (IBAction)changedHighlightSearchTerms:(id)sender {
	[prefsController setShouldHighlightSearchTerms:[highlightSearchTermsButton state] sender:self];
}
- (IBAction)changedStyledTextBehavior:(id)sender {
    [prefsController setPastePreservesStyle:[styledTextButton state] sender:self];
}
- (IBAction)changedAutoSuggestLinks:(id)sender {
    [prefsController setLinksAutoSuggested:[autoSuggestLinksButton state] sender:self];
}

- (IBAction)changedMakeURLsClickable:(id)sender {
	[prefsController setMakeURLsClickable:[makeURLsClickable state] sender:self];
}

- (IBAction)changedNoteDeletion:(id)sender {
	[prefsController setConfirmNoteDeletion:[confirmDeletionButton state] sender:self];
}

- (IBAction)changedNotesFolderLocation:(id)sender {
    NSLog(@"Changed notes folder menu");
}

- (IBAction)changedQuitBehavior:(id)sender {
    [prefsController setQuitWhenClosingWindow:[quitWhenClosingButton state] sender:self];
}

- (IBAction)changedSpellChecking:(id)sender {
    [prefsController setCheckSpellingAsYouType:[checkSpellingButton state] sender:self];
}


- (IBAction)changedTabBehavior:(id)sender {
    if (sender != self)
	[self performSelector:@selector(changedTabBehavior:) withObject:self afterDelay:0.0];
    else
	[prefsController setTabIndenting:[[tabKeyRadioMatrix cellAtRow:0 column:0] state] sender:self];
}

- (IBAction)changedExternalEditorsMenu:(id)sender {
	//not currently called as an action in practice
	[self _selectDefaultExternalEditor];
}

- (void)_selectDefaultExternalEditor {
	ExternalEditor *ed = [[ExternalEditorListController sharedInstance] defaultExternalEditor];
	NSInteger idx = ed ? [externalEditorMenuButton indexOfItemWithRepresentedObject:ed] : 0;
	if (idx > -1) {
		[externalEditorMenuButton selectItemAtIndex:idx];
	}
}

- (IBAction)changedTableText:(id)sender {
	if (sender == tableTextMenuButton) {
		if ([tableTextSizeField selectedTag] != 3) [tableTextSizeField setFloatValue:[prefsController tableFontSize]];
		[self performSelector:@selector(changedTableText:) withObject:nil afterDelay:0.0];
	} else {
		[window makeFirstResponder:window];
		float newFontSize = 0.0;
		switch ([tableTextMenuButton selectedTag]) {
			case 1:
				newFontSize = [NSFont smallSystemFontSize];
				break;
			case 2:
				newFontSize = /*[NSFont systemFontSize]*/ SYSTEM_LIST_FONT_SIZE;
				break;
			case 3:
				newFontSize = [tableTextSizeField floatValue];
		}
		[tableTextSizeField setHidden:([tableTextMenuButton selectedTag] != 3)];
		if (![tableTextSizeField isHidden])
			[tableTextSizeField selectText:sender];
		
		[prefsController setTableFontSize:newFontSize sender:self];
	}	
}

- (IBAction)changedTitleCompletion:(id)sender {
    [prefsController setAutoCompleteSearches:[completeNoteTitlesButton state] sender:self];
}

- (IBAction)changedSoftTabs:(id)sender {
	[prefsController setSoftTabs:[softTabsButton state] sender:self];
}

- (void)settingChangedForSelectorString:(NSString*)selectorString {
    [showDockIconButton setState:[prefsController showDockIcon]];
    [showMenuBarIconButton setState:[prefsController showMenuBarIcon]];
    [smartQuotesButton setState:[prefsController useSmartQuotes]];
    [smartDashesButton setState:[prefsController useSmartDashes]];
    [smartInsertDeleteButton setState:[prefsController useSmartInsertDelete]];
    if ([selectorString isEqualToString:SEL_STR(resolveNoteBodyFontFromNotationPrefsFromSender:)]) {
		[self previewNoteBodyFont];
	} else if ([selectorString isEqualToString:SEL_STR(setCheckSpellingAsYouType:sender:)]) {
		[checkSpellingButton setState:[prefsController checkSpellingAsYouType]];
	} else if ([selectorString isEqualToString:SEL_STR(setConfirmNoteDeletion:sender:)]) {
		[confirmDeletionButton setState:[prefsController confirmNoteDeletion]];
	}
}

- (NSMenu*)directorySelectionMenu {
    NSMenu *theMenu = [[[NSMenu alloc] initWithTitle:@"Note Directory Menu"] autorelease];
    
    NVFileReference targetRef = {{0}};
    NSString *name = [prefsController displayNameForDefaultDirectoryWithFSRef:&targetRef];
    if (!name)
		name = NSLocalizedString(@"<Directory unknown>", nil);
	
	NSImage *iconImage = nil;
	if (!IsZeros(&targetRef, sizeof(NVFileReference)) || [[prefsController aliasDataForDefaultDirectory] fsRefAsAlias:&targetRef])
		iconImage = [NSImage smallIconForFSRef:&targetRef];
	
    NSMenuItem *theMenuItem = [[[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""] autorelease];
    
    if (iconImage)
		[theMenuItem setImage:iconImage];
    
    [theMenu addItem:theMenuItem];
    
    [theMenu addItem:[NSMenuItem separatorItem]];
    
    theMenuItem = [[[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Other...", @"title of menu item for selecting a different notes folder")
											  action:@selector(changeDefaultDirectory) keyEquivalent:@""] autorelease];
    [theMenuItem setTarget:self];
    [theMenu addItem:theMenuItem];
    
    return theMenu;
}

- (void)changeDefaultDirectory {
	NVFileReference notesDirectoryRef;
	NSData *aliasData = nil;
	NSString *directoryPath = nil;

	if ([self getNewNotesRefFromOpenPanel:&notesDirectoryRef returnedPath:&directoryPath]) {
		
		//make sure we're not choosing the same folder as what we started with, because:
		//-[NotationController initWithAliasData:] might attempt to initialize journaling, which will already be in use
		NVFileReference currentNotesDirectoryRef;
		[[prefsController aliasDataForDefaultDirectory] fsRefAsAlias:&currentNotesDirectoryRef];
		if (NVCompareReferences(&notesDirectoryRef, &currentNotesDirectoryRef) != noErr) {
			
			if ((aliasData = [NSData aliasDataForFSRef:&notesDirectoryRef])) {
				[prefsController setAliasDataForDefaultDirectory:aliasData sender:self];
				
			}
		} else {
			NSLog(@"This folder is already chosen!");
		}
		
	}

	[folderLocationsMenuButton setMenu:[self directorySelectionMenu]];

	if ([folderLocationsMenuButton numberOfItems] > 0)
		[folderLocationsMenuButton selectItemAtIndex:0];
}

- (BOOL)getNewNotesRefFromOpenPanel:(NVFileReference*)notesDirectoryRef returnedPath:(NSString**)path {
    NSString *startingDirectory = nil;
	
    if (!notesDirectoryRef) {
		NSLog(@"notesDirectoryRef is NULL!");
		return NO;
    }
    
    NVFileReference currentNotesDirectoryRef;
    //resolve alias to fsref; get path from fsref
    if ([[prefsController aliasDataForDefaultDirectory] fsRefAsAlias:&currentNotesDirectoryRef]) {
		NSString *resolvedPath = [[NSFileManager defaultManager] pathWithFSRef:&currentNotesDirectoryRef];
		if (resolvedPath) startingDirectory = resolvedPath;
    }
    
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    [openPanel setCanCreateDirectories:YES];
    [openPanel setCanChooseFiles:NO];
    [openPanel setCanChooseDirectories:YES];
    [openPanel setResolvesAliases:YES];
    [openPanel setAllowsMultipleSelection:NO];
    [openPanel setTreatsFilePackagesAsDirectories:NO];
    [openPanel setTitle:NSLocalizedString(@"Select a folder",@"title of open panel for selecting a notes folder")];
    [openPanel setPrompt:NSLocalizedString(@"Select", @"title of open panel button to select a folder")];
    [openPanel setMessage:NSLocalizedString(@"Select the folder that Notational Velocity should use for reading and storing notes.",nil)];
    
    if (NVRunOpenPanel(openPanel, startingDirectory, @"Notational Data", nil) == NSModalResponseOK) {
		CFStringRef filename = (CFStringRef)[[openPanel URL] path];
		if (!filename)
			return NO;
		
		if (path)
			*path = [[[[openPanel URL] path] copy] autorelease];
		
		//yes, I know that navigation services uses uses FSRefs, but NSSavePanel saves us much more work
		CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, filename, kCFURLPOSIXPathStyle, true);
		[(id)url autorelease];
		if (!url || !NVURLGetFileReference(url, notesDirectoryRef))
			return NO;
		
		return YES;
    }
    
    return NO;
}

- (NotationPrefsViewController*)notationPrefsViewController {
	if (!notationPrefsViewController) {
		notationPrefsViewController = [[NotationPrefsViewController alloc] init];
	}
	return notationPrefsViewController;
}

- (NSView*)databaseView {
    NSView *notesView = [[self notationPrefsViewController] view];
    if (notesView && ![notesView superview]) NVEmbedView(notesView, notationPrefsView);
	
    return databaseView;
}

- (void)addToolbarItemWithName:(NSString*)name {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:name];
	
	NSString *localizedTitle = [[NSBundle mainBundle] localizedStringForKey:name value:@"" table:nil];
    [item setPaletteLabel:localizedTitle];
    [item setLabel:localizedTitle];
    NSString *symbol = @{@"General": @"gearshape", @"Notes": @"folder", @"Editing": @"pencil", @"Fonts & Colors": @"textformat",
                         @"Display": @"rectangle.split.2x1", @"Writing": @"text.cursor", @"Desktop": @"menubar.dock.rectangle"}[name];
    [item setImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:localizedTitle]];
    [item setTarget:self];
    [item setAction:@selector(switchViews:)];
    [items setObject:item forKey:name];
    [item release];
}

- (void)awakeFromNib {
    [showDockIconButton setState:[prefsController showDockIcon]];
    [showMenuBarIconButton setState:[prefsController showMenuBarIcon]];
    [autoPairingButton setState:[prefsController useAutoPairing]];
    [rightToLeftButton setState:[prefsController rightToLeftEditing]];
    [smartQuotesButton setState:[prefsController useSmartQuotes]];
    [smartDashesButton setState:[prefsController useSmartDashes]];
    [smartInsertDeleteButton setState:[prefsController useSmartInsertDelete]];
    [limitTextWidthButton setState:[prefsController managesTextWidthInWindow]];
    [textWidthSlider setDoubleValue:[prefsController maxNoteBodyWidth]];
    [textWidthSlider setAccessibilityLabel:NSLocalizedString(@"Maximum text width", nil)];
    [self changedTextWidth:textWidthSlider];
    [colorSchemeButton selectItemAtIndex:[prefsController colorScheme]];
    [colorSchemeButton setAccessibilityLabel:NSLocalizedString(@"Interface colors", nil)];
    [alternatingRowsButton setState:[prefsController alternatingRows]];
    [noteListGridButton setState:[prefsController showNoteListGrid]];
    [themedScrollbarsButton setState:[prefsController useThemedScrollbars]];
	
	[window setDelegate:self];
	
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changedTableText:)
												 name:NSControlTextDidEndEditingNotification object:tableTextSizeField];
    
    [tabKeyRadioMatrix setState:[prefsController tabKeyIndents] atRow:0 column:0];
    [tabKeyRadioMatrix setState:![prefsController tabKeyIndents] atRow:1 column:0];
    
    float fontSize = [prefsController tableFontSize];
    int fontButtonIndex = 3;
    if (fontSize == [NSFont smallSystemFontSize]) fontButtonIndex = 0;
    else if (fontSize == /*[NSFont systemFontSize]*/ SYSTEM_LIST_FONT_SIZE) fontButtonIndex = 1;
    [tableTextMenuButton selectItemAtIndex:fontButtonIndex];
    [tableTextSizeField setFloatValue:fontSize];
    [tableTextSizeField setHidden:(fontButtonIndex != 3)];
    
	[externalEditorMenuButton setMenu:[[ExternalEditorListController sharedInstance] addEditorPrefsMenu]];
	[self _selectDefaultExternalEditor];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(changedExternalEditorsMenu:) 
												 name:ExternalEditorsChangedNotification object:nil];
	
    [completeNoteTitlesButton setState:[prefsController autoCompleteSearches]];
    [checkSpellingButton setState:[prefsController checkSpellingAsYouType]];
    [confirmDeletionButton setState:[prefsController confirmNoteDeletion]];
    [quitWhenClosingButton setState:[prefsController quitWhenClosingWindow]];
    [styledTextButton setState:[prefsController pastePreservesStyle]];
    [autoSuggestLinksButton setState:[prefsController linksAutoSuggested]];
	[softTabsButton setState:[prefsController softTabs]];
	[makeURLsClickable setState:[prefsController URLsAreClickable]];
    [bodyTextFontField setBackgroundColor:[NSColor textBackgroundColor]];
    [self previewNoteBodyFont];
	[appShortcutRecorder setKeyCode:[prefsController appActivationKeyCode] carbonModifiers:[prefsController appActivationModifiers]];
	[searchHighlightColorWell setColor:[prefsController searchTermHighlightColorRaw:YES]];
	[systemHighlightColorButton setEnabled:[prefsController searchTermHighlightColorIsCustom]];
	[highlightSearchTermsButton setState:[prefsController highlightSearchTerms]];
	[foregroundColorWell setColor:[prefsController foregroundTextColor]];
	[backgroundColorWell setColor:[prefsController backgroundTextColor]];
    
    items = [[NSMutableDictionary alloc] init];
    
    [self addToolbarItemWithName:@"General"];
    [self addToolbarItemWithName:@"Notes"];	
    [self addToolbarItemWithName:@"Editing"];
	[self addToolbarItemWithName:@"Fonts & Colors"];
    [self addToolbarItemWithName:@"Display"];
    [self addToolbarItemWithName:@"Writing"];
    [self addToolbarItemWithName:@"Desktop"];
		
    toolbar = [[NSToolbar alloc] initWithIdentifier:@"preferencePanes"];
    [toolbar setDelegate:self];
    [toolbar setAllowsUserCustomization:NO];
    [toolbar setAutosavesConfiguration:NO]; 
    [toolbar setDisplayMode:NSToolbarDisplayModeIconAndLabel];
    [window setToolbarStyle:NSWindowToolbarStylePreference];
    [window setToolbar:toolbar];
    [toolbar release];  //setToolbar retains the toolbar we pass, so release the one we used.


    CGFloat toolbarWidth = 40;
    NSDictionary *labelAttributes = @{NSFontAttributeName: [NSFont systemFontOfSize:12]};
    for (NSToolbarItem *item in toolbar.items)
        toolbarWidth += MAX(64, ceil([item.label sizeWithAttributes:labelAttributes].width) + 24);
    NSSize contentSize = NSMakeSize(MAX(640, toolbarWidth), 0);
    for (NSView *pane in @[generalView, [self databaseView], editingView, fontsColorsView, displayView, writingView, desktopView]) {
        if ([[pane constraints] count]) [pane setFrameSize:[pane fittingSize]];
        contentSize.width = MAX(contentSize.width, NSWidth(pane.frame));
        contentSize.height = MAX(contentSize.height, NSHeight(pane.frame));
    }
    paneContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, contentSize.width, contentSize.height)];
    [window setContentView:paneContainer];
    [paneContainer release];
    [window setContentMinSize:contentSize];
    [window setContentSize:contentSize];

    [self switchViews:nil];  //select last selected pane by default
    
}


- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSString *)itemIdentifier willBeInsertedIntoToolbar:(BOOL)flag {
    return [items objectForKey:itemIdentifier];
}

- (NSArray *)toolbarAllowedItemIdentifiers:(NSToolbar*)theToolbar {
    return [self toolbarDefaultItemIdentifiers:theToolbar];
}

- (NSArray *)toolbarDefaultItemIdentifiers:(NSToolbar*)theToolbar {
    return [NSArray arrayWithObjects:@"General", @"Notes", @"Editing", @"Fonts & Colors", @"Display", @"Writing", @"Desktop", nil];
}

- (NSArray *)toolbarSelectableItemIdentifiers: (NSToolbar *)toolbar {
    //make all of them selectable. This puts that little grey outline thing around an item when you select it.
    return [items allKeys];
}

- (void)switchViews:(NSToolbarItem *)item {
    NSString *sender = nil;
	
    if (item == nil) {
        sender = [prefsController lastSelectedPreferencesPane];
    } else {
        sender = [item itemIdentifier];
		[prefsController setLastSelectedPreferencesPane:sender sender:self];
    }
    [toolbar setSelectedItemIdentifier:sender];
	
    NSView *prefsView = nil;
	
    [window setTitle:[[NSBundle mainBundle] localizedStringForKey:sender value:@"" table:nil]];
	
    if ([sender isEqualToString:@"General"]){
         prefsView = generalView;
    } else if([sender isEqualToString:@"Notes"]) {
        prefsView = [self databaseView];
    } else if([sender isEqualToString:@"Editing"]) {
        prefsView = editingView;
    } else if([sender isEqualToString:@"Fonts & Colors"]) {
        prefsView = fontsColorsView;
    } else if ([sender isEqualToString:@"Display"]) {
        prefsView = displayView;
    } else if ([sender isEqualToString:@"Writing"]) {
        prefsView = writingView;
    } else if ([sender isEqualToString:@"Desktop"]) {
        prefsView = desktopView;
	} else {
		NSLog(@"unknown sender: %@", sender);
	}
    
    if (prefsView == databaseView)
		[folderLocationsMenuButton setMenu:[self directorySelectionMenu]];
	
	NSAssert(prefsView != nil, @"switching to a nil prefs view!");
    
	[[NSFontPanel sharedFontPanel] close];

    [window makeFirstResponder:nil];
    for (NSView *pane in [[paneContainer.subviews copy] autorelease])
        [pane removeFromSuperview];
    [prefsView setFrameOrigin:NSMakePoint(floor((NSWidth(paneContainer.bounds) - NSWidth(prefsView.frame)) / 2),
                                        NSHeight(paneContainer.bounds) - NSHeight(prefsView.frame))];
    [paneContainer addSubview:prefsView];
    [window recalculateKeyViewLoop];
}

@end
