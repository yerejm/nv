#import "CompiledNib.h"

static BOOL CompileXib(NSString *xib, NSString *output) {
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[@"ibtool", @"--minimum-deployment-target", @"15.0", @"--compile", output, xib];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) return NO;
    [task waitUntilExit];
    return task.terminationStatus == 0;
}

//Base nibs take their text from the strings file of the bundle's localization when they load, so each language gets a bundle of its own
static NSNib *BaseLocalizedNib(NSString *xib, NSString *strings, NSString *localization, NSString *name, NSString *scratchDirectory) {
    NSString *contents = [[[scratchDirectory stringByAppendingPathComponent:[NSUUID UUID].UUIDString] stringByAppendingPathExtension:@"bundle"] stringByAppendingPathComponent:@"Contents"];
    NSString *resources = [contents stringByAppendingPathComponent:@"Resources"];
    NSString *base = [resources stringByAppendingPathComponent:@"Base.lproj"];
    NSString *localized = [resources stringByAppendingPathComponent:[localization stringByAppendingPathExtension:@"lproj"]];
    NSFileManager *files = [NSFileManager defaultManager];
    [files createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:NULL];
    [files createDirectoryAtPath:localized withIntermediateDirectories:YES attributes:nil error:NULL];
    [@{@"CFBundleIdentifier": [@"net.notational.velocity.layout." stringByAppendingString:[NSUUID UUID].UUIDString],
       @"CFBundleDevelopmentRegion": localization, @"CFBundlePackageType": @"BNDL"} writeToFile:[contents stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
    if (!CompileXib(xib, [base stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"nib"]])) return nil;
    if (strings) [files copyItemAtPath:strings toPath:[localized stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"strings"]] error:NULL];
    NSBundle *bundle = [NSBundle bundleWithPath:[contents stringByDeletingLastPathComponent]];
    return [[[NSNib alloc] initWithNibNamed:name bundle:bundle] autorelease];
}

NSNib *NVLocalizedNib(NSString *resources, NSString *localization, NSString *name, NSString *scratchDirectory) {
    NSString *base = [[resources stringByAppendingPathComponent:@"Base.lproj"] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"xib"]];
    NSString *strings = [[resources stringByAppendingPathComponent:[localization stringByAppendingPathExtension:@"lproj"]] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"strings"]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:base]) return nil;
    return BaseLocalizedNib(base, [[NSFileManager defaultManager] fileExistsAtPath:strings] ? strings : nil, localization, name, scratchDirectory);
}
