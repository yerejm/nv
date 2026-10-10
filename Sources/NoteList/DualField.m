#import "AppController_Importing.h"
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


#import "DualField.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NotationPrefs.h"
#import "AppController.h"
#import "BookmarksController.h"

#define BORDER_LEFT_OFFSET 3.0
#define MAX_STATE_IMG_DIM 16.0
#define CLEAR_BUTTON_IMG_DIM 16.0
#define TEXT_LEFT_OFFSET (MAX_STATE_IMG_DIM + BORDER_LEFT_OFFSET)

static void DrawFieldSymbol(NSString *name, NSRect rect, CGFloat opacity) {
    NSImage *icon = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    //hierarchical rather than a single palette color keeps the glyph distinct from its circle in the filled button symbols
    icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:[[GlobalPrefs defaultPrefs] foregroundTextColor]]];
    [icon drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:opacity respectFlipped:YES hints:nil];
}

//the clear and back buttons are drawn by the cell, so VoiceOver reaches them through these
@interface DualFieldButtonElement : NSAccessibilityElement
@property (nonatomic, assign) DualFieldCell *fieldCell;
@property (nonatomic) BOOL clears;
@end

@implementation DualFieldButtonElement

- (NSRect)accessibilityFrame {
	NSView *view = [self.fieldCell controlView];
	NSRect rect = self.clears ? [self.fieldCell clearButtonRectForBounds:[view bounds]] : [self.fieldCell snapbackButtonRectForBounds:[view bounds]];
	return NSAccessibilityFrameInView(view, rect);
}

- (id)accessibilityParent {
	return self.fieldCell;
}

- (BOOL)accessibilityPerformPress {
	if (self.clears) [NSApp tryToPerform:@selector(cancelOperation:) with:nil];
	else [(DualField *)[self.fieldCell controlView] snapback:nil];
	return YES;
}

@end

@implementation DualFieldCell

- (id) init {
	self = [super init];
	if (self != nil) {
		[self setStringValue:@""];
		[self setEditable:YES];
		[self setSelectable:YES];
		[self setBezeled:NO];
		[self setBordered:NO];
		[self setDrawsBackground:NO];
		[self setWraps:YES];
		[self setPlaceholderString:NSLocalizedString(@"Search or Create", @"placeholder text in search/create field")];
		
		[self setFocusRingType:NSFocusRingTypeExterior];
		
		clearButtonState = snapbackButtonState = BUTTON_HIDDEN;
		
	}
	return self;
}

- (NSRect)drawingRectForBounds:(NSRect)someBounds {
    return [self textAreaForBounds:someBounds];
}

- (void)selectWithFrame:(NSRect)frame inView:(NSView *)controlView editor:(NSText *)editor delegate:(id)delegate start:(NSInteger)start length:(NSInteger)length {
    [super selectWithFrame:[self textAreaForBounds:frame] inView:controlView editor:editor delegate:delegate start:start length:length];
}

- (void)editWithFrame:(NSRect)frame inView:(NSView *)controlView editor:(NSText *)editor delegate:(id)delegate event:(NSEvent *)event {
    [super editWithFrame:[self textAreaForBounds:frame] inView:controlView editor:editor delegate:delegate event:event];
}

- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
	NSTextView *textView = (NSTextView*)[super setUpFieldEditorAttributes:textObj];
	[textView setDrawsBackground:NO];
    [textView setTextColor:[[GlobalPrefs defaultPrefs] foregroundTextColor]];
    [textView setInsertionPointColor:[[GlobalPrefs defaultPrefs] foregroundTextColor]];
    [textView setSelectedTextAttributes:@{NSBackgroundColorAttributeName:[NSColor selectedTextBackgroundColor], NSForegroundColorAttributeName:[NSColor selectedTextColor]}];
		
	return textView;
}

