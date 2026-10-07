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
#import "NSBezierPath_NV.h"
#import "LinearDividerShader.h"
#import "AppController.h"
#import "BookmarksController.h"

#define BORDER_LEFT_OFFSET 3.0
#define MAX_STATE_IMG_DIM 16.0
#define CLEAR_BUTTON_IMG_DIM 16.0
#define TEXT_LEFT_OFFSET (MAX_STATE_IMG_DIM + BORDER_LEFT_OFFSET)

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
	
	if (BUTTON_HIDDEN != clearButtonState) {
		NSImage *clearImg = [NSImage imageNamed:(clearButtonState == BUTTON_NORMAL ? @"Clear" : @"ClearPressed") ];
        [clearImg drawInRect:[self clearButtonRectForBounds:cellFrame] fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
	}
	if (BUTTON_HIDDEN != snapbackButtonState) {
		NSRect snRect = [self snapbackButtonRectForBounds:cellFrame];
		NSImage *snapImg = [NSImage imageNamed:
							[(DualField *)controlView hasFollowedLinks] ? (snapbackButtonState == BUTTON_NORMAL ? @"LinkBack" : @"LinkBackPressed") :
							(snapbackButtonState == BUTTON_NORMAL ? @"SnapBack" : @"SnapBackPressed") ];
        [snapImg drawInRect:snRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
	}
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
	
	NSCell *dualFieldCell = [[[DualFieldCell alloc] init] autorelease];
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
	IBeamCursor = [[NSCursor IBeamCursor] retain];
	
	followedLinks = [[NSMutableArray alloc] init];
}

- (void)setTrackingRect {
	if (!docIconRectTag)
		docIconRectTag = [self addTrackingRect:[[self cell] snapbackButtonRectForBounds:[self bounds]] 
										 owner:self userData:NULL assumeInside:NO];	
}

- (void)dealloc {
	[snapbackString release];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[followedLinks release];
	
	[super dealloc];
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
	if ([theEvent trackingNumber] == docIconRectTag) {
		[[self cell] setShowsSnapbackButton:[self showsDocumentIcon]];
	} else {
		NSLog(@"got mouse entered on a different tracking number: %ld", (long)[theEvent trackingNumber]);
	}
}
- (void)mouseExited:(NSEvent *)theEvent {
	if ([theEvent trackingNumber] == docIconRectTag) {
		[[self cell] setShowsSnapbackButton:NO];
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
	
	NoteBookmark *aBookmark = [[followedLinks lastObject] retain];
	[followedLinks removeLastObject];
	 
	[(AppController *)[NSApp delegate] searchForString:[aBookmark searchString]];
	[(AppController *)[NSApp delegate] revealNote:[aBookmark noteObject] options:0];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearFollowedLinks) object:nil];

	return [aBookmark autorelease];
}

- (void)clearFollowedLinks {
	[followedLinks removeAllObjects];
}

- (void)setSnapbackString:(NSString*)string {
	
	NSString *proposedString = string ? [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
	
	if (proposedString != snapbackString /*the nil == nil case*/ && ![proposedString isEqualToString:snapbackString]) {
		[snapbackString release];
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

/*- (BOOL)becomeFirstResponder {
	[(AppController *)[NSApp delegate] updateEmptyViewStatus];
	return [super becomeFirstResponder];
}*/

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
	
	//if ([replacementString rangeOfString:@"\n" options:NSLiteralSearch].location != NSNotFound) {
//		//NO! you cannot paste line feeds.
//		return NO;
//	}
	
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

+ (NSImage*)snapbackImageWithString:(NSString*)string {
	//get width of string, center rect around it,
	//lock focus, draw rounded rect, draw text, unlock focus
	
	static NSDictionary *smallTextAttrs = nil;
	static NSMutableDictionary *smallTextBackAttrs = nil;
	if (!smallTextAttrs) {
		smallTextAttrs = [[NSDictionary dictionaryWithObjectsAndKeys:
						   [NSFont systemFontOfSize:[NSFont smallSystemFontSize]], NSFontAttributeName, 
						   [NSColor whiteColor], NSForegroundColorAttributeName, nil] retain];
		[(smallTextBackAttrs = [smallTextAttrs mutableCopy]) setObject:[NSColor colorWithCalibratedWhite:0.44 alpha:1.0] forKey:NSForegroundColorAttributeName];
	}
	
	if ([string length] > 15) string = [[string substringToIndex:15] stringByAppendingString:NSLocalizedString(@"...", @"ellipsis character")];
	NSSize stringSize = [string sizeWithAttributes:smallTextAttrs];
	
	NSPoint textOffset = NSMakePoint(5.0f, 2.0f);
	NSRect wordRect = NSMakeRect(0, 0, ceilf(stringSize.width + textOffset.x * 2.0f), stringSize.height + textOffset.y * 2.0f);
	
	NSImage *image = [[NSImage alloc] initWithSize:wordRect.size];
	[image lockFocus];

	NSBezierPath *backgroundPath = [NSBezierPath bezierPathWithRoundRectInRect:NSInsetRect(wordRect, 1.5, 1.5) radius:1.5f];

	static LinearDividerShader *snapbackShader = nil;
	if (!snapbackShader) {
		snapbackShader = [[LinearDividerShader alloc] initWithStartColor:[NSColor colorWithDeviceRed:0.8 green:0.386 blue:0.019 alpha:1.0]
																endColor:[NSColor colorWithDeviceRed:1.0 green:0.486 blue:0.039 alpha:1.0]];
	}


	[[NSGraphicsContext currentContext] saveGraphicsState];
	[backgroundPath addClip];
	[snapbackShader drawDividerInRect:wordRect withDimpleRect:NSZeroRect blendVertically:YES];
	[[NSGraphicsContext currentContext] restoreGraphicsState];
	
	[[NSColor colorWithDeviceRed:0.63 green:0.20 blue:0.0 alpha:1.0] set];
	[backgroundPath stroke];
	
	[string drawAtPoint:NSMakePoint(textOffset.x, textOffset.y+1) withAttributes:smallTextBackAttrs];
	[string drawAtPoint:textOffset withAttributes:smallTextAttrs];
	
	[image unlockFocus];
	return [image autorelease];
}

- (void)drawRect:(NSRect)rect {
    [super drawRect:rect];
    if (![self.cell snapbackButtonIsVisible]) {
        NSImage *icon = [NSImage imageWithSystemSymbolName:showsDocumentIcon ? @"pencil" : @"magnifyingglass" accessibilityDescription:nil];
        icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[[[GlobalPrefs defaultPrefs] foregroundTextColor]]]];
        CGFloat opacity = self.window.isMainWindow ? 0.8 : 0.45;
        NSRect frame = NSInsetRect([self.cell snapbackButtonRectForBounds:self.bounds], 1, 1);
        [icon drawInRect:frame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:opacity respectFlipped:YES hints:nil];
    }
}

@end
