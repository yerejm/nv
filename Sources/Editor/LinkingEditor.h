/* LinkingEditor */

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
#import <objc/runtime.h>

@class NotesTableView;
@class NoteObject;
@class GlobalPrefs;

@interface LinkingEditor : NSTextView
<NSLayoutManagerDelegate>
{
    IBOutlet NSTextField *controlField;
    IBOutlet NotesTableView *notesTableView;

	GlobalPrefs *prefsController;
	NSTextFinder *textFinder;
	BOOL didRenderFully;
	
	BOOL didChangeIntoAutomaticRange;
	NSRange lastAutomaticallySelectedRange;
	NSRange changedRange;
	BOOL isAutocompleting, wasDeleting;
	
	BOOL mouseInside;
	BOOL updatingTextWidth;
	
};

- (NSColor*)_insertionPointColorForForegroundColor:(NSColor*)fgColor backgroundColor:(NSColor*)bgColor;
- (NSColor*)_linkColorForForegroundColor:(NSColor*)fgColor backgroundColor:(NSColor*)bgColor;
- (NSColor*)_selectionColorForForegroundColor:(NSColor*)fgColor backgroundColor:(NSColor*)bgColor;
- (NSDictionary*)preferredLinkAttributes;
- (void)updateTextColors;
- (void)updateTextWidth;
- (void)updateWritingDirection;
- (void)insertParagraphAbove:(id)sender;
- (void)insertParagraphBelow:(id)sender;
- (NSRange)selectedRangeWasAutomatic:(BOOL*)automatic;
- (void)setAutomaticallySelectedRange:(NSRange)newRange;
- (void)removeHighlightedTerms;
- (void)highlightRangesTemporarily:(CFArrayRef)ranges;
- (NSRange)highlightTermsTemporarilyReturningFirstRange:(NSString*)typedString avoidHighlight:(BOOL)noHighlight;
- (void)defaultStyle:(id)sender;
- (void)strikethroughNV:(id)sender;
- (void)bold:(id)sender;
- (void)italic:(id)sender;
- (void)applyStyleOfTrait:(NSFontTraitMask)trait alternateAttributeName:(NSString*)attrName alternateAttributeValue:(id)value;
- (id)highlightLinkAtIndex:(NSUInteger)givenIndex;

- (BOOL)jumpToRenaming;
- (void)indicateRange:(NSValue*)rangeValue;

- (void)fixTypingAttributesForSubstitutedFonts;
- (void)fixCursorForBackgroundUpdatingMouseInside:(BOOL)setMouseInside;

- (BOOL)_selectionAbutsBulletIndentRange;
- (BOOL)_rangeIsAutoIdentedBullet:(NSRange)aRange;

- (void)setupFontMenu;
- (void)clearFindPanel;
- (void)noteFindContentWillChange;
- (void)configureFindMenu:(NSMenu *)menu;
- (BOOL)didRenderFully;
@end

@interface NSTextView (Private)

@end