- (NSRect)clearButtonRectForBounds:(NSRect)rect {
    return NSMakeRect(NSMaxX(rect) - CLEAR_BUTTON_IMG_DIM - BORDER_LEFT_OFFSET,
                      floor(NSMidY(rect) - CLEAR_BUTTON_IMG_DIM / 2),
                      CLEAR_BUTTON_IMG_DIM, CLEAR_BUTTON_IMG_DIM);
}

- (NSRect)snapbackButtonRectForBounds:(NSRect)rect {
    return NSMakeRect(NSMinX(rect) + BORDER_LEFT_OFFSET,
                      floor(NSMidY(rect) - MAX_STATE_IMG_DIM / 2),
                      MAX_STATE_IMG_DIM, MAX_STATE_IMG_DIM);
}

- (NSRect)textAreaForBounds:(NSRect)rect {
    NSRect textRect = [super drawingRectForBounds:rect];
    CGFloat height = MIN(NSHeight(textRect), ceil(self.font.ascender - self.font.descender + self.font.leading));
    return NSMakeRect(NSMinX(rect) + TEXT_LEFT_OFFSET + 3,
                      floor(NSMidY(textRect) - height / 2),
                      MAX(0, NSWidth(rect) - TEXT_LEFT_OFFSET - CLEAR_BUTTON_IMG_DIM - BORDER_LEFT_OFFSET - 6),
                      height);
}

- (void)drawFocusRingMaskWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(cellFrame, 1, 1) xRadius:6 yRadius:6] fill];
}

- (NSRect)focusRingMaskBoundsForFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    return NSInsetRect(cellFrame, 1, 1);
}

- (BOOL)clearButtonIsVisible {
	return BUTTON_HIDDEN != clearButtonState;
}

- (void)setShowsClearButton:(BOOL)shouldShow {
	if ((BUTTON_HIDDEN != clearButtonState) != shouldShow) {
		NSView *controlView = [self controlView];
		clearButtonState = shouldShow ? BUTTON_NORMAL : BUTTON_HIDDEN;
		[controlView setNeedsDisplayInRect:[self clearButtonRectForBounds:[controlView bounds]]];
		[[controlView window] invalidateCursorRectsForView:controlView];
	}
}

- (BOOL)snapbackButtonIsVisible {
	return BUTTON_HIDDEN != snapbackButtonState;
}

- (void)setShowsSnapbackButton:(BOOL)shouldShow {
	NSView *controlView = [self controlView];
	//used for being notified from a mouseover-ing
	if ((snapbackButtonState != BUTTON_HIDDEN) != shouldShow) {
		snapbackButtonState = shouldShow ? BUTTON_NORMAL : BUTTON_HIDDEN;
		[controlView setNeedsDisplayInRect:[self snapbackButtonRectForBounds:[controlView bounds]]];
		[[controlView window] invalidateCursorRectsForView:controlView];
	}
	
}

- (DualFieldButtonElement *)_accessibilityButtonClearing:(BOOL)clears {
	DualFieldButtonElement *element = [[DualFieldButtonElement alloc] init];
	[element setFieldCell:self];
	[element setClears:clears];
	[element setAccessibilityRole:NSAccessibilityButtonRole];
	[element setAccessibilityLabel:clears ? NSLocalizedString(@"Clear Search", @"accessibility name of the button that clears the search field") :
		NSLocalizedString(@"Back to Search", @"accessibility name of the button that returns from a note to the search")];
	[element setAccessibilityHelp:clears ? NSLocalizedString(@"Clear the search; press ESC", @"tooltip string for search/title field") :
		[NSString stringWithFormat:NSLocalizedString(@"Go back to search; press %@-D to deselect", @"tooltip string for search/title field"), @"\u2318"]];
	return element;
}

//cells are copied bitwise, so a copy makes its own accessibility buttons
- (id)copyWithZone:(NSZone *)zone {
	DualFieldCell *copy = [super copyWithZone:zone];
	copy->clearButtonElement = nil;
	copy->snapbackButtonElement = nil;
	return copy;
}

