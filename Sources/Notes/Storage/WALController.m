//
//  WALController.m
//  Notation
//
//  Created by Zachary Schneirov on 2/5/06.

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <CommonCrypto/CommonCryptor.h>
#import "NSData_transformations.h"
#import "WALController.h"
#import "DeletedNoteObject.h"
#import "NoteObject.h"
#import "NSCollection_utils.h"
#import "NSString_NV.h"

/*
 CFHashBytes from http://www.opensource.apple.com/source/CF/CF-1153.18/CFUtilities.c
 */
#define ELF_STEP(B) T1 = (H << 4) + B; T2 = T1 & 0xF0000000; if (T2) T1 ^= (T2 >> 24); T1 &= (~T2); H = T1;

CFHashCode CFHashBytes(const uint8_t *bytes, CFIndex length) {
    /* The ELF hash algorithm, used in the ELF object file format */
    UInt32 H = 0, T1, T2;
    SInt32 rem = (SInt32)length;
    while (3 < rem) {
        ELF_STEP(bytes[length - rem]);
        ELF_STEP(bytes[length - rem + 1]);
        ELF_STEP(bytes[length - rem + 2]);
        ELF_STEP(bytes[length - rem + 3]);
        rem -= 4;
    }
    switch (rem) {
        case 3:  ELF_STEP(bytes[length - 3]);
        case 2:  ELF_STEP(bytes[length - 2]);
        case 1:  ELF_STEP(bytes[length - 1]);
        case 0:  ;
    }
    return H;
}

#undef ELF_STEP

#define JOURNAL_ENCRYPTION_PURPOSE "Notational Velocity journal encryption"
#define JOURNAL_AUTHENTICATION_PURPOSE "Notational Velocity journal authentication"
//the lengths and IV of an authenticated record header, which its tag covers along with the ciphertext
#define AUTHENTICATED_HEADER_LEN (sizeof(u_int32_t) * 2 + RECORD_IV_LEN)

const char WALAuthenticatedJournalMagic[8] = {'N', 'V', 'W', 'A', 'L', 0, 0, 5};

//file descriptor based for lower level access

//also used as an ad-hoc lock file;
//if it's removed, assume another application did it
//so serialize notes to database file and quit
//if the other app already recovered the journal and rewrote the database file then it won't matter
//if it didn't, well at least the notes have been saved

@implementation WALController

- (instancetype)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key {
    if ((self = [super init])) {
		logFD = -1;
		
		char filename[] = "Interim Note-Changes";
		size_t newPathLength = sizeof(filename) + strlen(path) + 2;
		
		journalFile = (char*)malloc(newPathLength);
		strlcpy(journalFile, path, newPathLength);
		strlcat(journalFile, "/", newPathLength);
		strlcat(journalFile, filename, newPathLength);
		
		//for simplicity's sake the log file is always compressed and encrypted with the key for the current database
		//if the database has no encryption, it should have passed some constant known key to us instead
		logSessionKey = key;
		recordEncryptionKey = [key subkeyForPurpose:JOURNAL_ENCRYPTION_PURPOSE salt:nil];
		recordAuthenticationKey = [key subkeyForPurpose:JOURNAL_AUTHENTICATION_PURPOSE salt:nil];
		
    }
    return self;
}

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}

//called frequently--each time the app comes to the foreground?
- (BOOL)logFileStillExists {
    struct stat sb;
    
    //but really we shouldn't just fstat the fd because the file shouldn't be renamed or moved, either
    //on the other hand, what if another app deleted and re-created it? then any changes would be lost upon closing the fd
    if (fstat(logFD, &sb) < 0) {
	NSLog(@"logFileStillExists: fstat error: %s", strerror(errno));
	
	return NO;
    }
    
    return (sb.st_nlink > 0);
}

