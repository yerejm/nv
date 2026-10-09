/* AppController */

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


#import <Cocoa/Cocoa.h>

#import "NotationController.h"
#import "NotesTableView.h"
#import "NVSplitView.h"

@class LinkingEditor;
@class EmptyView;
@class NotesTableView;
@class GlobalPrefs;
@class PrefsWindowController;
@class DualField;

@interface AppController : NSObject
<NSMenuItemValidation, NSApplicationDelegate, NSToolbarDelegate, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSTokenFieldDelegate, NVSplitViewDelegate>
{
    IBOutlet DualField *field;
	IBOutlet NSView *splitSubview;
	IBOutlet NVSplitView *splitView;
    IBOutlet NotesTableView *notesTableView;
    IBOutlet LinkingEditor *textView;
	IBOutlet EmptyView *editorStatusView;
    IBOutlet NSWindow *window;
	NSToolbar *toolbar;
	NSToolbarItem *dualFieldItem;
    NSTextField *windowTitleLabel;
	
	NSURL *URLToInterpretOnLaunch;
	NSMutableArray *pathsToOpenOnLaunch;
	
    NSUndoManager *windowUndoManager;
    PrefsWindowController *prefsWindowController;
    GlobalPrefs *prefsController;
    NotationController *notationController;
	
	NSRunningApplication *previousActiveApplication;
	BOOL activatedFromAnotherSpace;
	BOOL activationRequested;
    BOOL pendingSearchFocus;
	BOOL changingViewLayout;
	BOOL fullScreenSwitchedLayout, fullScreenSearchVisible, fullScreenEditorFocused;
    NSTextField *wordCountLabel;
    id modifierMonitor;
    NSStatusItem *statusItem;
    NSMenu *statusMenu;
    BOOL temporaryWordCount;
	ViewLocationContext listUpdateViewCtx;
	BOOL isFilteringFromTyping, typedStringIsCached;
	BOOL isCreatingANote;
	NSString *typedString;
	
	NoteObject *currentNote;
	NSArray *savedSelectedNotes;
}

void outletObjectAwoke(id sender);

- (void)setNotationController:(NotationController*)newNotation;

- (void)setupViewsAfterAppAwakened;
- (void)runDelayedUIActionsAfterLaunch;
- (void)updateNoteMenus;
- (void)updateInterfaceAppearance;

- (IBAction)renameNote:(id)sender;
- (IBAction)deleteNote:(id)sender;
- (IBAction)copyNoteLink:(id)sender;
- (IBAction)exportNote:(id)sender;
- (IBAction)revealNote:(id)sender;
- (IBAction)editNoteExternally:(id)sender;
- (IBAction)printNote:(id)sender;
- (IBAction)tagNote:(id)sender;
- (void)applySharedTags:(NSArray *)tags toNotes:(NSArray *)notes originalSharedTags:(NSArray *)sharedTags;
- (void)flagsChanged:(NSEvent *)event;
- (void)updateWordCount;
- (IBAction)toggleWordCount:(id)sender;
- (void)updateDesktopPresence;
- (IBAction)statusItemAction:(id)sender;
- (IBAction)showStatusMenu:(id)sender;
- (IBAction)toggleDockIcon:(id)sender;
- (IBAction)createNoteFromStatusClipboard:(id)sender;
- (IBAction)importNotes:(id)sender;
- (IBAction)switchViewLayout:(id)sender;
- (IBAction)toggleCollapse:(id)sender;

- (IBAction)fieldAction:(id)sender;
- (NoteObject*)createNoteIfNecessary;
- (void)searchForString:(NSString*)string;
- (NSUInteger)revealNote:(NoteObject*)note options:(NSUInteger)opts;
- (BOOL)displayContentsForNoteAtIndex:(NSInteger)noteIndex;
- (void)processChangedSelectionForTable:(NSTableView*)table;
- (void)setEmptyViewState:(BOOL)state;
- (void)cancelOperation:(id)sender;
- (void)_setCurrentNote:(NoteObject*)aNote;
- (void)_expandToolbar;
- (void)_collapseToolbar;
- (void)_forceRegeneratePreviewsForTitleColumn;
- (void)_configureDividerForCurrentLayout;
- (NoteObject*)selectedNoteObject;

- (void)restoreListStateUsingPreferences;

- (void)setTableAllowsMultipleSelection;

- (NSString*)fieldSearchString;
- (void)cacheTypedStringIfNecessary:(NSString*)aString;
- (NSString*)typedString;

- (IBAction)showHelpDocument:(id)sender;
- (IBAction)showPreferencesWindow:(id)sender;
- (IBAction)toggleNVActivation:(id)sender;
- (IBAction)bringFocusToControlField:(id)sender;
- (NSWindow*)window;

@end
