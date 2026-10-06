#import "AcceptanceEditorSession.h"
#include <signal.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSString *directory = [NSString stringWithUTF8String:argv[2]];
        if ([mode isEqualToString:@"--cleanup"])
            return NVCleanupAcceptanceEditor(directory) ? 0 : 1;
        if (![mode isEqualToString:@"--verify"]) return 2;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSString *path = [directory stringByAppendingPathComponent:@"Temporary editor verification.txt"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return 1;
        if (![@"Temporary acceptance document.\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) return 1;
        NVAcceptanceEditorSession *session = [[[NVAcceptanceEditorSession alloc] initWithDirectory:directory] autorelease];
        __block int interrupted = 0;
        NSMutableArray *signalSources = [NSMutableArray array];
        for (NSNumber *number in @[@(SIGINT), @(SIGTERM), @(SIGHUP)]) {
            int value = number.intValue;
            signal(value, SIG_IGN);
            dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, value, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(source, ^{
                interrupted = value;
                [session tearDown];
            });
            dispatch_resume(source);
            [signalSources addObject:source];
            dispatch_release(source);
        }
        BOOL opened = NO;
        BOOL background = NO;
        BOOL cleaned = NO;
        NSArray *existing = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.TextEdit"];
        @try {
            NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
            opened = [session openURLs:@[[NSURL fileURLWithPath:path]]
                withApplicationAtURL:[workspace URLForApplicationWithBundleIdentifier:@"com.apple.TextEdit"]
                workspace:workspace timeout:10];
            if (getenv("NV_EDITOR_TEST_HOLD_OPEN")) {
                NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
                while (!interrupted && limit.timeIntervalSinceNow > 0)
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            }
            NSDictionary *identity = [NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:@"external-editor.plist"]];
            NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:[identity[@"pid"] intValue]];
            NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:5];
            while (application && !application.finishedLaunching && limit.timeIntervalSinceNow > 0)
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            background = application && application.hidden && !application.active;
        } @finally {
            cleaned = [session tearDown] && NVCleanupAcceptanceEditor(directory);
            [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
            for (dispatch_source_t source in signalSources) dispatch_source_cancel(source);
        }
        BOOL existingPreserved = YES;
        for (NSRunningApplication *application in existing)
            if (application.terminated) existingPreserved = NO;
        printf("opened=%d background=%d cleaned=%d existingPreserved=%d\n", opened, background, cleaned, existingPreserved);
        if (interrupted) return cleaned ? 128 + interrupted : 1;
        return opened && background && cleaned && existingPreserved ? 0 : 1;
    }
}
