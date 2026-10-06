#import <Cocoa/Cocoa.h>

BOOL NVAcceptanceEditorMatchesIdentity(NSRunningApplication *application, NSDictionary *identity);
BOOL NVStopAcceptanceEditor(NSRunningApplication *application, NSDictionary *identity, NSTimeInterval timeout);
BOOL NVCleanupAcceptanceEditor(NSString *directory);

@interface NVAcceptanceEditorSession : NSObject {
    NSString *_directory;
    NSRunningApplication *_application;
    NSDictionary *_identity;
    BOOL _opening;
    BOOL _finishedOpening;
    BOOL _teardownRequested;
    BOOL _openedSuccessfully;
}
- (id)initWithDirectory:(NSString *)directory;
- (BOOL)openURLs:(NSArray *)URLs withApplicationAtURL:(NSURL *)applicationURL workspace:(NSWorkspace *)workspace timeout:(NSTimeInterval)timeout;
- (BOOL)tearDown;
@end
