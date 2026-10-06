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


#import "AugmentedScrollView.h"
#import "GlobalPrefs.h"

@implementation AugmentedScrollView
- (void)awakeFromNib {
    [[GlobalPrefs defaultPrefs] registerWithTarget:self forChangesInSettings:
        @selector(setUseThemedScrollbars:sender:), @selector(setForegroundTextColor:sender:), @selector(setBackgroundTextColor:sender:), nil];
    NVConfigureScrolling(self);
}
- (void)settingChangedForSelectorString:(NSString *)selector {
    NVConfigureScrolling(self);
}
@end

@implementation NVOverlayScroller
+ (BOOL)isCompatibleWithOverlayScrollers { return YES; }
- (void)drawKnob {
    NSRect rect = [self rectForPart:NSScrollerKnob];
    rect = NSInsetRect(rect, 2, 2);
    NSColor *color = [[[GlobalPrefs defaultPrefs] foregroundTextColor] colorWithAlphaComponent:self.enabled ? 0.55 : 0.2];
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:5 yRadius:5] fill];
}
- (void)drawKnobSlotInRect:(NSRect)rect highlight:(BOOL)highlight {
    [[[[GlobalPrefs defaultPrefs] foregroundTextColor] colorWithAlphaComponent:highlight ? 0.12 : 0.06] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect, 2, 2) xRadius:5 yRadius:5] fill];
}
@end

void NVConfigureScrolling(NSScrollView *scrollView) {
    if (!scrollView) return;
    BOOL themed = [[GlobalPrefs defaultPrefs] useThemedScrollbars];
    Class scrollerClass = themed ? [NVOverlayScroller class] : [NSScroller class];
    if ([scrollView.verticalScroller class] != scrollerClass) {
        NSScroller *scroller = [[[scrollerClass alloc] initWithFrame:scrollView.verticalScroller.frame] autorelease];
        [scrollView setVerticalScroller:scroller];
    }
    [scrollView setScrollerStyle:themed ? NSScrollerStyleOverlay : [NSScroller preferredScrollerStyle]];
    [scrollView setVerticalScrollElasticity:NSScrollElasticityAllowed];
    [scrollView setHorizontalScrollElasticity:NSScrollElasticityNone];
    [scrollView.verticalScroller setControlSize:NSControlSizeRegular];
    [scrollView.verticalScroller setNeedsDisplay:YES];
}
