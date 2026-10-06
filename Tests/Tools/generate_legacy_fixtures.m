#import <Cocoa/Cocoa.h>
#import "DeletedNoteObject.h"
#import "broken_md5.h"

@interface FixtureNote : NSObject <SynchronizedNote> {
    CFUUIDBytes identity;
}
@end
@implementation FixtureNote
- (id)init {
    if ((self = [super init])) {
        CFUUIDRef uuid = CFUUIDCreateFromString(NULL, CFSTR("00112233-4455-6677-8899-AABBCCDDEEFF"));
        identity = CFUUIDGetUUIDBytes(uuid);
        CFRelease(uuid);
    }
    return self;
}
- (CFUUIDBytes *)uniqueNoteIDBytes { return &identity; }
- (NSDictionary *)syncServicesMD { return @{ @"Simplenote": @{ @"key": @"sanitized-retired-id", @"version": @7 } }; }
- (unsigned int)logSequenceNumber { return 42; }
- (void)incrementLSN {}
- (BOOL)youngerThanLogObject:(id<SynchronizedNote>)note { return 42 < [note logSequenceNumber]; }
- (void)setSyncObjectAndKeyMD:(NSDictionary *)metadata forService:(NSString *)service {}
- (void)removeAllSyncMDForService:(NSString *)service {}
- (void)encodeWithCoder:(NSCoder *)coder {}
- (id)initWithCoder:(NSCoder *)coder { return [self init]; }
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        FixtureNote *note = [[[FixtureNote alloc] init] autorelease];
        DeletedNoteObject *deleted = [DeletedNoteObject deletedNoteWithNote:note];
        if (![[NSKeyedArchiver archivedDataWithRootObject:deleted] writeToFile:[directory stringByAppendingPathComponent:@"deleted-keyed.archive"] atomically:YES]) return 3;
        if (![[NSArchiver archivedDataWithRootObject:deleted] writeToFile:[directory stringByAppendingPathComponent:@"deleted-positional.archive"] atomically:YES]) return 4;
        const unsigned char input[] = "legacy import: café 日本語";
        unsigned char digest[16];
        BrokenMD5_CTX context;
        BrokenMD5Init(&context);
        BrokenMD5Update(&context, input, sizeof(input) - 1);
        BrokenMD5Final(digest, &context);
        NSMutableString *hex = [NSMutableString string];
        for (NSUInteger index = 0; index < sizeof(digest); index++) [hex appendFormat:@"%02x", digest[index]];
        [hex writeToFile:[directory stringByAppendingPathComponent:@"broken-md5.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return 0;
}
