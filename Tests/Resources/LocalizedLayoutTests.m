#import <XCTest/XCTest.h>
#import "TestPaths.h"
#import "CompiledNib.h"
#import "GlobalPrefs.h"

//stands in for each nib's owner so windows load without the controllers that normally run them
@interface LayoutNibOwner : NSObject
@end
@implementation LayoutNibOwner
- (void)setValue:(id)value forUndefinedKey:(NSString *)key {}
- (id)valueForUndefinedKey:(NSString *)key { return nil; }
@end

static NSString *ControlText(NSControl *control) {
    return [control isKindOfClass:[NSButton class]] ? [(NSButton *)control title] : [control stringValue];
}

static BOOL CellOverflows(NSCell *cell, NSSize available) {
    BOOL wraps = [cell wraps] || [cell lineBreakMode] == NSLineBreakByWordWrapping || [cell lineBreakMode] == NSLineBreakByCharWrapping;
    if (wraps) return [cell cellSizeForBounds:NSMakeRect(0, 0, available.width, CGFLOAT_MAX)].height > available.height + 1;
    return [cell cellSize].width > available.width + 1;
}

//hidden controls are checked too, since code shows them
static void CollectClippedText(NSView *view, NSString *path, NSMutableOrderedSet *problems) {
    NSString *here = [path stringByAppendingFormat:@"/%@", NSStringFromClass([view class])];
    BOOL label = [view isKindOfClass:[NSTextField class]] && ![(NSTextField *)view isEditable];
    BOOL button = [view isKindOfClass:[NSButton class]] && ![view isKindOfClass:[NSPopUpButton class]];
    if ((label || button) && [ControlText((NSControl *)view) length] && CellOverflows([(NSControl *)view cell], [view bounds].size))
        [problems addObject:[NSString stringWithFormat:@"%@ \"%@\" needs %@ in %@", here, ControlText((NSControl *)view),
                             NSStringFromSize([[(NSControl *)view cell] cellSize]), NSStringFromSize([view bounds].size)]];
    if (![view translatesAutoresizingMaskIntoConstraints] && ![NSStringFromClass([view class]) hasPrefix:@"_"] && [view hasAmbiguousLayout])
        [problems addObject:[NSString stringWithFormat:@"%@ has an ambiguous layout", here]];
    for (NSView *subview in [view subviews]) CollectClippedText(subview, here, problems);
}

//drawn in the light appearance on an opaque window-colored ground, so text is visible whatever the system appearance
static NSData *SnapshotPNG(NSView *root) {
    NSAppearance *aqua = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [root setAppearance:aqua];
    [root layoutSubtreeIfNeeded];
    NSBitmapImageRep *bitmap = [root bitmapImageRepForCachingDisplayInRect:[root bounds]];
    [root cacheDisplayInRect:[root bounds] toBitmapImageRep:bitmap];
    NSBitmapImageRep *opaque = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:[bitmap pixelsWide] pixelsHigh:[bitmap pixelsHigh]
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:opaque]];
    NSRect pixels = NSMakeRect(0, 0, [bitmap pixelsWide], [bitmap pixelsHigh]);
    [aqua performAsCurrentDrawingAppearance:^{
        [[NSColor windowBackgroundColor] setFill];
        NSRectFill(pixels);
    }];
    [bitmap drawInRect:pixels fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:nil];
    [NSGraphicsContext restoreGraphicsState];
    return [opaque representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static NSArray *TabViews(NSView *view) {
    NSMutableArray *found = [NSMutableArray array];
    if ([view isKindOfClass:[NSTabView class]]) [found addObject:view];
    for (NSView *subview in [view subviews]) [found addObjectsFromArray:TabViews(subview)];
    return found;
}

static NSArray *LayoutNibNames(NSString *resources) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[resources stringByAppendingPathComponent:@"Base.lproj"] error:NULL])
        if ([[file pathExtension] isEqualToString:@"xib"] && ![file hasPrefix:@"MainMenu"]) [names addObject:[file stringByDeletingPathExtension]];
    return [names sortedArrayUsingSelector:@selector(compare:)];
}

@interface LocalizedLayoutTests : XCTestCase
@end

@implementation LocalizedLayoutTests

- (void)testLocalizedTextFitsItsControls {
    [NSApplication sharedApplication];
    [GlobalPrefs defaultPrefs];
    NSString *resources = NVResourcesDirectory();
    NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *snapshots = [[[NVTestsDirectory() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"build"] stringByAppendingPathComponent:@"localized-layout"];
    [[NSFileManager defaultManager] createDirectoryAtPath:scratch withIntermediateDirectories:YES attributes:nil error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:snapshots withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableOrderedSet *problems = [NSMutableOrderedSet orderedSet];
    for (NSString *name in LayoutNibNames(resources)) {
        for (NSString *localization in @[@"en", @"de", @"fr", @"it", @"pt", @"zh_CN"]) {
            NSNib *nib = NVLocalizedNib(resources, localization, name, scratch);
            NSArray *objects = nil;
            if (![nib instantiateWithOwner:[[LayoutNibOwner alloc] init] topLevelObjects:&objects]) {
                [problems addObject:[NSString stringWithFormat:@"%@ %@ did not load", localization, name]];
                continue;
            }
            NSUInteger index = 0;
            for (id object in objects) {
                NSView *root = [object isKindOfClass:[NSWindow class]] ? [object contentView] : [object isKindOfClass:[NSView class]] ? object : nil;
                if (!root) continue;
                //as their controllers do: tab views fit their largest page, and views placed by code fit their content
                for (NSTabView *tabs in TabViews(root)) NVSizeTabViewToLargestPage(tabs);
                void (^layOut)(void) = ^{
                    if ([object isKindOfClass:[NSWindow class]]) [object layoutIfNeeded];
                    else {
                        if ([[root constraints] count]) [root setFrameSize:[root fittingSize]];
                        [root layoutSubtreeIfNeeded];
                    }
                };
                layOut();
                NSString *path = [NSString stringWithFormat:@"%@ %@", localization, name];
                CollectClippedText(root, path, problems);
                for (NSTabView *tabs in TabViews(root)) {
                    for (NSTabViewItem *item in [tabs tabViewItems]) {
                        [tabs selectTabViewItem:item];
                        layOut();
                        CollectClippedText([item view], [path stringByAppendingFormat:@"[%@]", [item identifier]], problems);
                    }
                    [tabs selectFirstTabViewItem:nil];
                    layOut();
                }
                [[NSFileManager defaultManager] createFileAtPath:[snapshots stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%lu-%@.png", name, (unsigned long)index++, localization]]
                                                        contents:SnapshotPNG(root) attributes:nil];
                if ([object isKindOfClass:[NSWindow class]]) {
                    [object setReleasedWhenClosed:NO];
                    [object close];
                }
            }
        }
    }
    [[NSFileManager defaultManager] removeItemAtPath:scratch error:NULL];
    XCTAssertEqual(problems.count, 0U, @"%@", [[problems array] componentsJoinedByString:@"\n"]);
}

@end
