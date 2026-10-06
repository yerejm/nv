#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "FrozenNotation.h"
#import "NotationPrefs.h"
#import "NSData_transformations.h"
#import "NSString_NV.h"
#import "WALController.h"

static NSString *Hex(NSData *data) {
    NSMutableString *result = [NSMutableString string];
    const unsigned char *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) [result appendFormat:@"%02x", bytes[index]];
    return result;
}

static BOOL LegacyEncrypt(NSMutableData *data, SEL selector, NSData *key, NSData *iv) {
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.launchPath = @"/usr/bin/openssl";
    task.arguments = @[@"enc", @"-aes-256-cbc", @"-K", Hex(key), @"-iv", Hex(iv)];
    NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    [task launch];
    [input.fileHandleForWriting writeData:data];
    [input.fileHandleForWriting closeFile];
    NSData *encrypted = [output.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) return NO;
    [data setData:encrypted];
    return YES;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        [NSApplication sharedApplication];
        NSString *directory = [NSString stringWithUTF8String:argv[1]];
        method_setImplementation(class_getInstanceMethod([NSMutableData class], @selector(encryptAESDataWithKey:iv:)), (IMP)LegacyEncrypt);
        NoteObject *note = [[[NoteObject alloc] initWithNoteBody:[[[NSAttributedString alloc] initWithString:@"Retained legacy content: café 日本語 😀\n[[Project Alpha]]\nhttps://example.com"] autorelease] title:@"Sanitized legacy note" delegate:nil format:SingleDatabaseFormat labels:@"fixture local"] autorelease];
        note->uniqueNoteIDBytes = [@"00112233-4455-6677-8899-AABBCCDDEEFF" uuidBytes];
        note->logSequenceNumber = 7;
        [note setSyncObjectAndKeyMD:@{ @"key": @"sanitized-retired-id", @"version": @7 } forService:@"Simplenote"];
        NotationPrefs *prefs = [[[NotationPrefs alloc] init] autorelease];
        [[prefs valueForKey:@"syncServiceAccounts"] setObject:[NSMutableDictionary dictionaryWithDictionary:@{ @"enabled": @YES, @"username": @"sanitized@example.invalid", @"frequency": @5 }] forKey:@"Simplenote"];
        NSMutableArray *notes = [NSMutableArray arrayWithObject:note];
        NSMutableSet *deletions = [NSMutableSet setWithObject:[DeletedNoteObject deletedNoteWithNote:note]];
        NSData *plain = [FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:deletions prefs:prefs];
        if (![plain writeToFile:[directory stringByAppendingPathComponent:@"legacy-plain.database"] atomically:YES]) return 3;
        [prefs setPassphraseData:[@"sanitized fixture password" dataUsingEncoding:NSUTF8StringEncoding] inKeychain:NO];
        [prefs setDoesEncryption:YES];
        NSData *encrypted = [FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:deletions prefs:prefs];
        if (![encrypted writeToFile:[directory stringByAppendingPathComponent:@"legacy-encrypted.database"] atomically:YES]) return 4;
        NSString *journalDirectory = [directory stringByAppendingPathComponent:@"journal-capture"];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:journalDirectory withIntermediateDirectories:YES attributes:nil error:NULL]) return 5;
        WALStorageController *writer = [[[WALStorageController alloc] initWithParentFSRep:journalDirectory.fileSystemRepresentation encryptionKey:[NSMutableData dataWithLength:32]] autorelease];
        if (![writer writeEstablishedNote:note] || ![writer writeRemovalForNote:note] || ![writer synchronize]) return 6;
        NSData *journal = [NSData dataWithContentsOfFile:[journalDirectory stringByAppendingPathComponent:@"Interim Note-Changes"]];
        if (![journal writeToFile:[directory stringByAppendingPathComponent:@"legacy-deletion.journal"] atomically:YES]) return 7;
        [[NSFileManager defaultManager] removeItemAtPath:journalDirectory error:NULL];
    }
    return 0;
}
