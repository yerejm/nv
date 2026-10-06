#ifndef NV_APPKIT_H
#define NV_APPKIT_H

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>

static inline BOOL NVLoadNib(NSString *name, id owner) {
    NSArray *objects = nil;
    if (![[NSBundle mainBundle] loadNibNamed:name owner:owner topLevelObjects:&objects]) return NO;
    NSMutableDictionary *nibs = objc_getAssociatedObject(owner, @selector(loadNibNamed:owner:topLevelObjects:));
    if (!nibs) {
        nibs = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(owner, @selector(loadNibNamed:owner:topLevelObjects:), nibs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [nibs setObject:objects forKey:name];
    return YES;
}

static inline OSType NVOSTypeFromString(CFStringRef string) {
    char bytes[5];
    if (!string || CFStringGetLength(string) != 4 || !CFStringGetCString(string, bytes, sizeof(bytes), kCFStringEncodingMacRoman)) return 0;
    return (OSType)(unsigned char)bytes[0] << 24 | (OSType)(unsigned char)bytes[1] << 16 | (OSType)(unsigned char)bytes[2] << 8 | (OSType)(unsigned char)bytes[3];
}

static inline CFStringRef NVStringFromOSType(OSType type) {
    UInt8 bytes[] = { (UInt8)(type >> 24), (UInt8)(type >> 16), (UInt8)(type >> 8), (UInt8)type };
    return CFStringCreateWithBytes(NULL, bytes, sizeof(bytes), kCFStringEncodingMacRoman, false);
}

static inline NSAlert *NVMakeAlert(NSString *title, NSString *information, NSString *first, NSString *second, NSString *third) {
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setMessageText:title ?: @""];
    [alert setInformativeText:information ?: @""];
    [alert addButtonWithTitle:first ?: NSLocalizedString(@"OK", nil)];
    if (second) [alert addButtonWithTitle:second];
    if (third) [alert addButtonWithTitle:third];
    return alert;
}

static inline NSModalResponse NVRunAlert(NSAlertStyle style, NSString *title, NSString *information, NSString *first, NSString *second, NSString *third) {
    NSAlert *alert = NVMakeAlert(title, information, first, second, third);
    [alert setAlertStyle:style];
    return [alert runModal];
}

static inline void NVCompleteSheet(id delegate, SEL selector, id sheet, NSModalResponse response, void *context) {
    if (delegate && selector) ((void (*)(id, SEL, id, NSModalResponse, void *))objc_msgSend)(delegate, selector, sheet, response, context);
}

static inline void NVBeginSheet(NSWindow *sheet, NSWindow *parent, id delegate, SEL selector, void *context) {
    [parent beginSheet:sheet completionHandler:^(NSModalResponse response) {
        NVCompleteSheet(delegate, selector, sheet, response, context);
    }];
}

static inline void NVBeginAlertSheet(NSAlert *alert, NSWindow *parent, id delegate, SEL selector, void *context) {
    [alert beginSheetModalForWindow:parent completionHandler:^(NSModalResponse response) {
        NVCompleteSheet(delegate, selector, alert, response, context);
    }];
}

static inline void NVBeginPanel(NSSavePanel *panel, NSWindow *parent, id delegate, SEL selector, void *context) {
    [panel beginSheetModalForWindow:parent completionHandler:^(NSModalResponse response) {
        NVCompleteSheet(delegate, selector, panel, response, context);
    }];
}

static inline void NVSetPanelTypes(NSSavePanel *panel, NSArray *extensions) {
    NSMutableArray *types = [NSMutableArray array];
    for (NSString *extension in extensions) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if (type) [types addObject:type];
    }
    [panel setAllowedContentTypes:types];
}

static inline NSModalResponse NVRunOpenPanel(NSOpenPanel *panel, NSString *directory, NSString *name, NSArray *extensions) {
    if (directory) [panel setDirectoryURL:[NSURL fileURLWithPath:directory]];
    if (name) [panel setNameFieldStringValue:name];
    NVSetPanelTypes(panel, extensions);
    return [panel runModal];
}

static inline NSString *NVFormatCount(NSString *format, NSUInteger count) {
    NSString *wideFormat = [format stringByReplacingOccurrencesOfString:@"%d" withString:@"%lu"];
    return [NSString stringWithFormat:wideFormat, (unsigned long)count];
}

#endif