- (NSAccessibilitySubrole)accessibilitySubrole {
	return NSAccessibilitySearchFieldSubrole;
}

- (NSString *)accessibilityLabel {
	return NSLocalizedString(@"Search or Create", @"placeholder text in search/create field");
}

- (NSString *)accessibilityHelp {
	return NSLocalizedString(@"Type any text to search; press Return to create a note", @"tooltip string for search/title field");
}

- (id)accessibilityClearButton {
	if (![self clearButtonIsVisible]) return nil;
	if (!clearButtonElement) clearButtonElement = [self _accessibilityButtonClearing:YES];
	return clearButtonElement;
}

//the back button only lights up under the pointer, but going back is possible whenever a note or followed link is showing
- (id)accessibilitySearchButton {
	DualField *field = (DualField *)[self controlView];
	if (![field showsDocumentIcon] && ![field hasFollowedLinks]) return nil;
	if (!snapbackButtonElement) snapbackButtonElement = [self _accessibilityButtonClearing:NO];
	return snapbackButtonElement;
}

- (NSArray *)accessibilityChildren {
	NSMutableArray *children = [NSMutableArray arrayWithArray:[super accessibilityChildren] ?: @[]];
	for (id button in @[[self accessibilitySearchButton] ?: [NSNull null], [self accessibilityClearButton] ?: [NSNull null]])
		if (button != [NSNull null]) [children addObject:button];
	return children;
}

- (BOOL)handleMouseDown:(NSEvent *)theEvent {
	DualField *controlView = (DualField *)[self controlView];
    NSPoint location = [controlView convertPoint:theEvent.locationInWindow fromView:nil];
    if (!([self clearButtonIsVisible] && [controlView mouse:location inRect:[self clearButtonRectForBounds:controlView.bounds]]) &&
        !([self snapbackButtonIsVisible] && [controlView mouse:location inRect:[self snapbackButtonRectForBounds:controlView.bounds]])) {
		return NO;
	}
	
	do {
		NSPoint mouseLoc = [controlView convertPoint:[theEvent locationInWindow] fromView:nil];
		
		if ([self clearButtonIsVisible])
			clearButtonState = [controlView mouse:mouseLoc inRect:[self clearButtonRectForBounds:[controlView bounds]]] ? BUTTON_PRESSED : BUTTON_NORMAL;
		
		if ([self snapbackButtonIsVisible])
			snapbackButtonState = [controlView mouse:mouseLoc inRect:[self snapbackButtonRectForBounds:[controlView bounds]]]  ? BUTTON_PRESSED : BUTTON_NORMAL;
		
		[controlView setNeedsDisplay:YES];
		
		NSEventType type = [theEvent type];
		if (type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseUp) {
			if (BUTTON_PRESSED == snapbackButtonState) {
				[controlView snapback:nil];
			} else if (BUTTON_PRESSED == clearButtonState) {
				[NSApp tryToPerform:@selector(cancelOperation:) with:nil];
			}
			break;
		}
		theEvent = [[controlView window] nextEventMatchingMask: NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseUp | NSEventMaskRightMouseDragged];
	} while (1);
	
	return YES;
}
		
- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(cellFrame, 1, 1) xRadius:6 yRadius:6];
    [[prefs backgroundTextColor] setFill];
    [border fill];
    [[prefs interfaceSeparatorColor] setStroke];
    [border stroke];
    [self setTextColor:[prefs foregroundTextColor]];
    if (![(DualField *)controlView currentEditor])
        [self drawInteriorWithFrame:cellFrame inView:controlView];
	
	if (BUTTON_HIDDEN != clearButtonState)
		DrawFieldSymbol(@"xmark.circle.fill", [self clearButtonRectForBounds:cellFrame], clearButtonState == BUTTON_PRESSED ? 0.8 : 0.45);
	if (BUTTON_HIDDEN != snapbackButtonState)
		DrawFieldSymbol([(DualField *)controlView hasFollowedLinks] ? @"arrow.backward.circle.fill" : @"arrow.uturn.backward.circle.fill",
						NSInsetRect([self snapbackButtonRectForBounds:cellFrame], 1, 1), snapbackButtonState == BUTTON_PRESSED ? 0.8 : 0.45);
}


