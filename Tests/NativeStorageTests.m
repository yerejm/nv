#import <XCTest/XCTest.h>
#import "NoteObject.h"
#import "DeletedNoteObject.h"
#import "FrozenNotation.h"
#import "NotationPrefs.h"
#import "NotationFileManager.h"
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
- (NotationController *)controller {
    FSRef directory;
    OSStatus error = FSPathMakeRef((const UInt8 *)self.temporaryDirectory.fileSystemRepresentation, &directory, NULL);
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
    FrozenNotation *frozen = [NSKeyedUnarchiver unarchiveObjectWithData:archive];
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
    NSString *directory = [[@__FILE__ stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Fixtures"];
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
    XCTAssertNotNil(data);
    return data;
}
- (void)checkLegacyDatabase:(NSString *)name encrypted:(BOOL)encrypted {
    FrozenNotation *frozen = [NSKeyedUnarchiver unarchiveObjectWithData:[self fixture:name]];
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
    FrozenNotation *frozen = [NSKeyedUnarchiver unarchiveObjectWithData:[self fixture:@"legacy-plain.database"]];
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
    FrozenNotation *reloaded = [NSKeyedUnarchiver unarchiveObjectWithData:saved];
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