- (BOOL)destroyLogFile {

	journalFile = (char*)realloc(journalFile, 4096 * sizeof(char));
    intptr_t pathIntPtr = (intptr_t)journalFile;
	
	//get current path of file descriptor in case the directory was moved
	if (fcntl(logFD, F_GETPATH, pathIntPtr) < 0) {
		NSLog(@"destroyLogFile: fcntl F_GETPATH error: %s", strerror(errno));
	}
	
	if (close(logFD) < 0) {
		NSLog(@"destroyLogFile: close error: %s:", strerror(errno));
	}
	
	if (unlink(journalFile) < 0) {
		NSLog(@"destroyLogFile: unlink error: %s", strerror(errno));
		return NO;
	}
    return YES;
}

//keeps a journal that cannot be trusted next to the notes instead of deleting it
- (BOOL)retireLogFileWithName:(NSString*)filename {
	char currentPath[MAXPATHLEN];
	if (fcntl(logFD, F_GETPATH, currentPath) < 0) {
		NSLog(@"retireLogFileWithName: fcntl F_GETPATH error: %s", strerror(errno));
		strlcpy(currentPath, journalFile, sizeof(currentPath));
	}
	if (close(logFD) < 0) {
		NSLog(@"retireLogFileWithName: close error: %s", strerror(errno));
	}
	logFD = -1;
	
	NSString *retiredPath = [[[NSString stringWithUTF8String:currentPath] stringByDeletingLastPathComponent] stringByAppendingPathComponent:filename];
	if (rename(currentPath, [retiredPath fileSystemRepresentation]) < 0) {
		NSLog(@"retireLogFileWithName: rename error: %s", strerror(errno));
		return NO;
	}
	return YES;
}

- (void)dealloc {
	if (journalFile)
		free(journalFile);
}

@end

@implementation WALStorageController
//appends a compressed stream of serialized notes

//general operation when writing the serialized database:

//log file is flushed to disk with synchronize
//log file is closed

//notes are serialized and fs-exchanged

//if these operations are all successful, log file is removed


- (instancetype)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key {
	return [self initWithParentFSRep:path encryptionKey:key authenticated:YES];
}

- (instancetype)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key authenticated:(BOOL)authenticated {
    if ((self = [super initWithParentFSRep:path encryptionKey:key])) {
	authenticatedRecords = authenticated;
	
	//we could make parent dir writable just in case, but that might be a security hazard depending on ownership
	
	//attempt to open/create the file exclusively with write-only and append access
	
	if ((logFD = open(journalFile, O_CREAT | O_EXCL | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)) < 0) {
	    //if this fails, the file probably still exists, or we don't have write permission
	    //either way, we shouldn't continue
	    
	    NSLog(@"WALStorageController: open error for file %s: %s", journalFile, strerror(errno));
	    
	    return nil;
	}
	if (fcntl(logFD, F_NOCACHE, 1) < 0) {
		NSLog(@"Unable to disable disk caching for writing: %s", strerror(errno));
	}
	if (authenticatedRecords && write(logFD, WALAuthenticatedJournalMagic, sizeof(WALAuthenticatedJournalMagic)) != sizeof(WALAuthenticatedJournalMagic)) {
		NSLog(@"WALStorageController: unable to write the journal header to %s: %s", journalFile, strerror(errno));
		close(logFD);
		unlink(journalFile);
		return nil;
	}
		
	//this will grow as necessary
	unwrittenData = [NSMutableData dataWithCapacity:16];
	
	//initialize the compression
		compressionStream.total_in = 0;
		compressionStream.total_out = 0;
		compressionStream.zalloc = Z_NULL;
		compressionStream.zfree = Z_NULL;
		compressionStream.opaque = Z_NULL;

		if (deflateInit2(&compressionStream, 5, Z_DEFLATED, MAX_WBITS, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY) != Z_OK) {
			NSLog(@"deflateInit2 returned error: %s", compressionStream.msg);
			return nil;
		}
		
    }
    
    return self;
}

- (BOOL)writeNoteObject:(id<SynchronizedNote>)aNoteObject {
	//this method serializes a note object, encrypts it, and writes it to the log
    NSMutableData *noteData = [NSMutableData data];
	NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
	[archiver encodeObject:aNoteObject forKey:@"aNote"];
	[archiver finishEncoding];
        [noteData setData:[archiver encodedData]];
	
    if ([noteData length])
		return [self _encryptAndWriteData:noteData];
    
    return NO;
}

