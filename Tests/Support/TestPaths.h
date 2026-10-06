#import <Foundation/Foundation.h>

static inline NSString *NVTestsDirectory(void) {
    return [[@__FILE__ stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
}

static inline NSString *NVFixturePath(NSString *name) {
    return [[NVTestsDirectory() stringByAppendingPathComponent:@"Fixtures"] stringByAppendingPathComponent:name];
}

static inline NSString *NVResourcesDirectory(void) {
    return [[NVTestsDirectory() stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Resources"];
}
