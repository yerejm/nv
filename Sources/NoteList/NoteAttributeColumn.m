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


#import "NoteAttributeColumn.h"
#import "NotesTableView.h"
#import "GlobalPrefs.h"


@implementation NoteTableHeaderCell

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
    GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
    [[[prefs backgroundTextColor] blendedColorWithFraction:self.isHighlighted ? 0.12 : 0.04 ofColor:[prefs foregroundTextColor]] setFill];
    NSRectFill(frame);
    [self drawInteriorWithFrame:frame inView:view];
    [[prefs interfaceSeparatorColor] setFill];
    NSRectFill(NSMakeRect(NSMinX(frame), NSMaxY(frame) - 1, NSWidth(frame), 1));
    if (NSMaxX(frame) < NSMaxX(view.bounds) - 1)
        NSRectFill(NSMakeRect(NSMaxX(frame) - 1, NSMinY(frame) + 6, 1, NSHeight(frame) - 12));
}

//AppKit centres only the sorted column's title, so every column is drawn here the same way
- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view {
    NSTableView *table = [view isKindOfClass:[NSTableHeaderView class]] ? [(NSTableHeaderView *)view tableView] : nil;
    NSImage *indicator = nil;
    for (NSTableColumn *column in [table tableColumns])
        if ([column headerCell] == self) indicator = [table indicatorImageInTableColumn:column];

    NSRect titleRect = [self titleRectForBounds:frame];
    if (indicator) {
        [self drawSortIndicatorWithFrame:frame inView:view ascending:[[indicator name] isEqualToString:@"NSAscendingSortIndicator"] priority:0];
        titleRect.size.width = MAX(0.0, NSMinX([self sortIndicatorRectForBounds:frame]) - 4 - NSMinX(titleRect));
    }
    NSFont *font = indicator ? [NSFont systemFontOfSize:[[self font] pointSize] weight:NSFontWeightSemibold] : [self font];
    NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [style setLineBreakMode:NSLineBreakByTruncatingTail];
    [[self stringValue] drawWithRect:titleRect options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                          attributes:@{NSFontAttributeName: font, NSParagraphStyleAttributeName: style,
                                       NSForegroundColorAttributeName: [[GlobalPrefs defaultPrefs] foregroundTextColor]}];
}

- (NSRect)titleRectForBounds:(NSRect)theRect {
    NSRect rect = [self drawingRectForBounds:theRect];
    NSFont *font = [self font];
    CGFloat lineHeight = ceil([font ascender] - [font descender] + [font leading]);
    rect.origin.y = round(NSMidY(theRect) - lineHeight / 2);
    rect.size.height = lineHeight;
    return rect;
}

- (NSRect)drawingRectForBounds:(NSRect)theRect {
	return NSInsetRect(theRect, 6.0f, 0.0);
}

@end

@implementation NoteAttributeColumn

- (id)initWithIdentifier:(id)anObject {
	
	if ([super initWithIdentifier:anObject]) {

		absoluteMinimumWidth = [anObject sizeWithAttributes:[NoteAttributeColumn standardDictionary]].width + 5;
		[self setMinWidth:absoluteMinimumWidth];
	}
	
	return self;
}

+ (NSDictionary*)standardDictionary {
	static NSDictionary *standardDictionary = nil;
	if (!standardDictionary)
		standardDictionary = [[NSDictionary dictionaryWithObjectsAndKeys:
			[NSFont systemFontOfSize:[NSFont smallSystemFontSize]], NSFontAttributeName, nil] retain];	

	return standardDictionary;
}

- (void)updateWidthForHighlight {
	[self setMinWidth:absoluteMinimumWidth + ([[self tableView] highlightedTableColumn] == self ? 10 : 0)];
}

SEL columnAttributeMutator(NoteAttributeColumn *col) {
	return col->mutateObjectSelector;
}

- (void)setMutatingSelector:(SEL)selector {
	mutateObjectSelector = selector;
}

id columnAttributeForObject(NotesTableView *tv, NoteAttributeColumn *col, id object, NSInteger row) {
	return col->objectAttribute(tv, object, row);
}

- (void)setDereferencingFunction:(id (*)(id, id, NSInteger))attributeFunction {
    objectAttribute = attributeFunction;
}

- (void)setSortingFunction:(NSInteger (*)(id *, id *))aFunction {
    sortFunction = aFunction;
}

- (NSInteger (*)(id *, id *))sortFunction {
    return sortFunction;
}

- (void)setReverseSortingFunction:(NSInteger (*)(id*, id*))aFunction {
    reverseSortFunction = aFunction;
}

- (NSInteger (*)(id*, id*))reverseSortFunction {
    return reverseSortFunction;
}
id (*dereferencingFunction(NoteAttributeColumn *col))(id, id, NSInteger) {
	return col->objectAttribute;
}

@end