- (BOOL)writeEstablishedNote:(id<SynchronizedNote>)aNoteObject {
	[aNoteObject incrementLSN];
	
	return [self writeNoteObject:aNoteObject];
}

- (BOOL)writeRemovalForNote:(id<SynchronizedNote>)aNoteObject {
	//increment the original note's LSN to ensure it's stored in the final DB
    [aNoteObject incrementLSN];
    
    //construct a "removal object" for this note with some identifying information
	DeletedNoteObject *removedNote = [[DeletedNoteObject alloc] initWithExistingObject:aNoteObject];
    
	return [self writeNoteObject:removedNote];	
}

- (void)writeNoteObjects:(NSArray*)notes {
	//assume that the LSNs have been incremented already if they needed to be
	NSUInteger i;
    for (i=0; i<[notes count]; i++) {
		[self writeNoteObject:[notes objectAtIndex:i]];
	}
}

- (BOOL)_attemptToWriteUnwrittenData {
    ssize_t bytesWritten = 0;
    
    //attempt to write any buffered data
    if ([unwrittenData length] > 0) {
		if ((bytesWritten = write(logFD, [unwrittenData bytes], [unwrittenData length])) > 0) {
			//shift bytes backward and shrink buffer if any data could be written
			void *bytes = [unwrittenData mutableBytes];
			size_t newLength = [unwrittenData length] - bytesWritten;
			
			if (newLength > 0)
				memmove(bytes, bytes + bytesWritten, newLength);
			[unwrittenData setLength:newLength];
		} else {
			NSLog(@"Unable to empty out unwritten data to journal %s: %s", journalFile, strerror(errno));
		}
    }
    
    return ([unwrittenData length] == 0);
}

//encrypts compressed record data in place and returns the header that precedes it
- (NSData*)_sealUnauthenticatedRecord:(NSMutableData*)data originalLength:(u_int32_t)originalLength {
	WALRecordHeader record = {{0}};
	record.originalDataLength = CFSwapInt32HostToBig(originalLength);
	
	NSData *recordSalt = [NSData randomDataOfLength:RECORD_SALT_LEN];
	NSData *recordKey = [logSessionKey derivedKeyOfLength:[logSessionKey length] salt:recordSalt iterations:1];
	if (!recordSalt || ![data encryptAESDataWithKey:recordKey iv:[recordSalt subdataWithRange:NSMakeRange(0, 16)]])
		return nil;
	if ([data length] > UINT32_MAX) return nil;
	
	record.dataLength = CFSwapInt32HostToBig((uint32_t)[data length]);
	record.checksum = CFSwapInt32HostToBig((uint32_t)[data CRC32]);
	memcpy(record.saltBuffer, [recordSalt bytes], RECORD_SALT_LEN);
	return [NSData dataWithBytes:record.recordBuffer length:sizeof(record.recordBuffer)];
}

- (NSData*)_sealAuthenticatedRecord:(NSMutableData*)data originalLength:(u_int32_t)originalLength {
	WALAuthenticatedRecordHeader record = {{0}};
	record.originalDataLength = CFSwapInt32HostToBig(originalLength);
	
	NSData *iv = [NSData randomDataOfLength:RECORD_IV_LEN];
	if (!iv || ![data encryptAESDataWithKey:recordEncryptionKey iv:iv])
		return nil;
	if ([data length] > UINT32_MAX) return nil;
	
	record.dataLength = CFSwapInt32HostToBig((uint32_t)[data length]);
	memcpy(record.iv, [iv bytes], RECORD_IV_LEN);
	NSData *authenticatedHeader = [NSData dataWithBytesNoCopy:record.recordBuffer length:AUTHENTICATED_HEADER_LEN freeWhenDone:NO];
	memcpy(record.tag, [NVHMACSHA256(recordAuthenticationKey, authenticatedHeader, data) bytes], RECORD_TAG_LEN);
	return [NSData dataWithBytes:record.recordBuffer length:sizeof(record.recordBuffer)];
}

