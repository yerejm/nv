#import "NVSplitView.h"
#import "AppController.h"

@implementation NVSplitView

@synthesize separatorColor;

- (void)awakeFromNib {
	[super awakeFromNib];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_noteCollapseChange) name:NSSplitViewDidResizeSubviewsNotification object:self];
	outletObjectAwoke(self);
}

- (void)dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[separatorColor release];
	[super dealloc];
}

- (NSColor *)dividerColor {
	return separatorColor ? separatorColor : [super dividerColor];
}

- (void)setSeparatorColor:(NSColor *)color {
	if (color != separatorColor) {
		[separatorColor release];
		separatorColor = [color retain];
	}
	[self setNeedsDisplay:YES];
}

- (NSView *)leadingPane {
	return [[self subviews] firstObject];
}

- (CGFloat)leadingPaneSize {
	NSSize size = [[self leadingPane] frame].size;
	return [self isVertical] ? size.width : size.height;
}

- (BOOL)isLeadingPaneCollapsed {
	return [self isSubviewCollapsed:[self leadingPane]];
}

- (CGFloat)expandedLeadingPaneSize {
	return [self isLeadingPaneCollapsed] ? expandedLeadingPaneSize : [self leadingPaneSize];
}

- (void)setExpandedLeadingPaneSize:(CGFloat)size {
	expandedLeadingPaneSize = size;
	if (![self isLeadingPaneCollapsed]) [self setPosition:size ofDividerAtIndex:0];
}

- (void)setLeadingPaneCollapsed:(BOOL)collapsed {
	if (collapsed == [self isLeadingPaneCollapsed]) return;
	if (collapsed) {
		expandedLeadingPaneSize = [self leadingPaneSize];
		[[self leadingPane] setHidden:YES];
		[self adjustSubviews];
	} else {
		[[self leadingPane] setHidden:NO];
		[self adjustSubviews];
		[self setPosition:expandedLeadingPaneSize ofDividerAtIndex:0];
	}
	[self _noteCollapseChange];
}

- (void)_noteCollapseChange {
	BOOL collapsed = [self isLeadingPaneCollapsed];
	if (collapsed == leadingPaneWasCollapsed) return;
	leadingPaneWasCollapsed = collapsed;
	id<NVSplitViewDelegate> delegate = (id<NVSplitViewDelegate>)[self delegate];
	if ([delegate respondsToSelector:@selector(splitView:leadingPaneDidCollapse:)])
		[delegate splitView:self leadingPaneDidCollapse:collapsed];
}

//only divider clicks reach the split view itself
- (void)mouseDown:(NSEvent *)event {
	id<NVSplitViewDelegate> delegate = (id<NVSplitViewDelegate>)[self delegate];
	if ([event clickCount] > 1) {
		if ([delegate respondsToSelector:@selector(splitViewDidDoubleClickDivider:)])
			[delegate splitViewDidDoubleClickDivider:self];
		return;
	}
	if ([delegate respondsToSelector:@selector(splitViewWillTrackDivider:)])
		[delegate splitViewWillTrackDivider:self];

	CGFloat sizeBeforeTracking = [self expandedLeadingPaneSize];
	BOOL wasCollapsed = [self isLeadingPaneCollapsed];
	[super mouseDown:event];
	//a pane dragged closed should reopen where the drag began, not at the minimum size it passed through
	if (!wasCollapsed && [self isLeadingPaneCollapsed]) expandedLeadingPaneSize = sizeBeforeTracking;
	[self _noteCollapseChange];
}

@end
