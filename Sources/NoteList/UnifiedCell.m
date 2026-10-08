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


#import "UnifiedCell.h"
#import "NoteObject.h"
#import "NotesTableView.h"
#import "GlobalPrefs.h"
#import "NSBezierPath_NV.h"
#import "NSString_CustomTruncation.h"
#import "NoteAttributeColumn.h"

@implementation UnifiedCell

- (id)init {
	if ([super init]) {

		[self setTruncatesLastVisibleLine:YES];
		[self setEditable:YES];
	}
	return self;
}

- (void)dealloc {
	[super dealloc];
}

- (void)selectWithFrame:(NSRect)aRect inView:(NSView *)controlView editor:(NSText *)textObj 
			   delegate:(id)anObject start:(NSInteger)selStart length:(NSInteger)selLength {
	
	NSRect rect = [(NotesTableView*)controlView lastEventActivatedTagEdit] ? [self nv_tagsRectForFrame:aRect] : [self nv_titleRectForFrame:aRect];
	[super selectWithFrame:rect inView:controlView editor:textObj delegate:anObject start:selStart length:selLength];
	
	[controlView setKeyboardFocusRingNeedsDisplayInRect:NSInsetRect([self nv_tagsRectForFrame:aRect], -3, -3)];
}

- (NSFocusRingType)focusRingType {
	return NSFocusRingTypeNone;
}

- (float)tableFontFrameHeight {
	return [(NotesTableView*)[self controlView] tableFontHeight] + 1.0f;
}

- (NSRect)nv_titleRectForFrame:(NSRect)aFrame {
	//fixed based on width of the cell

	//height could justifiably vary based on wrapped height of title string
	return NSMakeRect(aFrame.origin.x, aFrame.origin.y, MAX(0, aFrame.size.width - [self dateWidthForFrame:aFrame] - 8), [self tableFontFrameHeight]);
}

- (NSRect)nv_tagsRectForFrame:(NSRect)frame {
	//if no tags, return a default small frame to allow adding them
	float fontHeight = [self tableFontFrameHeight];
	NSSize size = NSMakeSize(NSWidth(frame), fontHeight);
	NSPoint pos = NSMakePoint(NSMinX(frame) + 3.0, (previewIsHidden ? NSMinY(frame) + fontHeight + size.height + 2.0 : NSMaxY(frame) - 2.0) - fontHeight);
	
	return (NSRect){pos, size};
}


- (NoteObject*)noteObject {
	return noteObject;
}

- (void)setNoteObject:(NoteObject*)obj {
	[noteObject autorelease];
	noteObject = [obj retain];
}

- (void)setPreviewIsHidden:(BOOL)value {
	previewIsHidden = value;
}

NSAttributedString *AttributedStringForSelection(NSAttributedString *str, BOOL withShadow) {
	//used to modify the cell's attributed string before display when it is selected
	NSRange fullRange = NSMakeRange(0, [str length]);
	NSMutableAttributedString *colorFreeStr = [str mutableCopy];
	[colorFreeStr removeAttribute:NSForegroundColorAttributeName range:fullRange];
	[colorFreeStr removeAttribute:NSShadowAttributeName range:fullRange];
	return [colorFreeStr autorelease];
}

- (NSString *)dateString {
    GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
    unsigned int columns = [prefs tableColumnsBitmap];
    if (!noteObject || (!ColumnIsSet(NoteDateCreatedColumn, columns) && !ColumnIsSet(NoteDateModifiedColumn, columns))) return @"";
    BOOL created = ColumnIsSet(NoteDateCreatedColumn, columns) &&
        (!ColumnIsSet(NoteDateModifiedColumn, columns) || [[prefs sortedTableColumnKey] isEqualToString:NoteDateCreatedColumnString]);
    return (created ? dateCreatedStringOfNote : dateModifiedStringOfNote)((id)self.controlView, noteObject, NSNotFound);
}

//the date and tags are drawn beside the cell's text rather than being part of it, so VoiceOver hears them here
- (NSString *)accessibilityLabel {
	NSMutableArray *parts = [NSMutableArray array];
	NSString *date = [self dateString];
	if ([date length]) [parts addObject:date];
	if (ColumnIsSet(NoteLabelsColumn, [[GlobalPrefs defaultPrefs] tableColumnsBitmap]) && [labelsOfNote(noteObject) length])
		[parts addObject:labelsOfNote(noteObject)];
	return [parts count] ? [parts componentsJoinedByString:@", "] : [super accessibilityLabel];
}

- (CGFloat)dateWidthForFrame:(NSRect)frame {
    NSString *date = [self dateString];
    return date.length ? MIN(ceil([date sizeWithAttributes:[self baseTextAttributes]].width) + 4, frame.size.width * 0.6) : 0;
}