- (BOOL)_encryptAndWriteData:(NSMutableData*)data {
	if ([data length] > UINT32_MAX - 32) return NO;
	u_int32_t originalLength = (u_int32_t)[data length];
	
	size_t compressedDataBufferSize = [data length] + (( [data length] + 99 ) / 100 ) + 12;
	if (compressedDataBufferSize > UINT_MAX) return NO;
    Bytef *compressedDataBuffer = (Bytef *)malloc(compressedDataBufferSize);
    if (!compressedDataBuffer) return NO;
	
    //adapt nsdata to compression stream
	compressionStream.next_in = (Bytef*)[data bytes];
	compressionStream.avail_in = (uInt)[data length];
	compressionStream.next_out = compressedDataBuffer;
	compressionStream.avail_out = (uInt)compressedDataBufferSize;
	compressionStream.data_type = Z_BINARY;
	
	uLong previousOut = compressionStream.total_out;
	/* Perform the compression here. */
	int deflateResult = deflate(&compressionStream, Z_SYNC_FLUSH);
	/*Find the total size of the resulting compressed data. */
	uLong zlibAfterBufLen = compressionStream.total_out - previousOut;

	if (deflateResult != Z_OK) {
		NSLog(@"zlib deflation error: %s\n", compressionStream.msg);
		return NO;
	}
	if (zlibAfterBufLen > compressedDataBufferSize) {
		NSLog(@"zlibAfterBufLen is larger than the allocated compressed buffer!");
		return NO;
	}
	
	[data setLength:zlibAfterBufLen];
	memcpy([data mutableBytes], compressedDataBuffer, zlibAfterBufLen);
	free(compressedDataBuffer);
    
	NSData *header = authenticatedRecords ? [self _sealAuthenticatedRecord:data originalLength:originalLength] :
		[self _sealUnauthenticatedRecord:data originalLength:originalLength];
	if (!header) {
		NSLog(@"Couldn't encrypt WAL record data!");
		return NO;
	}
    
    //pack the header and ciphertext to avoid multiple writes
    size_t dataChunkSize = [header length] + [data length];
    char *dataChunk = (char*)malloc(dataChunkSize);
    
    memcpy(dataChunk, [header bytes], [header length]);
    memcpy(dataChunk + [header length], [data bytes], [data length]);
    
    ssize_t bytesWritten = 0;
    
    //attempt to write any buffered data first
    if ([self _attemptToWriteUnwrittenData]) {
		//always append data in the right order; if there is old buffered data, then the new data is buffered until that is empty
		//otherwise the new data is appended immediately
		
		bytesWritten = write(logFD, dataChunk, dataChunkSize);
    }
    
    if (bytesWritten < 0) {
		NSLog(@"Unable to write new data to journal %s: %s", journalFile, strerror(errno));
		bytesWritten = 0;
    }
	
    if ((size_t)bytesWritten < dataChunkSize) {
		//buffer any remaining data that we were not able to write (in case the disk was full, for example)
		[unwrittenData appendBytes:dataChunk + bytesWritten length:(dataChunkSize - bytesWritten)];
    }
    
    free(dataChunk);
    
    return ((size_t)bytesWritten == dataChunkSize);
}

- (BOOL)synchronize {
    
    BOOL flushedUnwritten = [self _attemptToWriteUnwrittenData];
    
    //F_FULLFSYNC is probably overkill
    if (fsync(logFD)) {
	NSLog(@"synchronize WAL: fsync error: %s", strerror(errno));
	return NO;
    }
    
    return flushedUnwritten;
}

@end

@implementation WALRecoveryController

//record structure:
//int size
//int CRC32
//bytes from NSData

//general operation for recovering log:
//if walstoragecontroller couldn't be initialized, then the file probably already exists
//so try to initialize it here
//if that works, call recoverNextObject sequentially until it returns nil

//re-serialize all the (now-recovered) notes to database

//if that works, then remove the log file

- (instancetype)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key {
	return [self initWithParentFSRep:path encryptionKey:key acceptingUnauthenticatedRecords:NO];
}

