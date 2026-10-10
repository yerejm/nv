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
#import "AlienNoteImporter.h"

@interface ODBEditor (Acceptance)
- (void)handleModifiedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply;
- (void)handleClosedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)reply;
@end

static NSData *NVArchiveLegacyObject(id object) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [NSArchiver archivedDataWithRootObject:object];
#pragma clang diagnostic pop
}

static NSData *NVArchiveLegacyObjectAs(id object, NSString *className, NSString *archivedClassName) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSMutableData *data = [NSMutableData data];
    NSArchiver *archiver = [[NSArchiver alloc] initForWritingWithMutableData:data];
    [archiver encodeClassName:className intoClassName:archivedClassName];
    [archiver encodeRootObject:object];
    return data;
#pragma clang diagnostic pop
}

//written field by field with the types a 32-bit build archived, independently of NoteObject's own coder
@interface NVPositionalNoteArchive : NSObject <NSCoding>
@end
@implementation NVPositionalNoteArchive
- (void)encodeWithCoder:(NSCoder *)coder {
    CFAbsoluteTime modified = 700000000.5, created = 600000000.25;
    UInt32 range[2] = {3, 4};
    float scrolledProportion = 1.0f;
    unsigned int logSequenceNumber = 9, encoding = NSUTF8StringEncoding, serverModifiedTime = 0;
    int format = PlainTextFormat;
    UInt32 nodeID = 0xAABBCCDD, lowSeconds = 0x01020304;
    UInt16 highSeconds = 5, fraction = 6;
    CFUUIDBytes uuid = [@"00112233-4455-6677-8899-AABBCCDDEEFF" uuidBytes];
    [coder encodeValueOfObjCType:@encode(CFAbsoluteTime) at:&modified];
    [coder encodeValueOfObjCType:@encode(CFAbsoluteTime) at:&created];
    [coder encodeValueOfObjCType:"{_NSRange=II}" at:range];
    [coder encodeValueOfObjCType:@encode(float) at:&scrolledProportion];
    [coder encodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
    [coder encodeValueOfObjCType:@encode(int) at:&format];
    [coder encodeValueOfObjCType:"L" at:&nodeID];
    [coder encodeValueOfObjCType:@encode(UInt16) at:&highSeconds];
    [coder encodeValueOfObjCType:"L" at:&lowSeconds];
    [coder encodeValueOfObjCType:@encode(UInt16) at:&fraction];
    [coder encodeValueOfObjCType:"I" at:&encoding];
    [coder encodeValueOfObjCType:@encode(CFUUIDBytes) at:&uuid];
    [coder encodeValueOfObjCType:@encode(unsigned int) at:&serverModifiedTime];
    [coder encodeObject:@"Positional title"];
    [coder encodeObject:@"alpha beta"];
    [coder encodeObject:[[NSAttributedString alloc] initWithString:@"Positional body"]];
    [coder encodeObject:@"Positional title.txt"];
}
- (id)initWithCoder:(NSCoder *)coder {
    return [super init];
}
@end

//the layout of a document in the Stickies database written by Mac OS X 10.0-10.14
@interface NVStickiesDocumentArchive : NSObject <NSCoding>
@end
@implementation NVStickiesDocumentArchive
- (void)encodeWithCoder:(NSCoder *)coder {
    NSAttributedString *text = [[NSAttributedString alloc] initWithString:@"Sticky title\nSticky body"];
    int flags = 1, color = 2;
    float frame[4] = {10, 20, 300, 200};
    [coder encodeObject:[text RTFDFromRange:NSMakeRange(0, text.length) documentAttributes:@{}]];
    [coder encodeValueOfObjCType:@encode(int) at:&flags];
    [coder encodeValueOfObjCType:"{_NSRect={_NSPoint=ff}{_NSSize=ff}}" at:frame];
    [coder encodeValueOfObjCType:@encode(int) at:&color];
    [coder encodeObject:[NSDate dateWithTimeIntervalSinceReferenceDate:500000000]];
    [coder encodeObject:[NSDate dateWithTimeIntervalSinceReferenceDate:510000000]];
}
- (id)initWithCoder:(NSCoder *)coder {
    return [super init];
}
@end

static BOOL NVUnexpectedObjectWasDecoded = NO;

@interface NVUnexpectedArchiveObject : NSObject <NSSecureCoding>
@end
@implementation NVUnexpectedArchiveObject
+ (BOOL)supportsSecureCoding {
    return YES;
}
- (void)encodeWithCoder:(NSCoder *)coder {
}
- (id)initWithCoder:(NSCoder *)coder {
    NVUnexpectedObjectWasDecoded = YES;
    return [super init];
}
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
    NoteObject *note = [[NoteObject alloc] initWithNoteBody:[[NSAttributedString alloc] initWithString:@"Retained content: café 日本語 😀\n[[Project Alpha]]\nhttps://example.com"] title:@"Sanitized legacy note" delegate:nil format:SingleDatabaseFormat labels:@"fixture local"];
    note->uniqueNoteIDBytes = [@"00112233-4455-6677-8899-AABBCCDDEEFF" uuidBytes];
    note->logSequenceNumber = 7;
    [note setSyncObjectAndKeyMD:@{ @"key": @"sanitized-retired-id", @"version": @7 } forService:@"Simplenote"];
    return note;
}
- (void)testDecodedImmutableContentRemainsEditable {
    NoteObject *note = [self sampleNote];
    NSAttributedString *immutable = [[NSAttributedString alloc] initWithString:@"Archived styled text" attributes:@{NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)}];
    note->contentString = (id)immutable;
    NoteObject *decoded = NVUnarchiveObject(NVArchiveObject(note), [NoteObject class]);
    XCTAssertTrue([decoded->contentString isKindOfClass:[NSMutableAttributedString class]]);
    [decoded->contentString.mutableString appendString:@" edited"];
    XCTAssertEqualObjects(decoded->contentString.string, @"Archived styled text edited");
    XCTAssertEqualObjects([decoded->contentString attribute:NSUnderlineStyleAttributeName atIndex:0 effectiveRange:NULL], @(NSUnderlineStyleSingle));
}
- (void)testDoneTagsAndLinksSurviveSecureDecoding {
    NoteObject *note = [self sampleNote];
    [note->contentString addAttributes:@{@"NVDoneTag": [NSNull null], NSStrikethroughStyleAttributeName: @1,
                                         NSLinkAttributeName: [NSURL URLWithString:@"https://example.com"]} range:NSMakeRange(0, 8)];
    NoteObject *decoded = NVUnarchiveObject(NVArchiveObject(note), [NoteObject class]);
    NSDictionary *attributes = [decoded->contentString attributesAtIndex:0 effectiveRange:NULL];
    XCTAssertEqualObjects(attributes[@"NVDoneTag"], [NSNull null]);
    XCTAssertEqualObjects(attributes[NSLinkAttributeName], [NSURL URLWithString:@"https://example.com"]);
    XCTAssertEqualObjects(attributes[NSStrikethroughStyleAttributeName], @1);
}
- (void)testArchivesCarryingUnexpectedClassesAreRejected {
    NVUnexpectedObjectWasDecoded = NO;
    NVUnexpectedArchiveObject *unexpected = [[NVUnexpectedArchiveObject alloc] init];
    NotationPrefs *prefs = [[NotationPrefs alloc] init];
    NSData *deletions = [FrozenNotation frozenDataWithExistingNotes:[NSMutableArray arrayWithObject:[self sampleNote]] deletedNotes:[NSMutableSet setWithObject:unexpected] prefs:prefs];
    XCTAssertNotNil(deletions);
    XCTAssertThrows(NVUnarchiveObject(deletions, [FrozenNotation class]));
    NSData *notes = [FrozenNotation frozenDataWithExistingNotes:[NSMutableArray arrayWithObject:unexpected] deletedNotes:[NSMutableSet set] prefs:prefs];
    FrozenNotation *frozen = NVUnarchiveObject(notes, [FrozenNotation class]);
    OSStatus error = noErr;
    XCTAssertNil([frozen unpackedNotesWithPrefs:[frozen notationPrefs] returningError:&error]);
    XCTAssertEqual(error, kCoderErr);
    NoteObject *note = [self sampleNote];
    [note->contentString addAttribute:@"unexpected" value:unexpected range:NSMakeRange(0, 1)];
    XCTAssertThrows(NVUnarchiveObject(NVArchiveObject(note), [NoteObject class]));
    XCTAssertNil(NVUnarchivePreference(NVArchiveObject(unexpected), [NSFont class]));
    NSData *key = [NSMutableData dataWithLength:32];
    WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key];
    XCTAssertTrue([writer writeNoteObject:(id)unexpected]);
    XCTAssertTrue([writer synchronize]);
    WALRecoveryController *reader = [[WALRecoveryController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key];
    XCTAssertEqual([reader recoveredNotes].count, 0U);
    XCTAssertFalse(NVUnexpectedObjectWasDecoded);
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
- (int)runDiskImageTool:(NSArray *)arguments {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/hdiutil";
    task.arguments = arguments;
    [task launch];
    [task waitUntilExit];
    return task.terminationStatus;
}
- (void)testBookmarkMountsDetachedVolumeOnlyWhenAllowed {
    NSString *volumeName = [@"NVMount-" stringByAppendingString:[[[NSUUID UUID] UUIDString] substringToIndex:8]];
    NSString *image = [self.temporaryDirectory stringByAppendingPathComponent:@"notes.dmg"];
    NSString *mountPoint = [self.temporaryDirectory stringByAppendingPathComponent:@"mount"];
    XCTAssertEqual([self runDiskImageTool:(@[@"create", @"-quiet", @"-size", @"8m", @"-fs", @"APFS", @"-volname", volumeName, image])], 0);
    XCTAssertEqual([self runDiskImageTool:(@[@"attach", @"-quiet", @"-nobrowse", @"-mountpoint", mountPoint, image])], 0);
    NSString *notesPath = [mountPoint stringByAppendingPathComponent:@"notes"];
    XCTAssertTrue([[NSFileManager defaultManager] createDirectoryAtPath:notesPath withIntermediateDirectories:NO attributes:nil error:NULL]);
    NVFileReference directory, resolved;
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)notesPath.fileSystemRepresentation, &directory, NULL), noErr);
    NSData *bookmark = [NSData aliasDataForFSRef:&directory];
    XCTAssertNotNil(bookmark);
    XCTAssertEqual([self runDiskImageTool:(@[@"detach", @"-quiet", mountPoint])], 0);
    XCTAssertFalse([bookmark fsRefAsAlias:&resolved]);
    XCTAssertTrue([bookmark fsRefAsAliasMountingVolume:&resolved]);
    char resolvedPath[PATH_MAX];
    XCTAssertEqual(NVReferenceMakePath(&resolved, (UInt8 *)resolvedPath, sizeof(resolvedPath)), noErr);
    XCTAssertEqualObjects([@(resolvedPath) lastPathComponent], @"notes");
    XCTAssertEqual([self runDiskImageTool:(@[@"detach", @"-quiet", [@(resolvedPath) stringByDeletingLastPathComponent]])], 0);
}
- (void)testAtomicExchangePreservesDestinationMetadata {
    NSString *sourcePath = [self.temporaryDirectory stringByAppendingPathComponent:@"temporary"];
    NSString *destinationPath = [self.temporaryDirectory stringByAppendingPathComponent:@"note.txt"];
    XCTAssertTrue([@"new contents" writeToFile:sourcePath atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertTrue([@"old contents" writeToFile:destinationPath atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    XCTAssertEqual(chmod(destinationPath.fileSystemRepresentation, 0640), 0);
    const char metadata[] = "retained metadata";
    XCTAssertEqual(setxattr(destinationPath.fileSystemRepresentation, "com.notational.velocity.test", metadata, sizeof(metadata), 0, 0), 0);
    const struct timeval oldDates[2] = {{1577804400, 0}, {1577804400, 0}};
    XCTAssertEqual(utimes(destinationPath.fileSystemRepresentation, oldDates), 0);
    struct stat written;
    XCTAssertEqual(stat(sourcePath.fileSystemRepresentation, &written), 0);
    NVFileReference source, destination, newSource, newDestination;
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)sourcePath.fileSystemRepresentation, &source, NULL), noErr);
    XCTAssertEqual(NVPathMakeReference((const UInt8 *)destinationPath.fileSystemRepresentation, &destination, NULL), noErr);
    XCTAssertEqual(NVExchangeFiles(&source, &destination, &newSource, &newDestination), noErr);
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:destinationPath encoding:NSUTF8StringEncoding error:NULL], @"new contents");
    XCTAssertEqualObjects([NSString stringWithContentsOfFile:sourcePath encoding:NSUTF8StringEncoding error:NULL], @"old contents");
    struct stat attributes;
    XCTAssertEqual(stat(destinationPath.fileSystemRepresentation, &attributes), 0);
    XCTAssertEqual(attributes.st_mode & 0777, 0640);
    XCTAssertEqual(attributes.st_birthtimespec.tv_sec, oldDates[1].tv_sec);
    XCTAssertEqual(attributes.st_mtimespec.tv_sec, written.st_mtimespec.tv_sec);
    XCTAssertEqual(attributes.st_mtimespec.tv_nsec, written.st_mtimespec.tv_nsec);
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
    NotationController *controller = [[NotationController alloc] initWithDirectoryRef:&directory error:&error];
    XCTAssertEqual(error, noErr);
    XCTAssertNotNil(controller);
    [controller setUndoManager:[[NSUndoManager alloc] init]];
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
    WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key];
    XCTAssertNotNil(writer);
    XCTAssertTrue([writer writeEstablishedNote:note]);
    [note->contentString replaceCharactersInRange:NSMakeRange(0, note->contentString.length) withString:@"journal edit"];
    XCTAssertTrue([writer writeEstablishedNote:note]);
    XCTAssertTrue([writer writeRemovalForNote:note]);
    XCTAssertTrue([writer synchronize]);
    WALRecoveryController *reader = [[WALRecoveryController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key];
    NSDictionary *recovered = [reader recoveredNotes];
    XCTAssertEqual(recovered.count, 1U);
    DeletedNoteObject *deletion = [recovered.allValues firstObject];
    XCTAssertTrue([deletion isKindOfClass:[DeletedNoteObject class]]);
    XCTAssertEqual([deletion logSequenceNumber], [note logSequenceNumber]);
    XCTAssertEqual(memcmp([deletion uniqueNoteIDBytes], [note uniqueNoteIDBytes], sizeof(CFUUIDBytes)), 0);
}
- (void)testEncryptionPasswordVerifierAndStorageEnvelope {
    NotationPrefs *prefs = [[NotationPrefs alloc] init];
    [prefs setPassphraseData:[@"sanitized fixture password" dataUsingEncoding:NSUTF8StringEncoding] inKeychain:NO];
    XCTAssertTrue([prefs canLoadPassphrase:@"sanitized fixture password"]);
    XCTAssertFalse([prefs canLoadPassphrase:@"wrong password"]);
    [prefs setDoesEncryption:YES];
    NSData *archive = [FrozenNotation frozenDataWithExistingNotes:[NSMutableArray arrayWithObject:[self sampleNote]] deletedNotes:[NSMutableSet set] prefs:prefs];
    FrozenNotation *frozen = NVUnarchiveObject(archive, [FrozenNotation class]);
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
                           @"ODBEditorFileName": resolved};
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
    NotationPrefs *prefs = [[NotationPrefs alloc] init];
    NSData *password = [@"sanitized temporary Keychain password" dataUsingEncoding:NSUTF8StringEncoding];
    NSString *account = [NSString stringWithUTF8String:[prefs setKeychainIdentifier]];
    XCTAssertNotNil([[NSUUID alloc] initWithUUIDString:account]);
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
    NoteObject *removed = [[NoteObject alloc] initWithNoteBody:[[NSAttributedString alloc] initWithString:@"Removed after the last save"] title:@"Recovery deletion" delegate:nil format:SingleDatabaseFormat labels:nil];
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
    writer = nil;
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
    FrozenNotation *frozen = NVUnarchiveObject([self fixture:name], [FrozenNotation class]);
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
- (void)testDerivedEarlierEpochDatabases {
    for (NSNumber *epoch in @[@2, @3]) {
        for (NSString *kind in @[@"plain", @"encrypted"]) {
            NSString *name = [NSString stringWithFormat:@"legacy-epoch%@-%@.database", epoch, kind];
            [self checkLegacyDatabase:name encrypted:[kind isEqualToString:@"encrypted"]];
            FrozenNotation *frozen = NVUnarchiveObject([self fixture:name], [FrozenNotation class]);
            XCTAssertEqual([[frozen notationPrefs] epochIteration], epoch.unsignedIntValue, @"%@", name);
        }
    }
}
- (NSString *)databaseFromFixture:(NSString *)name {
    NSString *database = [self.temporaryDirectory stringByAppendingPathComponent:@"Notes & Settings"];
    [[NSFileManager defaultManager] removeItemAtPath:database error:NULL];
    XCTAssertTrue([[self fixture:name] writeToFile:database atomically:YES]);
    return database;
}
- (NotationPrefs *)savedPrefsAt:(NSString *)database {
    return [NVUnarchiveObject([NSData dataWithContentsOfFile:database], [FrozenNotation class]) notationPrefs];
}
- (NSData *)journalHeader {
    NSData *journal = [NSData dataWithContentsOfFile:[self.temporaryDirectory stringByAppendingPathComponent:@"Interim Note-Changes"]];
    return [journal subdataWithRange:NSMakeRange(0, MIN(journal.length, sizeof(WALAuthenticatedJournalMagic)))];
}
- (NSData *)authenticatedJournalMagic {
    return [NSData dataWithBytes:WALAuthenticatedJournalMagic length:sizeof(WALAuthenticatedJournalMagic)];
}
- (void)testEarlierEpochDatabasesUpgradeOnlyToTheLastCompatibleEpochOnOpen {
    for (NSNumber *epoch in @[@2, @3]) {
        NSString *name = [NSString stringWithFormat:@"legacy-epoch%@-plain.database", epoch];
        NSString *database = [self databaseFromFixture:name];
        NotationController *controller = [self controller];
        NoteObject *note = [controller noteForUUIDBytes:&(CFUUIDBytes){0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF}];
        XCTAssertEqualObjects(note->titleString, @"Sanitized legacy note", @"%@", name);
        [controller closeAllResources];
        XCTAssertEqual([[self savedPrefsAt:database] epochIteration], (UInt32)LAST_COMPATIBLE_EPOCH, @"%@", name);
    }
}
- (void)testExistingDatabaseKeepsItsCompatibleFormat {
    NSString *database = [self databaseFromFixture:@"legacy-plain.database"];
    NotationController *controller = [self controller];
    XCTAssertFalse([[controller notationPrefs] usesAuthenticatedFormat]);
    XCTAssertNotEqualObjects([self journalHeader], [self authenticatedJournalMagic]);
    [controller addNewNote:[[NoteObject alloc] initWithNoteBody:[[NSAttributedString alloc] initWithString:@"Added later"] title:@"Added" delegate:nil format:SingleDatabaseFormat labels:nil]];
    XCTAssertTrue([controller flushAllNoteChanges]);
    [controller closeAllResources];
    NSDictionary *plist = [NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:database] options:0 format:NULL error:NULL];
    for (NSDictionary *object in plist[@"$objects"])
        if ([object isKindOfClass:[NSDictionary class]] && object[@"epochIteration"]) {
            XCTAssertEqualObjects(object[@"epochIteration"], @(LAST_COMPATIBLE_EPOCH));
            XCTAssertNil(object[@"keyDerivationPRF"]);
        }
}
- (void)testNewDatabaseUsesTheAuthenticatedFormat {
    NotationController *controller = [self controller];
    XCTAssertTrue([[controller notationPrefs] usesAuthenticatedFormat]);
    XCTAssertEqualObjects([self journalHeader], [self authenticatedJournalMagic]);
    [controller addNewNote:[self sampleNote]];
    XCTAssertTrue([controller flushAllNoteChanges]);
    [controller closeAllResources];
    XCTAssertEqual([[self savedPrefsAt:[self.temporaryDirectory stringByAppendingPathComponent:@"Notes & Settings"]] epochIteration], (UInt32)EPOC_ITERATION);
}
- (void)testUpgradeToAuthenticatedFormatKeepsACopyOfTheOriginal {
    NSString *database = [self databaseFromFixture:@"legacy-plain.database"];
    NotationController *controller = [self controller];
    XCTAssertTrue([controller flushAllNoteChanges]);
    NSData *original = [NSData dataWithContentsOfFile:database];
    XCTAssertTrue([controller upgradeToAuthenticatedFormat]);
    XCTAssertTrue([[controller notationPrefs] usesAuthenticatedFormat]);
    XCTAssertEqualObjects([self journalHeader], [self authenticatedJournalMagic]);
    NSString *backup = [self.temporaryDirectory stringByAppendingPathComponent:@"Notes & Settings (before security upgrade)"];
    XCTAssertEqualObjects([NSData dataWithContentsOfFile:backup], original);
    XCTAssertEqual([[self savedPrefsAt:backup] epochIteration], (UInt32)LAST_COMPATIBLE_EPOCH);
    XCTAssertEqual([[self savedPrefsAt:database] epochIteration], (UInt32)EPOC_ITERATION);
    [controller closeAllResources];
    NotationController *reopened = [self controller];
    XCTAssertTrue([[reopened notationPrefs] usesAuthenticatedFormat]);
    XCTAssertEqual([reopened totalNoteCount], 1U);
    XCTAssertFalse([[reopened notationPrefs] catalogEntryAllowed:&(NoteCatalogEntry){.filename = (CFMutableStringRef)@"Notes & Settings (before security upgrade)"}]);
    [reopened closeAllResources];
}
- (void)testRetiredMetadataSurvivesArchiveAndLocalIdentityLinks {
    FrozenNotation *frozen = NVUnarchiveObject([self fixture:@"legacy-plain.database"], [FrozenNotation class]);
    NotationPrefs *prefs = [frozen notationPrefs];
    NSDictionary *accounts = [prefs.syncServiceAccounts copy];
    XCTAssertTrue([accounts[@"Simplenote"][@"enabled"] boolValue]);
    OSStatus error;
    NSMutableArray *notes = [frozen unpackedNotesWithPrefs:prefs returningError:&error];
    NoteObject *note = notes.firstObject;
    NSDictionary *metadata = [note.syncServicesMD copy];
    NSString *identity = nil;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:note.uniqueNoteLink resolvingAgainstBaseURL:NO].queryItems)
        if ([item.name isEqualToString:@"NV"]) identity = item.value;
    XCTAssertEqualObjects([identity decodeBase64WithNewlines:NO], [NSData dataWithBytes:note.uniqueNoteIDBytes length:16]);
    NSData *saved = [FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:[frozen deletedNotes] prefs:prefs];
    FrozenNotation *reloaded = NVUnarchiveObject(saved, [FrozenNotation class]);
    NSArray *loaded = [reloaded unpackedNotesWithPrefs:[reloaded notationPrefs] returningError:&error];
    XCTAssertEqualObjects([[reloaded notationPrefs] syncServiceAccounts], accounts);
    XCTAssertEqualObjects([(NoteObject *)loaded.firstObject syncServicesMD], metadata);
    XCTAssertEqualObjects(prefs.syncServiceAccounts, accounts);
}
- (FrozenNotation *)frozenNotationWithPositionalNotesAtEpoch:(UInt32)epoch {
    NotationPrefs *prefs = [[NotationPrefs alloc] init];
    NSData *archive = [FrozenNotation frozenDataWithExistingNotes:[NSMutableArray arrayWithObject:[self sampleNote]] deletedNotes:[NSMutableSet set] prefs:prefs];
    FrozenNotation *frozen = NVUnarchiveObject(archive, [FrozenNotation class]);
    [[frozen notationPrefs] setValue:@(epoch) forKey:@"epochIteration"];
    NSData *positional = NVArchiveLegacyObject([NSMutableArray arrayWithObject:@"positional note"]);
    [frozen setValue:[positional compressedData] forKey:@"notesData"];
    return frozen;
}
- (void)testPositionalNotesLoadOnlyBeforeKeyedEpoch {
    OSStatus error;
    NSArray *notes = [[self frozenNotationWithPositionalNotesAtEpoch:1] unpackedNotesReturningError:&error];
    XCTAssertEqual(error, noErr);
    XCTAssertEqualObjects(notes, @[@"positional note"]);
    XCTAssertNil([[self frozenNotationWithPositionalNotesAtEpoch:2] unpackedNotesReturningError:&error]);
    XCTAssertEqual(error, kCoderErr);
}
- (void)testLegacyPreferenceArchivesMigrateOnce {
    NSString *suite = [@"net.notational.velocity.tests." stringByAppendingString:[[NSUUID UUID] UUIDString]];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    NSColor *red = [NSColor colorWithCalibratedRed:1 green:0 blue:0 alpha:1];
    NSData *legacyColor = NVArchiveLegacyObject(red);
    NSData *keyedColor = NVArchiveObject([NSColor blueColor]);
    [defaults setObject:NVArchiveLegacyObject([NSFont fontWithName:@"Helvetica" size:15]) forKey:@"NoteBodyFont"];
    [defaults setObject:legacyColor forKey:@"ForegroundTextColor"];
    [defaults setObject:NVArchiveLegacyObject(@"not a color") forKey:@"BackgroundTextColor"];
    [defaults setObject:keyedColor forKey:@"SearchTermHighlightColor"];
    NVMigrateLegacyArchivedPreferences(defaults);
    NSFont *font = NVUnarchivePreference([defaults dataForKey:@"NoteBodyFont"], [NSFont class]);
    XCTAssertEqualObjects(font.fontName, @"Helvetica");
    XCTAssertEqual(font.pointSize, 15);
    XCTAssertEqualObjects(NVUnarchivePreference([defaults dataForKey:@"ForegroundTextColor"], [NSColor class]), red);
    XCTAssertNil([defaults persistentDomainForName:suite][@"BackgroundTextColor"]);
    XCTAssertEqualObjects([defaults dataForKey:@"SearchTermHighlightColor"], keyedColor);
    XCTAssertTrue([defaults boolForKey:@"LegacyArchivedPreferencesMigrated"]);
    [defaults setObject:legacyColor forKey:@"ForegroundTextColor"];
    NVMigrateLegacyArchivedPreferences(defaults);
    XCTAssertEqualObjects([defaults dataForKey:@"ForegroundTextColor"], legacyColor);
    XCTAssertNil(NVUnarchivePreference(legacyColor, [NSColor class]));
    [defaults removePersistentDomainForName:suite];
}
- (WALRecoveryController *)readerForJournalFixture:(NSString *)name acceptingUnauthenticatedRecords:(BOOL)acceptsUnauthenticated {
    NSString *journal = [self.temporaryDirectory stringByAppendingPathComponent:@"Interim Note-Changes"];
    [[NSFileManager defaultManager] removeItemAtPath:journal error:NULL];
    XCTAssertTrue([[self fixture:name] writeToFile:journal atomically:YES]);
    return [[WALRecoveryController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:[NSMutableData dataWithLength:32]
                                acceptingUnauthenticatedRecords:acceptsUnauthenticated];
}
- (void)checkJournalDeletion:(NSDictionary *)recovered {
    XCTAssertEqual(recovered.count, 1U);
    DeletedNoteObject *deletion = recovered.allValues.firstObject;
    XCTAssertTrue([deletion isKindOfClass:[DeletedNoteObject class]]);
    XCTAssertEqual([deletion logSequenceNumber], 9U);
    XCTAssertEqualObjects([NSString uuidStringWithBytes:*[deletion uniqueNoteIDBytes]], @"00112233-4455-6677-8899-AABBCCDDEEFF");
}
- (void)testFixedLegacyJournalDeletion {
    WALRecoveryController *reader = [self readerForJournalFixture:@"legacy-deletion.journal" acceptingUnauthenticatedRecords:YES];
    [self checkJournalDeletion:[reader recoveredNotes]];
    XCTAssertFalse([reader rejectedUnverifiedRecords]);
}
- (void)testUnauthenticatedJournalIsRefusedOnceAuthenticated {
    WALRecoveryController *reader = [self readerForJournalFixture:@"legacy-deletion.journal" acceptingUnauthenticatedRecords:NO];
    XCTAssertEqual([reader recoveredNotes].count, 0U);
    XCTAssertTrue([reader rejectedUnverifiedRecords]);
}
- (void)testCompatibleJournalIsReadableByEarlierEpochs {
    NSData *key = [NSMutableData dataWithLength:32];
    NoteObject *note = [self sampleNote];
    WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key authenticated:NO];
    XCTAssertTrue([writer writeEstablishedNote:note]);
    XCTAssertTrue([writer synchronize]);
    XCTAssertNotEqualObjects([self journalHeader], [self authenticatedJournalMagic]);
    WALRecoveryController *reader = [[WALRecoveryController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key acceptingUnauthenticatedRecords:YES];
    NSDictionary *recovered = [reader recoveredNotes];
    XCTAssertEqual(recovered.count, 1U);
    XCTAssertEqualObjects(((NoteObject *)recovered.allValues.firstObject)->titleString, note->titleString);
}
- (void)testFixedAuthenticatedJournalDeletion {
    for (NSNumber *acceptsUnauthenticated in @[@NO, @YES]) {
        WALRecoveryController *reader = [self readerForJournalFixture:@"epoch5-deletion.journal" acceptingUnauthenticatedRecords:acceptsUnauthenticated.boolValue];
        [self checkJournalDeletion:[reader recoveredNotes]];
        XCTAssertFalse([reader rejectedUnverifiedRecords]);
    }
}
- (NSString *)journalWithNotes:(NSArray *)notes key:(NSData *)key {
    WALStorageController *writer = [[WALStorageController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key];
    for (NoteObject *note in notes) XCTAssertTrue([writer writeEstablishedNote:note]);
    XCTAssertTrue([writer synchronize]);
    return [self.temporaryDirectory stringByAppendingPathComponent:@"Interim Note-Changes"];
}
- (void)flipByteAtOffset:(off_t)offset ofFile:(NSString *)path {
    NSMutableData *data = [NSMutableData dataWithContentsOfFile:path];
    if (offset < 0) offset += data.length;
    ((unsigned char *)data.mutableBytes)[offset] ^= 0x01;
    XCTAssertEqual(chmod(path.fileSystemRepresentation, 0600), 0);
    XCTAssertTrue([data writeToFile:path atomically:NO]);
}
- (void)testTamperedJournalRecordsAreRejected {
    NSData *key = [NSMutableData dataWithLength:32];
    NoteObject *first = [self sampleNote];
    NoteObject *second = [[NoteObject alloc] initWithNoteBody:[[NSAttributedString alloc] initWithString:@"Second journal note"] title:@"Second" delegate:nil format:SingleDatabaseFormat labels:nil];
    NSString *journal = [self journalWithNotes:@[first, second] key:key];
    [self flipByteAtOffset:-1 ofFile:journal];
    WALRecoveryController *reader = [[WALRecoveryController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key];
    NSDictionary *recovered = [reader recoveredNotes];
    XCTAssertEqual(recovered.count, 1U);
    XCTAssertEqualObjects(((NoteObject *)recovered.allValues.firstObject)->titleString, first->titleString);
    XCTAssertTrue([reader rejectedUnverifiedRecords]);
    XCTAssertTrue([reader destroyLogFile]);
    
    for (NSNumber *offset in @[@8, @(8 + 7), @(8 + 8), @(8 + 8 + 16), @(8 + 8 + 16 + 32)]) {
        journal = [self journalWithNotes:@[first] key:key];
        [self flipByteAtOffset:offset.longLongValue ofFile:journal];
        reader = [[WALRecoveryController alloc] initWithParentFSRep:self.temporaryDirectory.fileSystemRepresentation encryptionKey:key];
        XCTAssertEqual([reader recoveredNotes].count, 0U, @"offset %@", offset);
        XCTAssertTrue([reader rejectedUnverifiedRecords], @"offset %@", offset);
        XCTAssertTrue([reader destroyLogFile]);
    }
}
- (void)testStartupKeepsTamperedJournalAside {
    NotationController *controller = [self controller];
    NoteObject *edited = [self sampleNote];
    [controller addNewNote:edited];
    XCTAssertTrue([controller flushAllNoteChanges]);
    NSData *key = [[controller notationPrefs] WALSessionKey];
    CFUUIDBytes editedID = *[edited uniqueNoteIDBytes];
    [controller closeAllResources];
    [edited->contentString replaceCharactersInRange:NSMakeRange(0, edited->contentString.length) withString:@"Tampered unsaved edit"];
    NSString *journal = [self journalWithNotes:@[edited] key:key];
    [self flipByteAtOffset:-1 ofFile:journal];
    NotationController *reopened = [self controller];
    NoteObject *loaded = [reopened noteForUUIDBytes:&editedID];
    XCTAssertEqualObjects(loaded->contentString.string, @"Retained content: café 日本語 😀\n[[Project Alpha]]\nhttps://example.com");
    NSString *retired = [self.temporaryDirectory stringByAppendingPathComponent:@"Interim Note-Changes (unverified)"];
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:retired]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:journal]);
    [reopened closeAllResources];
}
- (NSData *)archive:(NSData *)archive settingPreference:(NSString *)key to:(id)value {
    NSMutableDictionary *plist = [NSPropertyListSerialization propertyListWithData:archive options:NSPropertyListMutableContainers format:NULL error:NULL];
    for (NSMutableDictionary *object in plist[@"$objects"])
        if ([object isKindOfClass:[NSDictionary class]] && object[@"epochIteration"]) object[key] = value;
    return [NSPropertyListSerialization dataWithPropertyList:plist format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];
}
- (OSStatus)unpackArchive:(NSData *)archive password:(NSString *)password tampering:(void (^)(FrozenNotation *frozen))tamper {
    FrozenNotation *frozen = NVUnarchiveObject(archive, [FrozenNotation class]);
    XCTAssertTrue([[frozen notationPrefs] canLoadPassphrase:password]);
    if (tamper) tamper(frozen);
    OSStatus error = noErr;
    NSArray *notes = [frozen unpackedNotesWithPrefs:[frozen notationPrefs] returningError:&error];
    XCTAssertEqual(notes == nil, error != noErr);
    return error;
}
- (void)checkAuthenticatedArchive:(NSData *)archive password:(NSString *)password {
    XCTAssertEqual([self unpackArchive:archive password:password tampering:nil], noErr);
    XCTAssertEqual([self unpackArchive:archive password:password tampering:^(FrozenNotation *frozen) {
        ((unsigned char *)[[frozen valueForKey:@"notesData"] mutableBytes])[0] ^= 0x01;
    }], kDataIntegrityErr);
    XCTAssertEqual([self unpackArchive:archive password:password tampering:^(FrozenNotation *frozen) {
        NSMutableData *data = [frozen valueForKey:@"notesData"];
        ((unsigned char *)data.mutableBytes)[data.length - 1] ^= 0x01;
    }], kDataIntegrityErr);
    XCTAssertEqual([self unpackArchive:archive password:password tampering:^(FrozenNotation *frozen) {
        [(NSMutableData *)[frozen valueForKey:@"notesData"] setLength:16];
    }], kDataIntegrityErr);
    XCTAssertEqual([self unpackArchive:archive password:password tampering:^(FrozenNotation *frozen) {
        NSMutableData *salt = [[[frozen notationPrefs] valueForKey:@"dataSessionSalt"] mutableCopy];
        ((unsigned char *)salt.mutableBytes)[0] ^= 0x01;
        [[frozen notationPrefs] setValue:salt forKey:@"dataSessionSalt"];
    }], kDataIntegrityErr);
    XCTAssertNotEqual([self unpackArchive:[self archive:archive settingPreference:@"epochIteration" to:@4] password:password tampering:nil], noErr);
}
- (void)testEncryptedDatabaseIsAuthenticatedAndRejectsTampering {
    NotationPrefs *prefs = [[NotationPrefs alloc] init];
    [prefs setPassphraseData:[@"sanitized fixture password" dataUsingEncoding:NSUTF8StringEncoding] inKeychain:NO];
    [prefs setDoesEncryption:YES];
    NSData *archive = [FrozenNotation frozenDataWithExistingNotes:[NSMutableArray arrayWithObject:[self sampleNote]] deletedNotes:[NSMutableSet set] prefs:prefs];
    FrozenNotation *frozen = NVUnarchiveObject(archive, [FrozenNotation class]);
    XCTAssertEqual([[frozen notationPrefs] epochIteration], 5U);
    XCTAssertEqualObjects([[frozen notationPrefs] valueForKey:@"keyDerivationPRF"], @(kCCPRFHmacAlgSHA256));
    [self checkAuthenticatedArchive:archive password:@"sanitized fixture password"];
}
- (void)testFixedAuthenticatedDatabases {
    for (NSString *name in @[@"epoch5-upgraded-encrypted.database", @"epoch5-sha256-encrypted.database"]) {
        [self checkLegacyDatabase:name encrypted:YES];
        [self checkAuthenticatedArchive:[self fixture:name] password:@"sanitized fixture password"];
    }
}
- (NSData *)resavedLegacyEncryptedDatabaseUpgrading:(BOOL)upgrade {
    FrozenNotation *legacy = NVUnarchiveObject([self fixture:@"legacy-encrypted.database"], [FrozenNotation class]);
    NotationPrefs *prefs = [legacy notationPrefs];
    XCTAssertTrue([prefs canLoadPassphrase:@"sanitized fixture password"]);
    OSStatus error;
    NSMutableArray *notes = [legacy unpackedNotesWithPrefs:prefs returningError:&error];
    XCTAssertEqual(error, noErr);
    if (upgrade) [prefs setUsesAuthenticatedFormat:YES];
    return [FrozenNotation frozenDataWithExistingNotes:notes deletedNotes:[legacy deletedNotes] prefs:prefs];
}
- (void)testLegacyEncryptedDatabaseKeepsItsFormatWhenSaved {
    NSData *saved = [self resavedLegacyEncryptedDatabaseUpgrading:NO];
    FrozenNotation *resaved = NVUnarchiveObject(saved, [FrozenNotation class]);
    XCTAssertEqual([[resaved notationPrefs] epochIteration], (UInt32)LAST_COMPATIBLE_EPOCH);
    XCTAssertFalse([[resaved notationPrefs] usesAuthenticatedFormat]);
    XCTAssertEqual([self unpackArchive:saved password:@"sanitized fixture password" tampering:nil], noErr);
}
- (void)testLegacyEncryptedDatabaseUpgradesToAuthenticatedFormatOnRequest {
    NSData *saved = [self resavedLegacyEncryptedDatabaseUpgrading:YES];
    FrozenNotation *upgraded = NVUnarchiveObject(saved, [FrozenNotation class]);
    XCTAssertEqual([[upgraded notationPrefs] epochIteration], 5U);
    XCTAssertEqualObjects([[upgraded notationPrefs] valueForKey:@"keyDerivationPRF"], @(kCCPRFHmacAlgSHA1));
    [self checkAuthenticatedArchive:saved password:@"sanitized fixture password"];
}
- (void)checkPassphraseChangeAfterUpgrading:(BOOL)upgrade derivesWith:(CCPseudoRandomAlgorithm)prf {
    FrozenNotation *legacy = NVUnarchiveObject([self fixture:@"legacy-encrypted.database"], [FrozenNotation class]);
    NotationPrefs *prefs = [legacy notationPrefs];
    NSData *oldSalt = [prefs valueForKey:@"masterSalt"];
    XCTAssertTrue([prefs canLoadPassphrase:@"sanitized fixture password"]);
    if (upgrade) [prefs setUsesAuthenticatedFormat:YES];
    [prefs setPassphraseData:[@"changed fixture password" dataUsingEncoding:NSUTF8StringEncoding] inKeychain:NO];
    XCTAssertEqualObjects([prefs valueForKey:@"keyDerivationPRF"], @(prf));
    XCTAssertNotEqualObjects([prefs valueForKey:@"masterSalt"], oldSalt);
    XCTAssertTrue([prefs canLoadPassphrase:@"changed fixture password"]);
    XCTAssertFalse([prefs canLoadPassphrase:@"sanitized fixture password"]);
}
- (void)testPassphraseChangeKeepsCompatibleKeysUntilUpgraded {
    [self checkPassphraseChangeAfterUpgrading:NO derivesWith:kCCPRFHmacAlgSHA1];
}
- (void)testPassphraseChangeDerivesNewKeysWithSHA256OnceUpgraded {
    [self checkPassphraseChangeAfterUpgrading:YES derivesWith:kCCPRFHmacAlgSHA256];
}
- (void)testThirtyTwoBitPositionalNoteArchive {
    NoteObject *note = NVUnarchiveLegacyObject(NVArchiveLegacyObjectAs([[NVPositionalNoteArchive alloc] init], @"NVPositionalNoteArchive", @"NoteObject"));
    XCTAssertTrue([note isKindOfClass:[NoteObject class]]);
    XCTAssertEqual(note->modifiedDate, 700000000.5);
    XCTAssertEqual(note->createdDate, 600000000.25);
    XCTAssertTrue(NSEqualRanges(note->selectedRange, NSMakeRange(3, 4)));
    XCTAssertTrue(note->contentsWere7Bit);
    XCTAssertEqual(note->logSequenceNumber, 9U);
    XCTAssertEqual(note->currentFormatID, PlainTextFormat);
    XCTAssertEqual(note->nodeID, 0xAABBCCDDU);
    XCTAssertEqual(note->fileModifiedDate.highSeconds, 5);
    XCTAssertEqual(note->fileModifiedDate.lowSeconds, 0x01020304U);
    XCTAssertEqual(note->fileModifiedDate.fraction, 6);
    XCTAssertEqual(note->fileEncoding, NSUTF8StringEncoding);
    CFUUIDBytes expectedUUID = [@"00112233-4455-6677-8899-AABBCCDDEEFF" uuidBytes];
    XCTAssertEqual(memcmp(&note->uniqueNoteIDBytes, &expectedUUID, sizeof(CFUUIDBytes)), 0);
    XCTAssertEqualObjects(note->titleString, @"Positional title");
    XCTAssertEqualObjects(note->labelString, @"alpha beta");
    XCTAssertEqualObjects(note->contentString.string, @"Positional body");
    XCTAssertEqualObjects(note->filename, @"Positional title.txt");
}
- (void)testStickiesDatabaseImport {
    NSString *filename = [self.temporaryDirectory stringByAppendingPathComponent:@"StickiesDatabase"];
    NSMutableArray *documents = [NSMutableArray arrayWithObject:[[NVStickiesDocumentArchive alloc] init]];
    XCTAssertTrue([NVArchiveLegacyObjectAs(documents, @"NVStickiesDocumentArchive", @"Document") writeToFile:filename atomically:YES]);
    NSArray *notes = [[[AlienNoteImporter alloc] init] notesWithPaths:@[filename]];
    XCTAssertEqual(notes.count, 1U);
    NoteObject *note = notes.firstObject;
    XCTAssertEqualObjects(note->titleString, @"Sticky title");
    XCTAssertEqualObjects(note->contentString.string, @"Sticky body");
    XCTAssertEqual(note->createdDate, 500000000);
    XCTAssertEqual(note->modifiedDate, 510000000);
}
- (void)testFixedLegacyIDEAImport {
    NSString *filename = [self.temporaryDirectory stringByAppendingPathComponent:@"Sanitized.blor"];
    XCTAssertTrue([[self fixture:@"legacy-idea.blor"] writeToFile:filename atomically:YES]);
    NSData *key = [[@"legacy import: café 日本語" dataUsingEncoding:NSUTF8StringEncoding] BrokenMD5Digest];
    BlorNoteEnumerator *enumerator = [[BlorNoteEnumerator alloc] initWithBlor:filename passwordHashData:key];
    XCTAssertEqual(enumerator.suspectedNoteCount, 1U);
    NoteObject *note = [enumerator nextNote];
    XCTAssertEqualObjects(note->titleString, @"Legacy imported note");
    XCTAssertEqualObjects(note->contentString.string, @"Preserved legacy IDEA content: café 日本語\n[[Project Alpha]]");
}
- (void)testShortLivedStringFallsBackToAnEncodingThatDecodes {
    NSMutableData *data = [NSMutableData dataWithBytes:"caf\x8E" length:4];
    NSStringEncoding encoding = NSUTF8StringEncoding;
    NSMutableString *string = [NSMutableString newShortLivedStringFromData:data ofGuessedEncoding:&encoding withPath:NULL orWithFSRef:NULL];
    XCTAssertEqualObjects(string, @"café");
    XCTAssertEqual(encoding, NSMacOSRomanStringEncoding);
}
@end