- (NSMutableDictionary*)baseTextAttributes {
	static NSMutableParagraphStyle *alignStyle = nil;
	if (!alignStyle) {
		alignStyle = [[NSMutableParagraphStyle alloc] init];
		[alignStyle setAlignment:NSTextAlignmentRight];
        [alignStyle setLineBreakMode:NSLineBreakByTruncatingTail];
	}
	return [NSMutableDictionary dictionaryWithObjectsAndKeys:alignStyle, NSParagraphStyleAttributeName, [self font], NSFontAttributeName, nil];
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {	
	
	NotesTableView *tv = (NotesTableView *)controlView;
	
    NSMutableAttributedString *title = [[self.attributedStringValue mutableCopy] autorelease];
    if (title.length) {
        NSMutableParagraphStyle *style = [[([title attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL] ?: [NSParagraphStyle defaultParagraphStyle]) mutableCopy] autorelease];
        style.tailIndent = -[self dateWidthForFrame:cellFrame] - 8;
        [title addAttribute:NSParagraphStyleAttributeName value:style range:NSMakeRange(0, MIN(title.length, titleOfNote(noteObject).length))];
        [self setAttributedStringValue:title];
    }
	[super drawWithFrame:cellFrame inView:controlView];	
	
	//draw note date and tags

	NSMutableDictionary *baseAttrs = [self baseTextAttributes];
	//a selected row is drawn in the accent color only while the list has focus; otherwise it is a neutral gray
	BOOL emphasized = [self isHighlighted] && [tv isActiveStyle];
	NSColor *textColor = emphasized ? [NSColor alternateSelectedControlTextColor] : [[GlobalPrefs defaultPrefs] interfaceSecondaryColor];
	[baseAttrs setObject:textColor forKey:NSForegroundColorAttributeName];

	float fontHeight = [tv tableFontHeight];
	
	//if the sort-order is date-created, then show the date on which this note was created; otherwise show date modified.
	unsigned int columnsBitmap = [[GlobalPrefs defaultPrefs] tableColumnsBitmap];
	
	if (ColumnIsSet(NoteDateCreatedColumn, columnsBitmap) || ColumnIsSet(NoteDateModifiedColumn, columnsBitmap)) {
        NSString *dateStr = [self dateString];
        CGFloat width = [self dateWidthForFrame:cellFrame];
        [dateStr drawInRect:NSMakeRect(NSMaxX(cellFrame) - width, NSMinY(cellFrame), width, fontHeight) withAttributes:baseAttrs];
	}

	if (ColumnIsSet(NoteLabelsColumn, columnsBitmap) && [labelsOfNote(noteObject) length]) {
		NSRect rect = [self nv_tagsRectForFrame:cellFrame];
		rect.origin.y += fontHeight;
		rect = [controlView centerScanRect:rect];
		
		//clip the tags image within the bounds of the cell so that narrow columns look nicer
		[NSGraphicsContext saveGraphicsState];
		NSRectClip(cellFrame);
		[noteObject drawLabelBlocksInRect:rect rightAlign:!previewIsHidden highlighted:emphasized];
		[NSGraphicsContext restoreGraphicsState];
	}
	
	if ([tv currentEditor] && [self isHighlighted]) {
		//needed because the body text is normally not drawn while editing
		NSMutableAttributedString *cloneStr = [[self attributedStringValue] mutableCopy];
		[cloneStr addAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[self font], NSFontAttributeName, textColor, 
								 NSForegroundColorAttributeName, nil] range:NSMakeRange(0, [cloneStr length])];
		[cloneStr addAttributes:LineTruncAttributesForTitle() range:NSMakeRange(0, [titleOfNote(noteObject) length])];
		
		[cloneStr drawWithRect:NSInsetRect([self titleRectForBounds:cellFrame], 2., 0.) options: NSStringDrawingTruncatesLastVisibleLine | NSStringDrawingUsesLineFragmentOrigin];
		[cloneStr release];
		
		//draw a slightly different focus ring than what would have been drawn
		NSRect rect = [tv lastEventActivatedTagEdit] ? [self nv_tagsRectForFrame:cellFrame] : [self nv_titleRectForFrame:cellFrame];
		[NSGraphicsContext saveGraphicsState];
		NSBezierPath *path = [NSBezierPath bezierPathWithRect:NSInsetRect(rect, -2, -1)];
		
		//megafocusring casts a shadow both outside and inside
		if ([tv lastEventActivatedTagEdit]) {
			NSSetFocusRingStyle(NSFocusRingBelow);
			[path fill];
		}
		NSSetFocusRingStyle(NSFocusRingOnly);
		[path fill];
		
		[NSGraphicsContext restoreGraphicsState];
		
	}
}

@end