- (instancetype)initWithParentFSRep:(const char*)path encryptionKey:(NSData*)key acceptingUnauthenticatedRecords:(BOOL)acceptsUnauthenticated {
    if ((self = [super initWithParentFSRep:path encryptionKey:key])) {
	fileLength = totalBytesRead = 0;
	acceptsUnauthenticatedRecords = acceptsUnauthenticated;
	
	//make file readable just in case
	chmod(journalFile, S_IRUSR);
	
	//attempt to open file read-only
	if ((logFD = open(journalFile, O_EXCL | O_RDONLY)) < 0) {
	    NSLog(@"WALRecoveryController: open error for file %s: %s", journalFile, strerror(errno));
	    return nil;
	}
	
	struct stat sb;
	if (fstat(logFD, &sb) < 0) {
	    NSLog(@"WALRecoveryController: fstat error for file %s: %s", journalFile, strerror(errno));
	    return nil;
	}
	
	if (S_ISDIR(sb.st_mode)) {
	    NSLog(@"WALRecoveryController: log file is actually a directory! Don't play games with me!");
	    return nil;
	}
	
	fileLength = sb.st_size;
	
	char magic[sizeof(WALAuthenticatedJournalMagic)];
	if (read(logFD, magic, sizeof(magic)) == sizeof(magic) && !memcmp(magic, WALAuthenticatedJournalMagic, sizeof(magic))) {
		authenticatedJournal = YES;
		totalBytesRead = sizeof(magic);
	} else if (lseek(logFD, 0, SEEK_SET) < 0) {
		NSLog(@"WALRecoveryController: lseek error for file %s: %s", journalFile, strerror(errno));
		return nil;
	} else if (!acceptsUnauthenticatedRecords && fileLength > 0) {
		NSLog(@"WALRecoveryController: refusing unauthenticated journal %s", journalFile);
		rejectedUnverifiedRecords = YES;
	}
	
	//initialize decompression context
	compressionStream.total_in = 0;
	compressionStream.total_out = 0;
	compressionStream.zalloc = Z_NULL;
	compressionStream.zfree = Z_NULL;
	compressionStream.opaque = Z_NULL;
	
	if (inflateInit2(&compressionStream, MAX_WBITS) != Z_OK) {
		NSLog(@"inflateInit2 error: %s", compressionStream.msg);
		return nil;
	}
	
    }
    return self;
}

- (BOOL)rejectedUnverifiedRecords {
	return rejectedUnverifiedRecords;
}

//returns the decrypted, still-compressed data of the next record written before epoch 5
- (NSMutableData*)_readUnauthenticatedRecordReturningOriginalLength:(u_int32_t*)originalLength {
    WALRecordHeader record = {{0}};
    
    ssize_t readBytes = read(logFD, &record, sizeof(WALRecordHeader));
    totalBytesRead += MAX(0, readBytes);
	
    if (readBytes < (int)sizeof(WALRecordHeader)) {
		NSLog(@"recoverNextObject can't even read (entire) log record header: %s", strerror(errno));
		return nil;
    }
	
	record.originalDataLength = CFSwapInt32BigToHost(record.originalDataLength);
	record.dataLength = CFSwapInt32BigToHost(record.dataLength);
	record.checksum = CFSwapInt32BigToHost(record.checksum);
    
    if (record.dataLength > fileLength - totalBytesRead) {
		NSLog(@"recoverNextObject can't continue because the size of this record is larger than the rest of the file!");
		return nil;
    }
    
    NSMutableData *data = [NSMutableData dataWithLength:record.dataLength];
    readBytes = read(logFD, [data mutableBytes], record.dataLength);
    totalBytesRead += MAX(0, readBytes);
    
    if (readBytes < (ssize_t)record.dataLength) {
		NSLog(@"recoverNextObject can't read all serialized bytes: %s", strerror(errno));
		return nil;
    }
    
    if ([data CRC32] != record.checksum) {
		NSLog(@"recoverNextObject: checksum of read data does not match that of record header");
		return nil;
    }
	    
    //attempt to decrypt using record key based on record salt and log session key
	NSData *recordSalt = [NSData dataWithBytesNoCopy:record.saltBuffer length:RECORD_SALT_LEN freeWhenDone:NO];
	NSData *recordKey = [logSessionKey derivedKeyOfLength:[logSessionKey length] salt:recordSalt iterations:1];
	
	if (!([data decryptAESDataWithKey:recordKey iv:[recordSalt subdataWithRange:NSMakeRange(0, 16)]])) {
		NSLog(@"Record decryption failed!");
		return nil;
	}
	
	*originalLength = record.originalDataLength;
	return data;
}