+ (BOOL)prefersTrackingUntilMouseUp {
	// NSCell returns NO for this by default. If you want to have trackMouse:inRect:ofView:untilMouseUp: always track until the mouse is up, then you MUST return YES. Otherwise, strange things will happen.
	return YES;
}

@end

@implementation DualField

+ (Class)cellClass {
	return [DualFieldCell class];
}

- (void)awakeFromNib {
	
	NSCell *dualFieldCell = [[DualFieldCell alloc] init];
	[dualFieldCell setAction:[[self cell] action]];
	[dualFieldCell setTarget:[[self cell] target]];
	[self setCell:dualFieldCell];
	DualFieldCell *myCell = [self cell];
	
	[self setDrawsBackground:NO];
	[self setBordered:NO];
	[self setBezeled:NO];
	[self setFocusRingType:NSFocusRingTypeExterior];
			
	[myCell setAllowsUndo:NO];
	[myCell setLineBreakMode:NSLineBreakByCharWrapping];
	
	//remember this now to make sure we always use the same one, in case +IBeamCursor just happens to return a different object later (hint hint)
	IBeamCursor = [NSCursor IBeamCursor];
	
	followedLinks = [[NSMutableArray alloc] init];
}

- (void)updateTrackingAreas {
	if (docIconTrackingArea) {
		[self removeTrackingArea:docIconTrackingArea];
	}
	docIconTrackingArea = [[NSTrackingArea alloc] initWithRect:[[self cell] snapbackButtonRectForBounds:[self bounds]]
													   options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow
														 owner:self userInfo:nil];
	[self addTrackingArea:docIconTrackingArea];
	[super updateTrackingAreas];
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSString *)view:(NSView *)view stringForToolTip:(NSToolTipTag)tag point:(NSPoint)point userData:(void *)userData {
	unichar ch = 0x2318;
	
	if (tag == docIconTag) {
		//should be conditional on whether snapback exists, and include the snapback string
		if ([[self cell] snapbackButtonIsVisible]) {
			return [NSString stringWithFormat:NSLocalizedString(@"Go back to search; press %@-D to deselect", @"tooltip string for search/title field"), 
					[NSString stringWithCharacters:&ch length:1]];
		} else {
			return NSLocalizedString(@"Now searching for this text", @"tooltip string for search/title field");
		}
	} else if (tag == clearButtonTag) {
		if ([[self cell] clearButtonIsVisible]) {
			return NSLocalizedString(@"Clear the search; press ESC", @"tooltip string for search/title field");
		} else {
			return NSLocalizedString(@"Type any text to search; press Return to create a note", @"tooltip string for search/title field");
		}
	} else if (tag == textAreaTag) {
		if ([self showsDocumentIcon]) {
			return [NSString stringWithFormat:NSLocalizedString(@"Now editing this note; rename it with %@-R", @"tooltip string for search/title field"),
					[NSString stringWithCharacters:&ch length:1]];
		} else {
			return NSLocalizedString(@"Type any text to search; press Return to create a note", @"tooltip string for search/title field");
		}
	}
	return nil;
}

- (void)mouseEntered:(NSEvent *)theEvent {
	if ([theEvent trackingArea] == docIconTrackingArea) {
		[[self cell] setShowsSnapbackButton:[self showsDocumentIcon]];
	} else {
		[super mouseEntered:theEvent];
	}
}
- (void)mouseExited:(NSEvent *)theEvent {
	if ([theEvent trackingArea] == docIconTrackingArea) {
		[[self cell] setShowsSnapbackButton:NO];
	} else {
		[super mouseExited:theEvent];
	}
}

