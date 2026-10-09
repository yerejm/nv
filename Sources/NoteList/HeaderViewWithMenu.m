#import "NotesTableView.h"
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


#import "HeaderViewWithMenu.h"
#import "NoteAttributeColumn.h"

@implementation HeaderViewWithMenu

- (id)init {
	if ((self = [super init])) {
		isReloading = NO;
	}
	return self;
}

//while a column edge is dragged every column absorbs the change, so the columns keep filling the list;
//the header tracks the whole drag inside mouseDown:
- (void)mouseDown:(NSEvent *)event {
	NSMutableArray *userResizableColumns = [NSMutableArray array];
	for (NSTableColumn *column in [[self tableView] tableColumns]) {
		if ([column resizingMask] == NSTableColumnUserResizingMask) {
			[column setResizingMask:NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask];
			[userResizableColumns addObject:column];
		}
	}
	[super mouseDown:event];
	for (NSTableColumn *column in userResizableColumns)
		[column setResizingMask:NSTableColumnUserResizingMask];
}

- (void)setIsReloading:(BOOL)reloading {
	isReloading = reloading;
}

- (void)resetCursorRects {
	if (!isReloading) {
		[super resetCursorRects];
	}
}

- (NSMenu *)menuForEvent:(NSEvent *)theEvent {
    
    if ([[self tableView] respondsToSelector:@selector(menuForColumnConfiguration:)]) {
	NSPoint theClickPoint = [self convertPoint:[theEvent locationInWindow] fromView:NULL];
	NSInteger theColumn = [self columnAtPoint:theClickPoint];
	NSTableColumn *theTableColumn = nil;
	if (theColumn > -1)
	    theTableColumn = [[[self tableView] tableColumns] objectAtIndex:theColumn];
	
	NSMenu *theMenu = [[self tableView] performSelector:@selector(menuForColumnConfiguration:) withObject:theTableColumn];
	return theMenu;
    }
    
    return nil;
}


@end