//returns the decrypted, still-compressed data of the next record, but only once its tag is verified
- (NSMutableData*)_readAuthenticatedRecordReturningOriginalLength:(u_int32_t*)originalLength {
	WALAuthenticatedRecordHeader record = {{0}};
	
	ssize_t readBytes = read(logFD, &record, sizeof(record));
	totalBytesRead += MAX(0, readBytes);
	
	if (readBytes < (ssize_t)sizeof(record)) {
		if (readBytes != 0) NSLog(@"recoverNextObject can't read (entire) log record header: %s", strerror(errno));
		return nil;
	}
	
	u_int32_t dataLength = CFSwapInt32BigToHost(record.dataLength);
	if (!dataLength || dataLength % kCCBlockSizeAES128) {
		NSLog(@"recoverNextObject: journal record length %u is not a whole number of cipher blocks", dataLength);
		rejectedUnverifiedRecords = YES;
		return nil;
	}
	if (dataLength > fileLength - totalBytesRead) {
		NSLog(@"recoverNextObject can't continue because the size of this record is larger than the rest of the file!");
		return nil;
	}
	
	NSMutableData *data = [NSMutableData dataWithLength:dataLength];
	readBytes = read(logFD, [data mutableBytes], dataLength);
	totalBytesRead += MAX(0, readBytes);
	
	if (readBytes < (ssize_t)dataLength) {
		NSLog(@"recoverNextObject can't read all serialized bytes: %s", strerror(errno));
		return nil;
	}
	
	NSData *authenticatedHeader = [NSData dataWithBytesNoCopy:record.recordBuffer length:AUTHENTICATED_HEADER_LEN freeWhenDone:NO];
	NSData *tag = [NSData dataWithBytesNoCopy:record.tag length:RECORD_TAG_LEN freeWhenDone:NO];
	if (!NVTimingSafeEqualData(tag, NVHMACSHA256(recordAuthenticationKey, authenticatedHeader, data))) {
		NSLog(@"recoverNextObject: journal record failed authentication");
		rejectedUnverifiedRecords = YES;
		return nil;
	}
	
	if (![data decryptAESDataWithKey:recordEncryptionKey iv:[NSData dataWithBytesNoCopy:record.iv length:RECORD_IV_LEN freeWhenDone:NO]]) {
		NSLog(@"Record decryption failed!");
		rejectedUnverifiedRecords = YES;
		return nil;
	}
	
	*originalLength = CFSwapInt32BigToHost(record.originalDataLength);
	return data;
}