- (void)resetCursorRects {
	NSRect bounds = [self bounds];
	
	NSRect textArea = [[self cell] textAreaForBounds:bounds];
	NSRect clearButtonArea = [[self cell] clearButtonRectForBounds:bounds];
	NSRect snapbackButtonArea = [[self cell] snapbackButtonRectForBounds:bounds];
	
	//always show the pointer over the doc icon area; there is always a doc icon of some sort, even if non-functional
	[self addCursorRect: snapbackButtonArea cursor: [NSCursor arrowCursor]];
	
	//conditionally show the pointer over the clear button area
	if ([[self cell] clearButtonIsVisible]) {
		[self addCursorRect: clearButtonArea cursor: [NSCursor arrowCursor]];
	} else {
		textArea = NSUnionRect(textArea, clearButtonArea);
	}
	[self addCursorRect: textArea cursor: IBeamCursor];
	
	[self removeAllToolTips];
	textAreaTag = [self addToolTipRect:textArea owner:self userData:NULL];
	clearButtonTag = [self addToolTipRect:clearButtonArea owner:self userData:NULL];	
	docIconTag = [self addToolTipRect:snapbackButtonArea owner:self userData:NULL];
}


- (void)reflectScrolledClipView:(NSClipView *)aClipView {	
	[super setKeyboardFocusRingNeedsDisplayInRect: [self bounds]];
}

- (void)mouseDown:(NSEvent*)anEvent {
	
	if ([[self cell] handleMouseDown:anEvent])
		return;
	
	[super mouseDown:anEvent];
}

- (BOOL)hasFollowedLinks {
	return [followedLinks count] != 0;
}
- (void)pushFollowedLink:(NoteBookmark*)aBM {

	[followedLinks addObject:aBM];
}

- (NoteBookmark*)popLastFollowedLink {
	
	NoteBookmark *aBookmark = [followedLinks lastObject];
	[followedLinks removeLastObject];
	 
	[(AppController *)[NSApp delegate] searchForString:[aBookmark searchString]];
	[(AppController *)[NSApp delegate] revealNote:[aBookmark noteObject] options:0];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearFollowedLinks) object:nil];

	return aBookmark;
}

- (void)clearFollowedLinks {
	[followedLinks removeAllObjects];
}

- (void)setSnapbackString:(NSString*)string {
	
	NSString *proposedString = string ? [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
	
	if (proposedString != snapbackString /*the nil == nil case*/ && ![proposedString isEqualToString:snapbackString]) {
		snapbackString = [proposedString copy];		
	}
	if (![proposedString length]) {
		[[self cell] setShowsSnapbackButton:NO];
	}
	[self performSelector:@selector(clearFollowedLinks) withObject:nil afterDelay:0];
}
- (NSString*)snapbackString {
	return snapbackString;
}


- (void)setShowsDocumentIcon:(BOOL)showsIcon {
	if (showsIcon != showsDocumentIcon) {
		showsDocumentIcon = showsIcon;
		[self setNeedsDisplay:YES];
	}
}

- (BOOL)showsDocumentIcon {
	return showsDocumentIcon;
}

- (BOOL)textView:(NSTextView *)aTextView shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString {
	
	
	lastLengthReplaced = [replacementString length];
	
	return YES;
}

- (NSUInteger)lastLengthReplaced {
	return lastLengthReplaced;
}

- (void)snapback:(id)sender {
	if ([self hasFollowedLinks]) {
		[self popLastFollowedLink];
	} else {
		[notesTable deselectAll:sender];
	}
}

- (void)drawRect:(NSRect)rect {
    [super drawRect:rect];
    if (![self.cell snapbackButtonIsVisible])
        DrawFieldSymbol(showsDocumentIcon ? @"pencil" : @"magnifyingglass", NSInsetRect([self.cell snapbackButtonRectForBounds:self.bounds], 1, 1),
                        self.window.isMainWindow ? 0.8 : 0.45);
}

@end
