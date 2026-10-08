#import <Cocoa/Cocoa.h>

//the nib the app would load for a localization: its Base xib with that language's strings
NSNib *NVLocalizedNib(NSString *resources, NSString *localization, NSString *name, NSString *scratchDirectory);