//log enumerating method
- (id <SynchronizedNote>)recoverNextObject {
    //read, verify and decrypt the next record, then decompress and deserialize it
    //if any of these fail, return nil
	
	u_int32_t originalDataLength = 0;
	NSMutableData *presumablySerializedData = nil;
	if (authenticatedJournal)
		presumablySerializedData = [self _readAuthenticatedRecordReturningOriginalLength:&originalDataLength];
	else if (acceptsUnauthenticatedRecords)
		presumablySerializedData = [self _readUnauthenticatedRecordReturningOriginalLength:&originalDataLength];
	if (!presumablySerializedData)
		return nil;
	
	//decompress here
	Bytef *uncompressedDataBuffer = (Bytef *)malloc(originalDataLength);
	
	compressionStream.avail_in = (uInt)[presumablySerializedData length];
	compressionStream.next_in = (Bytef*)[presumablySerializedData bytes];
	compressionStream.avail_out = originalDataLength;
	compressionStream.next_out = uncompressedDataBuffer;
	compressionStream.data_type = Z_BINARY;
	
	int inflateResult = inflate(&compressionStream, Z_SYNC_FLUSH);
	if (inflateResult == Z_STREAM_ERROR) {
		NSLog(@"zlib inflate error: %s", compressionStream.msg);
		free(uncompressedDataBuffer);
		return nil;
	}
	if (inflateResult == Z_NEED_DICT || inflateResult == Z_DATA_ERROR || 
		inflateResult == Z_MEM_ERROR) {
		NSLog(@"err: inflateResult = %d", inflateResult);
		free(uncompressedDataBuffer);
		return nil;
	}
	
	if (compressionStream.avail_out != 0) {
		NSLog(@"recoverNextObject: compressionStream.avail_out(%d) != 0", compressionStream.avail_out);
		free(uncompressedDataBuffer);
		return nil;
	}
	
	[presumablySerializedData setLength:originalDataLength];
	memcpy([presumablySerializedData mutableBytes], uncompressedDataBuffer, originalDataLength);
	free(uncompressedDataBuffer);
	
    
    id <SynchronizedNote> object = nil;
	@try {
		NSKeyedUnarchiver *unarchiver = NVUnarchiverForData(presumablySerializedData);
		object = [unarchiver decodeObjectOfClasses:[NSSet setWithArray:@[[NoteObject class], [DeletedNoteObject class]]] forKey:@"aNote"];
    } @catch (NSException *e) {
		NSLog(@"recoverNextObject got an exception while unarchiving object: %@; returning NSNull to skip", [e reason]);
		object = (id<SynchronizedNote>)[NSNull null];
    }
    
    return object;
}

static CFStringRef SynchronizedNoteKeyCopyDescription(const void *value) {
	if (!value) return NULL;
	CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, *(CFUUIDBytes*)value);
	CFStringRef description = CFUUIDCreateString(NULL, uuid);
	CFRelease(uuid);
	return description;
}
static CFHashCode SynchronizedNoteHash(const void * o) {
	
	return CFHashBytes(o, sizeof(CFUUIDBytes));
}
static Boolean SynchronizedNoteIsEqual(const void *o, const void *p) {
	
	return (!memcmp((CFUUIDBytes*)o, (CFUUIDBytes*)p, sizeof(CFUUIDBytes)));
}

//we keep a table of the newest recovered notes, as any changed notes will almost certainly be written multiple times
//throw away objects with LSNs lower than the current highest one for each UUID
//and when recovery cannot progress any further, only the newest objects will be exchanged

- (NSDictionary*)recoveredNotes {
    id <SynchronizedNote> obj = nil;
	CFUUIDBytes *objUUIDBytes = NULL;
    
    CFDictionaryKeyCallBacks keyCallbacks = kCFTypeDictionaryKeyCallBacks;
    keyCallbacks.equal = SynchronizedNoteIsEqual;
    keyCallbacks.hash = SynchronizedNoteHash;
	keyCallbacks.copyDescription = SynchronizedNoteKeyCopyDescription;
	keyCallbacks.retain = NULL;
	keyCallbacks.release = NULL;
    
    CFMutableDictionaryRef recoveredNotes = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &keyCallbacks, &kCFTypeDictionaryValueCallBacks);
    
    do {
		if ((obj = [self recoverNextObject])) {
			
			if ([obj conformsToProtocol:@protocol(SynchronizedNote)]) {
				objUUIDBytes = [obj uniqueNoteIDBytes];
				const void *foundNote = NULL;
				
				//if the note already exists, then insert this note only if it's newer, and always insert it if it doesn't exist
				if (CFDictionaryGetValueIfPresent(recoveredNotes, (const void *)objUUIDBytes, &foundNote)) {
					
					//note is already here, overwrite it only if our LSN is greater or equal
					if (foundNote && ![(__bridge id <SynchronizedNote>)foundNote youngerThanLogObject:obj])
						continue;
				}
				CFDictionarySetValue(recoveredNotes, (const void *)objUUIDBytes, (__bridge const void *)obj);
			} else {
				NSLog(@"object of class %@ recovered that doesn't conform to SynchronizedNote protocol", [(NSObject*)obj className]);
			}
		}
    } while (obj); //|| this note failed because of a deserialization problem, but everything else was fine
    
    
	return CFBridgingRelease(recoveredNotes);
}

@end
