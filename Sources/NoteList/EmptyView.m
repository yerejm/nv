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


#import "EmptyView.h"
#import "AppController.h"
#import "GlobalPrefs.h"

@implementation EmptyView

- (instancetype)initWithFrame:(NSRect)frameRect {
	if ((self = [super initWithFrame:frameRect]) != nil) {
		lastNotesNumber = -1;
	}
	return self;
}

- (void)awakeFromNib {
	//the nib archives Helvetica for this label
	[labelText setFont:[NSFont systemFontOfSize:[[labelText font] pointSize]]];
	[self _centerLabel];
	outletObjectAwoke(self);
}

//the label stays centred and wraps when the editor is too narrow for it, whatever its language
- (void)_centerLabel {
	NSRect bounds = NSInsetRect([self bounds], 10, 0);
	NSSize size = [[labelText cell] cellSizeForBounds:NSMakeRect(0, 0, MAX(NSWidth(bounds), 0), CGFLOAT_MAX)];
	[labelText setFrame:NSIntegralRect(NSMakeRect(NSMidX(bounds) - size.width / 2, NSMidY(bounds) - size.height / 2, size.width, size.height))];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
	[self _centerLabel];
}

- (void)mouseDown:(NSEvent*)anEvent {
	[[NSApp delegate] performSelector:@selector(_expandToolbar)];
}

- (void)setLabelStatus:(NSInteger)notesNumber {
	if (notesNumber != lastNotesNumber) {
		
		NSString *statusString = nil;
		if (notesNumber > 1) {
			statusString = NVFormatCount(NSLocalizedString(@"%d Notes Selected",nil), notesNumber);
		} else {
			statusString = NSLocalizedString(@"No Note Selected",nil);
		}
		
		[labelText setStringValue:statusString];
		[self _centerLabel];
		
		lastNotesNumber = notesNumber;
	}
}

- (void)updateInterfaceColors {
	[labelText setTextColor:[[GlobalPrefs defaultPrefs] interfaceSecondaryColor]];
	[self setNeedsDisplay:YES];
}

- (void)resetCursorRects {
	[self addCursorRect:[self bounds] cursor: [NSCursor arrowCursor]];
}

- (BOOL)isOpaque {	
	return YES;
}

- (void)drawRect:(NSRect)rect {
	[[[GlobalPrefs defaultPrefs] backgroundTextColor] set];
    NSRectFill([self bounds]);
}

@end
