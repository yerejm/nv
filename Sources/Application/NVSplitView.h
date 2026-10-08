#import <Cocoa/Cocoa.h>

@class NVSplitView;

@protocol NVSplitViewDelegate <NSSplitViewDelegate>
@optional
- (void)splitViewWillTrackDivider:(NVSplitView *)splitView;
- (void)splitViewDidDoubleClickDivider:(NVSplitView *)splitView;
- (void)splitView:(NVSplitView *)splitView leadingPaneDidCollapse:(BOOL)collapsed;
@end

//a two-pane split view whose leading pane can be collapsed and later expanded to its previous size
@interface NVSplitView : NSSplitView {
	NSColor *separatorColor;
	CGFloat expandedLeadingPaneSize;
	BOOL leadingPaneWasCollapsed;
}

@property (nonatomic, retain) NSColor *separatorColor;
@property (nonatomic, readonly, getter=isLeadingPaneCollapsed) BOOL leadingPaneCollapsed;
//the leading pane's width or height, or while collapsed, the size it expands to
@property (nonatomic) CGFloat expandedLeadingPaneSize;

- (void)setLeadingPaneCollapsed:(BOOL)collapsed;

@end
