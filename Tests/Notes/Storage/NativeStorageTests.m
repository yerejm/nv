#import <XCTest/XCTest.h>
#import "TestPaths.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "FrozenNotation.h"
#import "NotationPrefs.h"
#import "NotationFileManager.h"
#import "NotationDirectoryManager.h"
#include <sys/stat.h>
#include <sys/xattr.h>
#import "NSData_transformations.h"
#import "NSString_NV.h"
#import "GlobalPrefs.h"
#import "WALController.h"
#import "BlorPasswordRetriever.h"
#import "ODBEditor.h"
#import "ODBEditorSuite.h"

@interface ODBEditor (Acceptance)
- (void)handleModifiedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply;
- (void)handleClosedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply;
@end

@interface NativeStorageTests : XCTestCase
@property(nonatomic, retain) NSString *temporaryDirectory;
@end
@implementation NativeStorageTests
- (void)setUp {
    [super setUp];
    [NSApplication sharedApplication];
    self.temporaryDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:self.temporaryDirectory withIntermediateDirectories:YES attributes:nil error:NULL]);
}
- (void)tearDown {
    [NSObject cancelPreviousPerformRequestsWithTarget:[GlobalPrefs defaultPrefs]];
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:self.temporaryDirectory error:NULL]);
    self.temporaryDirectory = nil;
    [super tearDown];
}
- (NoteObject *)sampleNote {
    NoteObject *note = [[[NoteObject alloc] initWithNoteBody:[[[NSAttributedString alloc] initWithString:@"Retained content: café 日本語 😀\n[[Project Alpha]]\nhttps://example.com"] autorelease] title:@"Sanitized legacy note" delegate:nil format:SingleDatabaseFormat labels:@"fixture local"] autorelease];
    note->uniqueNoteIDBytes = [@"00112233-4455-6677-8899-AABBCCDDEEFF" uuidBytes];
    note->logSequenceNumber = 7;
    [note setSyncObjectAndKeyMD:@{ @"key": @"sanitized-retired-id", @"version": @7 } forService:@"Simplenote"];
    return note;
}
- (void)testFileReferenceTracksRenameAndRejectsReplacement {
    NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:@"original.txt"];
    NSString *renamed = [self.temporaryDirectory stringByAppendingPathComponent:@"renamed.txt"];
    XCTAssertTrue([@"original" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    NVFileReference reference;
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)path.fileSystemRepresentation, &reference, NULL), noErr);
    XCTAssertTrue([[NSFileManager defaultManager] moveItemAtPath:path toPath:renamed error:NULL]);
    XCTAssertTrue([@"replacement" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    UInt8 resolved[PATH_MAX];
    XCTAssertEqual(NVReferenceMakePath(&reference, resolved, sizeof(resolved)), noErr);
    char expected[PATH_MAX];
    XCTAssertNotEqual(realpath(renamed.fileSystemRepresentation, expected), NULL);
    XCTAssertEqual(strcmp((const char *)resolved, expected), 0);
    XCTAssertTrue([[NSFileManager defaultManager] removeItemAtPath:renamed error:NULL]);
    XCTAssertEqual(NVReferenceMakePath(&reference, resolved, sizeof(resolved)), fnfErr);
}
- (void)testUnicodeFilenameAndEmptyFileIO {
    NVFileReference directory, file;
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)self.temporaryDirectory.fileSystemRepresentation, &directory, NULL), noErr);
    NSString *name = @"café 日本語 / test.txt";
    UniChar characters[255];
    [name getCharacters:characters range:NSMakeRange(0, name.length)];
    XCTAssertEqual(NVCreateFileUnicode(&directory, name.length, characters, 0, NULL, &file, NULL), noErr);
    HFSUniStr255 catalogName;
    XCTAssertEqual(NVGetCatalogInfo(&file, 0, NULL, &catalogName, NULL, NULL), noErr);
    XCTAssertEqualObjects([NSString stringWithCharacters:catalogName.unicode length:catalogName.length], name);
    UInt64 length = 0;
    void *bytes = NULL;
    XCTAssertEqual(NVReadFile(&file, 4096, &length, &bytes, 0), noErr);
    XCTAssertEqual(length, 0ULL);
    free(bytes);
    NSData *content = [@"short" dataUsingEncoding:NSUTF8StringEncoding];
    XCTAssertEqual(NVWriteFile(&file, 2, content.length, content.bytes, 0, true), noErr);
    XCTAssertEqual(NVWriteFile(&file, 2, 0, NULL, 0, true), noErr);
    XCTAssertEqual(NVReadFile(&file, 4096, &length, &bytes, 0), noErr);
    XCTAssertEqual(length, 0ULL);
    free(bytes);
}
- (void)testBookmarkResolvesAfterDirectoryRename {
    NSString *path = [self.temporaryDirectory stringByAppendingPathComponent:@"notes"];
    NSString *renamed = [self.temporaryDirectory stringByAppendingPathComponent:@"renamed notes"];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:NULL]);
    NVFileReference directory, resolved;
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)path.fileSystemRepresentation, &directory, NULL), noErr);
    NSData *bookmark = [NSData aliasDataForFSRef:&directory];
    XCTAssertNotNil(bookmark);
    XCTAssertTrue([[NSFileManager defaultManager] moveItemAtPath:path toPath:renamed error:NULL]);
    XCTAssertTrue([bookmark fsRefAsAlias:&resolved]);
    XCTAssertEqual(NVCompareReferences(&directory, &resolved), noErr);
}
- (void)testAtomicExchangePreservesDestinationMetadata {
    NSString *sourcePath = [self.temporaryDirectory stringByAppendingPathComponent:@"temporary"];
    NSString *destinationPath = [self.temporaryDirectory stringByAppendingPathComponent:@"note.txt"];
    XCTAssertTrue([@"new contents" writeToFile:sourcePath atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"old contents" writeToFile:destinationPath atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertEqual(chmod(destinationPath.fileSystemRepresentation, 0640), 0);
    const char metadata[] = "retained metadata";
    XCTAssertEqual(setxattr(destinationPath.fileSystemRepresentation, "com.notational.velocity.test", metadata, sizeof(metadata), 0, 0), 0);
    NVFileReference source, destination, newSource, newDestination;
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)sourcePath.fileSystemRepresentation, &source, NULL), noErr);
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)destinationPath.fileSystemRepresentation, &destination, NULL), noErr);
    XCTAssertEqual(NVExchangeFiles(&source, &destination, &newSource, &newDestination), noErr);
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:destinationPath encoding:NSUTF8StringEncoding error:NULL], @"new contents");
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:NULL], @"old contents");
    struct stat attributes;
    XCTAssertEqual(stat(destinationPath.fileSystemRepresentation, &attributes), 0);
    XCTAssertEqual(attributes.st_mode & 0777, 0640);
    char actualMetadata[sizeof(metadata)];
    XCTAssertEqual(getxattr(destinationPath.fileSystemRepresentation, "com.notational.velocity.test", actualMetadata, sizeof(actualMetadata), 0, 0), (ssize_t)sizeof(metadata));
    XCTAssertEqual(memcmp(metadata, actualMetadata, sizeof(metadata)), 0);
    XCTAssertEqual(NVDeleteObject(&newSource), noErr);
    XCTAssertEqual(NVExchangeFiles(&newSource, &newDestination, NULL, NULL), fnfErr);
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:destinationPath encoding:NSUTF8StringEncoding error:NULL], @"new contents");
}
- (void)testExchangeFallbackPreservesBothFiles {
    NSString *sourcePath = [self.temporaryDirectory stringByAppendingPathComponent:@"temporary"];
    NSString *destinationPath = [self.temporaryDirectory stringByAppendingPathComponent:@"note.txt"];
    XCTAssertTrue([@"new contents" writeToFile:sourcePath atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"old contents" writeToFile:destinationPath atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    NVFileReference source, destination, newSource, newDestination;
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)sourcePath.fileSystemRepresentation, &source, NULL), noErr);
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)destinationPath.fileSystemRepresentation, &destination, NULL), noErr);
    XCTAssertEqual(NVExchangeFilesByRenaming(&source, &destination, &newSource, &newDestination), noErr);
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:destinationPath encoding:NSUTF8StringEncoding error:NULL], @"new contents");
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:NULL], @"old contents");
    XCTAssertEqual(NVCompareReferences(&source, &newDestination), noErr);
    XCTAssertEqual(NVCompareReferences(&destination, &newSource), noErr);
}
- (NotationController *)controller {
    NVFileReference directory;
    OSStatus error = NVPathMakeReference((const UInt8 *)self.temporaryDirectory.fileSystemRepresentation, &directory, NULL);
    XCTAssertEqual(error, noErr);
    NotationController *controller = [[[NotationController alloc] initWithDirectoryRef:&directory error:&error] autorelease];
    XCTAssertEqual(error, noErr);
    XCTAssertNotNil(controller);
    [controller setUndoManager:[[[NSUndoManager alloc] init] autorelease]];
    return controller;
}
- (void)testSingleDatabasePersistenceAndIdentity {
    NotationController *controller = [self controller];
    NoteObject *note = [self sampleNote];
    [controller addNewNote:note];
    XCTAssertTrue([controller flushAllNoteChanges]);
    [controller closeJournal];
    [controller stopFileNotifications];
    NotationController *reopened = [self controller];
    NoteObject *loaded = [reopened noteForUUIDBytes:[note uniqueNoteIDBytes]];
    XCTAssertEqualObjects(loaded->titleString, note->titleString);
    XCTAssertEqualObjects(loaded->contentString.string, note->contentString.string);
    XCTAssertTrue([reopened flushAllNoteChanges]);
    [reopened closeJournal];
    [reopened stopFileNotifications];
}
- (void)testPlainTextStorageAndLocalFileMonitoring {
    NotationController *controller = [self controller];
    [[controller notationPrefs] setNotesStorageFormat:PlainTextFormat];
    NoteObject *note = [self sampleNote];
    [controller addNewNote:note];
    XCTAssertTrue([controller flushAllNoteChanges]);
    NSString *filename = [note noteFilePath];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:filename]);
    XCTAssertTrue([@"Externally edited local content\n" writeToFile:filename atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    [controller synchronizeNotesFromDirectory];
    XCTAssertTrue([note->contentString.string containsString:@"Externally edited local content"]);
    XCTAssertTrue([controller flushAllNoteChanges]);
    [controller closeJournal];
    [controller stopFileNotifications];
}
- (void)testJournalEditAndDeletionRecovery {
    NoteObject *note = [self sampleNote];
    NSData *key = [NSMutableData dataWithLength:32];
    WALStorageController *writer = [[[WALStorageController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key] autorelease];
    XCTAssertNotNil(writer);
    XCTAssertTrue([writer writeEstablishedNote:note]);
    [note->contentString replaceCharactersInRange:NSMakeRange(0, note->contentString.length) withString:@"journal edit"];
    XCTAssertTrue([writer writeEstablishedNote:note]);
    XCTAssertTrue([writer writeRemovalForNote:note]);
    XCTAssertTrue([writer synchronize]);
    WALRecoveryController *reader = [[[WALRecoveryController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key] autorelease];
    NSDictionary *recovered = [reader recoveredNotes];
    XCTAssertEqual(recovered.count, 1U);
    DeletedNoteObject *deletion = [recovered.allValues firstObject];
    XCTAssertTrue([deletion isKindOfClass:[DeletedNoteObject class]]);
    XCTAssertEqual([deletion logSequenceNumber], [note logSequenceNumber]);
    XCTAssertEqual(memcmp([deletion uniqueNoteIDBytes], [note uniqueNoteIDBytes], sizeof(CFUUIDBytes)), 0);
}
- (void)testEncryptionPasswordVerifierAndStorageEnvelope {
    NotationPrefs *prefs = [[[NotationPrefs alloc] init] autorelease];
    [prefs setPassphraseData:[@"sanitized fixture password" dataUsingEncoding:NSUTF8StringEncoding] inKeychain:NO];
    XCTAssertTrue([prefs canLoadPassphrase:@"sanitized fixture password"]);
    XCTAssertFalse([prefs canLoadPassphrase:@"wrong password"]);
    [prefs setDoesEncryption:YES];
    NSData *archive = [FrozenNotation frozenDataWithExistingNotes:[NSMutableArray arrayWithObject:[self sampleNote]] deletedNotes:[NSMutableSet set] prefs:prefs];
    FrozenNotation *frozen = NVUnarchiveObject(archive);
    XCTAssertTrue([[frozen notationPrefs] canLoadPassphrase:@"sanitized fixture password"]);
    OSStatus error;
    NSArray *notes = [frozen unpackedNotesWithPrefs:[frozen notationPrefs] returningError:&error];
    XCTAssertEqual(error, noErr);
    XCTAssertEqual(notes.count, 1U);
    XCTAssertEqualObjects(((NoteObject *)notes[0])->titleString, @"Sanitized legacy note");
}
- (void)testODBSaveAndCloseCallbacksPreserveLocalNoteIdentity {
    NotationController *controller = [self controller];
    NoteObject *note = [self sampleNote];
    [controller addNewNote:note];
    CFUUIDBytes identity = *note.uniqueNoteIDBytes;
    NSString *filename = [self.temporaryDirectory stringByAppendingPathComponent:@"External edit.txt"];
    XCTAssertTrue([@"ODB saved content: café 日本語\n" writeToFile:filename atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    ODBEditor *editor = [ODBEditor sharedODBEditor];
    NSMutableDictionary *sessions = [editor valueForKey:@"_filePathsBeingEdited"];
    NSString *resolved = filename.stringByResolvingSymlinksInPath;
    sessions[resolved] = @{@"ODBEditorNonRetainedClient": [NSValue valueWithNonretainedObject:note],
                           @"ODBEditorFileName": resolved, @"ODBEditorIsEditingString": @NO};
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kODBEditorSuite eventID:kAEModifiedFile targetDescriptor:nil returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithDescriptorType:typeFileURL data:[[NSURL fileURLWithPath:filename].absoluteString dataUsingEncoding:NSUTF8StringEncoding]] forKeyword:keyDirectObject];
    [editor handleModifiedFileEvent:event withReplyEvent:nil];
    XCTAssertEqualObjects(note->contentString.string, @"ODB saved content: café 日本語\n");
    XCTAssertEqual(memcmp(note.uniqueNoteIDBytes, &identity, sizeof(identity)), 0);
    XCTAssertTrue([controller flushAllNoteChanges]);
    [editor handleClosedFileEvent:event withReplyEvent:nil];
    XCTAssertNil(sessions[resolved]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:filename]);
    [controller closeAllResources];
}
- (void)testEncryptionKeychainUsesNewDatabaseIdentity {
    NotationPrefs *prefs = [[[NotationPrefs alloc] init] autorelease];
    NSData *password = [@"sanitized temporary Keychain password" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *account = [NSString stringWithUTF8String:[prefs setKeychainIdentifier]];
    XCTAssertNotNil([[[NSUUID alloc] initWithUUIDString:account] autorelease]);
    @try {
        [prefs setPassphraseData:password inKeychain:YES];
        XCTAssertEqualObjects([prefs passwordDataFromKeychain], password);
        XCTAssertTrue([prefs canLoadPassphraseData:[prefs passwordDataFromKeychain]]);
    } @finally {
        [prefs setStoresPasswordInKeychain:NO];
        XCTAssertEqual([prefs currentKeychainItem], NULL);
    }
}
- (void)testStartupRecoversUnsavedEditAndDeletion {
    NotationController *controller = [self controller];
    NoteObject *edited = [self sampleNote];
    NoteObject *removed = [[[NoteObject alloc] initWithNoteBody:[[[NSAttributedString alloc] initWithString:@"Removed after the last save"] autorelease] title:@"Recovery deletion" delegate:nil format:SingleDatabaseFormat labels:nil] autorelease];
    [removed setSyncObjectAndKeyMD:@{@"key": @"retired-deletion-id"} forService:@"Simplenote"];
    [controller addNewNote:edited];
    [controller addNewNote:removed];
    XCTAssertTrue([controller flushAllNoteChanges]);
    NSData *key = [[controller notationPrefs] WALSessionKey];
    CFUUIDBytes removedID = *[removed uniqueNoteIDBytes];
    CFUUIDBytes editedID = *[edited uniqueNoteIDBytes];
    [controller closeAllResources];
    WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key];
    [edited->contentString replaceCharactersInRange:NSMakeRange(0, edited->contentString.length) withString:@"Recovered unsaved edit"];
    XCTAssertTrue([writer writeEstablishedNote:edited]);
    XCTAssertTrue([writer writeRemovalForNote:removed]);
    XCTAssertTrue([writer synchronize]);
    [writer release];
    NotationController *reopened = [self controller];
    NoteObject *recovered = [reopened noteForUUIDBytes:&editedID];
    XCTAssertEqualObjects(recovered->contentString.string, @"Recovered unsaved edit");
    XCTAssertNil([reopened noteForUUIDBytes:&removedID]);
    XCTAssertTrue([reopened flushAllNoteChanges]);
    [reopened closeAllResources];
}
- (NSData *)fixture:(NSString *)name {
    NSString *directory = NVFixturePath(@"");
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
    XCTAssertNotNil(data);
    return data;
}
- (void)checkLegacyDatabase:(NSString *)name encrypted:(BOOL)encrypted {
    FrozenNotation *frozen = NVUnarchiveObject([self fixture:name]);
    NotationPrefs *prefs = [frozen notationPrefs];
    XCTAssertEqual([prefs doesEncryption], encrypted);
    if (encrypted) {
        XCTAssertFalse([prefs canLoadPassphrase:@"wrong password"]);
        XCTAssertTrue([prefs canLoadPassphrase:@"sanitized fixture password"]);
    }
    OSStatus error;
    NSArray *notes = [frozen unpackedNotesWithPrefs:prefs returningError:&error];
    XCTAssertEqual(error, noErr);
    XCTAssertEqual(notes.count, 1U);
    if (notes.count != 1) return;
    NoteObject *note = notes[0];
    XCTAssertEqualObjects(note->titleString, @"Sanitized legacy note");
    XCTAssertEqualObjects(note->labelString, @"fixture local");
    XCTAssertEqualObjects(note->contentString.string, @"Retained legacy content: café 日本語 😀\n[[Project Alpha]]\nhttps://example.com");
    XCTAssertEqualObjects([NSString uuidStringWithBytes:*[note uniqueNoteIDBytes]], @"00112233-4455-6677-8899-AABBCCDDEEFF");
    XCTAssertEqual([note logSequenceNumber], 7U);
    XCTAssertEqualObjects([note syncServicesMD][@"Simplenote"][@"key"], @"sanitized-retired-id");
    XCTAssertEqual([frozen deletedNotes].count, 1U);
    XCTAssertTrue([[[frozen deletedNotes] anyObject] isKindOfClass:[DeletedNoteObject class]]);
}
- (void)testFixedLegacyUnencryptedDatabase {
    [self checkLegacyDatabase:@"legacy-plain.database" encrypted:NO];
}
- (void)testFixedLegacyEncryptedDatabase {
    [self checkLegacyDatabase:@"legacy-encrypted.database" encrypted:YES];
}
- (void)testRetiredMetadataSurvivesArchiveAndLocalIdentityLinks {
    FrozenNotation *frozen = NVUnarchiveObject([self fixture:@"legacy-plain.database"]);
    NotationPrefs *prefs = [frozen notationPrefs];
    NSDictionary *accounts = [[prefs.syncServiceAccounts copy] autorelease];
    XCTAssertTrue([accounts[@"Simplenote"][@"enabled"] boolValue]);
    OSStatus error;
    NSMutableArray *notes = [frozen unpackedNotesWithPrefs:prefs returningError:&error];
    NoteObject *note = notes.firstObject;
    NSDictionary *metadata = [[note.syncServicesMD copy] autorelease];
    NSString *identity = nil;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:note.uniqueNoteLink resolvingAgainstBaseURL:NO].queryItems)
        if ([item.name isEqualToString:@"NV"]) identity = item.value;
    XCTAssertEqualObjects([identity decodeBase64WithNewlines:NO], [NSData dataWithBytes:note.uniqueNoteIDBytes length:16]);
    NSData *saved = [FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:[frozen deletedNotes] prefs:prefs];
    FrozenNotation *reloaded = NVUnarchiveObject(saved);
    NSArray *loaded = [reloaded unpackedNotesWithPrefs:[reloaded notationPrefs] returningError:&error];
    XCTAssertEqualObjects([[reloaded notationPrefs] syncServiceAccounts], accounts);
    XCTAssertEqualObjects([(NoteObject *)loaded.firstObject syncServicesMD], metadata);
    XCTAssertEqualObjects(prefs.syncServiceAccounts, accounts);
}
- (void)testFixedLegacyJournalDeletion {
    NSString *journal = [self.temporaryDirectory stringByAppendingPathComponent:@"Interim Note-Changes"];
    XCTAssertTrue([[self fixture:@"legacy-deletion.journal"] writeToFile:journal atomically:YES]);
    WALRecoveryController *reader = [[[WALRecoveryController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:[NSMutableData dataWithLength:32]] autorelease];
    NSDictionary *recovered = [reader recoveredNotes];
    XCTAssertEqual(recovered.count, 1U);
    DeletedNoteObject *deletion = recovered.allValues.firstObject;
    XCTAssertTrue([deletion isKindOfClass:[DeletedNoteObject class]]);
    XCTAssertEqual([deletion logSequenceNumber], 9U);
    XCTAssertEqualObjects([NSString uuidStringWithBytes:*[deletion uniqueNoteIDBytes]], @"00112233-4455-6677-8899-AABBCCDDEEFF");
}
- (void)testFixedLegacyIDEAImport {
    NSString *filename = [self.temporaryDirectory stringByAppendingPathComponent:@"Sanitized.blor"];
    XCTAssertTrue([[self fixture:@"legacy-idea.blor"] writeToFile:filename atomically:YES]);
    NSData *key = [[@"legacy import: café 日本語" dataUsingEncoding:NSUTF8StringEncoding] BrokenMD5Digest];
    BlorNoteEnumerator *enumerator = [[[BlorNoteEnumerator alloc] initWithBlor:filename passwordHashData:key] autorelease];
    XCTAssertEqual(enumerator.suspectedNoteCount, 1U);
    NoteObject *note = [enumerator nextNote];
    XCTAssertEqualObjects(note->titleString, @"Legacy imported note");
    XCTAssertEqualObjects(note->contentString.string, @"Preserved legacy IDEA content: café 日本語\n[[Project Alpha]]");
}
@end
