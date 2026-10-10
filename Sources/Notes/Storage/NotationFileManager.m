//
//  NotationFileManager.m
//  Notation
//
//  Created by Zachary Schneirov on 4/9/06.

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


#import "NotationFileManager.h"
#import "NotationPrefs.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "NSData_transformations.h"
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include "NVMD5.h"

NSString *NotesDatabaseFileName = @"Notes & Settings";
NSString *const NotesDirectoryName = @"Notational Data";
NSString *UnverifiedJournalFileName = @"Interim Note-Changes (unverified)";
NSString *PreUpgradeDatabaseFileName = @"Notes & Settings (before security upgrade)";

@implementation NotationController (NotationFileManager)

static struct statfs *StatFSVolumeInfo(NotationController *controller);

OSStatus CreateDirectoryIfNotPresent(NVFileReference *parentRef, CFStringRef subDirectoryName, NVFileReference *childRef) {
    OSStatus result = NVMakeReference(parentRef, subDirectoryName, childRef);
    if (result == NVFileNotFoundErr) {
		result = NVCreateDirectory(parentRef, subDirectoryName, childRef);
    }
    return result;
}

OSStatus CreateTemporaryFile(NVFileReference *parentRef, NVFileReference *childTempRef) {
    OSStatus result = noErr;
    
    do {
		CFStringRef filename = CreateRandomizedFileName();
		result = NVMakeReference(parentRef, filename, childTempRef);
		if (result == NVFileNotFoundErr) {
			result = NVCreateFile(parentRef, filename, childTempRef);
			CFRelease(filename);
			return result;
		}
		CFRelease(filename);
		
    } while (result == noErr);
    
    return result;
}


/*
 Read the UUID from a mounted volume, by calling getattrlist().
 Assumes the path is the mount point of an HFS volume.
 */
static BOOL GetVolumeUUIDAttr(const char *path, VolumeUUID *volumeUUIDPtr) {
	struct attrlist alist;
	struct FinderAttrBuf {
		u_int32_t info_length;
		u_int32_t finderinfo[8];
	} volFinderInfo;
	
	int result = -1;
	
	/* Set up the attrlist structure to get the volume's Finder Info */
	alist.bitmapcount = 5;
	alist.reserved = 0;
	alist.commonattr = ATTR_CMN_FNDRINFO;
	alist.volattr = ATTR_VOL_INFO;
	alist.dirattr = 0;
	alist.fileattr = 0;
	alist.forkattr = 0;
	
	/* Get the Finder Info */
	if ((result = getattrlist(path, &alist, &volFinderInfo, sizeof(volFinderInfo), 0))) {
		NSLog(@"GetVolumeUUIDAttr error: %d", result);
		return NO;
	}
	
	/* Copy the UUID from the Finder Into to caller's buffer */
	VolumeUUID *finderInfoUUIDPtr = (VolumeUUID *)(&volFinderInfo.finderinfo[6]);
	volumeUUIDPtr->v.high = CFSwapInt32BigToHost(finderInfoUUIDPtr->v.high);
	volumeUUIDPtr->v.low = CFSwapInt32BigToHost(finderInfoUUIDPtr->v.low);
	
	return YES;
}


// Create a version 3 UUID; derived using "name" via MD5 checksum.
static void uuid_create_md5_from_name(unsigned char result_uuid[16], const void *name, int namelen) {
	
	static unsigned char FSUUIDNamespaceSHA1[16] = { 
		0xB3, 0xE2, 0x0F, 0x39, 0xF2, 0x92, 0x11, 0xD6, 
		0x97, 0xA4, 0x00, 0x30, 0x65, 0x43, 0xEC, 0xAC
	};
	
    NVMD5_CTX c;
	
    NVMD5Init(&c);
    NVMD5Update(&c, FSUUIDNamespaceSHA1, sizeof(FSUUIDNamespaceSHA1));
    NVMD5Update(&c, name, namelen);
    NVMD5Final(result_uuid, &c);
	
    result_uuid[6] = (result_uuid[6] & 0x0F) | 0x30;
    result_uuid[8] = (result_uuid[8] & 0x3F) | 0x80;
}


CFUUIDRef CopyHFSVolumeUUIDForMount(const char *mntonname) {
	VolumeUUID targetVolumeUUID;
	
	unsigned char rawUUID[8];
	
	if (!GetVolumeUUIDAttr(mntonname, &targetVolumeUUID))
		return NULL;
	
	((uint32_t *)rawUUID)[0] = CFSwapInt32HostToBig(targetVolumeUUID.v.high);
	((uint32_t *)rawUUID)[1] = CFSwapInt32HostToBig(targetVolumeUUID.v.low);
	
	CFUUIDBytes uuidBytes;
	uuid_create_md5_from_name((void*)&uuidBytes, rawUUID, sizeof(rawUUID));
	
	return CFUUIDCreateFromUUIDBytes(NULL, uuidBytes);
}

CFUUIDRef CopySyntheticUUIDForVolumeCreationDate(NVFileReference *ref) {
    char path[PATH_MAX];
    struct statfs volume;
    struct stat info;
    if (NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path)) || statfs(path, &volume) || stat(volume.f_mntonname, &info)) return NULL;
    NVArchivedDate date = NVArchivedDateFromTimespec(info.st_birthtimespec);
    date.highSeconds = CFSwapInt16HostToBig(date.highSeconds);
    date.lowSeconds = CFSwapInt32HostToBig(date.lowSeconds);
    date.fraction = CFSwapInt16HostToBig(date.fraction);
    CFUUIDBytes uuid;
    uuid_create_md5_from_name((void *)&uuid, &date, sizeof(date));
    return CFUUIDCreateFromUUIDBytes(NULL, uuid);
}

- (void)purgeOldPerDiskInfoFromNotes {
	//here's where notes' PerDiskInfo arrays would have older times removed, depending on -[DiskUUIDEntry lastAccessed]
	//each note will use RemovePerDiskInfoWithTableIndex
}

- (void)initializeDiskUUIDIfNecessary {
	//create a CFUUIDRef that identifies the volume this database sits on
	
	//don't bother unless we will be reading notes as separate files; otherwise there's no need to track the source of the attr mod dates
	//maybe disk UUIDs will be used in the future for something else; at that point this check should be altered
	
	if (!diskUUID && [self currentNoteStorageFormat] != SingleDatabaseFormat) {
		
		struct statfs * sfsb = StatFSVolumeInfo(self);
		//if this is not an hfs+ disk, then get the FSEvents UUID
		//if this is not Leopard or the FSEvents UUID is null, 
		//then take MD5 sum of creation date + some other info?

		if (sfsb && !strcmp(sfsb->f_fstypename, "hfs")) {
			//if this is an HFS volume, then use getattrlist to get finderinfo from the volume
			diskUUID = CopyHFSVolumeUUIDForMount(sfsb->f_mntonname);
		}

		if (!diskUUID && sfsb) {
			//this is not an hfs disk
			diskUUID = FSEventsCopyUUIDForDevice(sfsb->f_fsid.val[0]);
		}
		
		if (!diskUUID) {
			//all other checks failed; just use the volume's creation date
			diskUUID = CopySyntheticUUIDForVolumeCreationDate(&noteDirectoryRef);
		}
		NSUInteger index = [notationPrefs tableIndexOfDiskUUID:diskUUID];
        if (index > UINT32_MAX) [NSException raise:NSRangeException format:@"Too many disk identities"];
        diskUUIDIndex = (UInt32)index;
	}
}

static struct statfs *StatFSVolumeInfo(NotationController *controller) {
	if (!controller->statfsInfo) {
		OSStatus err = noErr;
		const UInt32 maxPathSize = 4 * 1024;
		UInt8 *convertedPath = (UInt8*)malloc(maxPathSize * sizeof(UInt8));
		
		if ((err = NVReferenceMakePath(&(controller->noteDirectoryRef), convertedPath, maxPathSize)) == noErr) {
			
			controller->statfsInfo = calloc(1, sizeof(struct statfs));
			
			if (statfs((char*)convertedPath, controller->statfsInfo))
				NSLog(@"statfs: error %d\n", errno);
		} else
			NSLog(@"NVReferenceMakePath: error %d\n", err);
		
		free(convertedPath);
	}
	return controller->statfsInfo;
}

UInt32 diskUUIDIndexForNotation(NotationController *controller) {
	return controller->diskUUIDIndex;
}

long BlockSizeForNotation(NotationController *controller) {
    if (!controller->blockSize) {
		long iosize = 0;

		struct statfs * sfsb = StatFSVolumeInfo(controller);
		if (sfsb) iosize = sfsb->f_iosize;
		
		controller->blockSize = MAX(iosize, 16 * 1024);
    }
    
    return controller->blockSize;
}

- (OSStatus)refreshFileRefIfNecessary:(NVFileReference *)childRef withName:(NSString *)filename {
	BOOL isOwned = NO;
	if (IsZeros(childRef, sizeof(NVFileReference)) || [self fileInNotesDirectory:childRef isOwnedByUs:&isOwned hasFileInfo:NULL] != noErr || !isOwned) {
		OSStatus err = noErr;
		if ((err = NVMakeReference(&noteDirectoryRef, (__bridge CFStringRef)filename, childRef)) != noErr) {
			NSLog(@"Could not get an fsref for file with name %@: %d\n", filename, err);
			return err;
		}
    }
	return noErr;
}


- (BOOL)notesDirectoryIsTrashed {
    NSString *path = [[NSFileManager defaultManager] pathWithFSRef:&noteDirectoryRef];
    NSArray *components = [path pathComponents];
    return [components containsObject:@".Trash"] || [components containsObject:@".Trashes"];
}

- (BOOL)notesDirectoryContainsFile:(NSString*)filename returningFSRef:(NVFileReference*)childRef {
	if (!filename) return NO;
	
	return NVMakeReference(&noteDirectoryRef, (__bridge CFStringRef)filename, childRef) == noErr;
}

- (OSStatus)renameAndForgetNoteDatabaseFile:(NSString*)newfilename {
	//this method does not move the note database file; for now it is used in cases of upgrading incompatible files
	
    OSStatus err = noErr;	
    if ((err = NVRename(&noteDatabaseRef, (__bridge CFStringRef)newfilename, NULL)) != noErr) {
		NSLog(@"Error renaming notes database file to %@: %d", newfilename, err);
		return err;
    }
	//reset the NVFileReference to ensure it doesn't point to the renamed file
	bzero(&noteDatabaseRef, sizeof(NVFileReference));
	return noErr;
}

- (BOOL)removeSpuriousDatabaseFileNotes {
	//remove any notes that might have been made out of the database or write-ahead-log files by accident
	//but leave the files intact; ensure only that they are also remotely unsynced
	//returns true if at least one note was removed, in which case allNotes should probably be refiltered
	
	NSUInteger i = 0;
	NoteObject *dbNote = nil, *walNote = nil;
	
	for (i=0; i<[allNotes count]; i++) {
		NoteObject *obj = [allNotes objectAtIndex:i];
		
		if (!dbNote && [filenameOfNote(obj) isEqualToString:NotesDatabaseFileName])
			dbNote = obj;
		if (!walNote && [filenameOfNote(obj) isEqualToString:@"Interim Note-Changes"])
			walNote = obj;
	}
	if (dbNote) {
		[allNotes removeObjectIdenticalTo:dbNote];
		[self _addDeletedNote:dbNote];
	}
	if (walNote) {
		[allNotes removeObjectIdenticalTo:walNote];
		[self _addDeletedNote:walNote];
	}
	return walNote || dbNote;
}

- (void)relocateNotesDirectory {
	
	while (1) {
		NSOpenPanel *openPanel = [NSOpenPanel openPanel];
		[openPanel setCanCreateDirectories:YES];
		[openPanel setCanChooseFiles:NO];
		[openPanel setCanChooseDirectories:YES];
		[openPanel setResolvesAliases:YES];
		[openPanel setAllowsMultipleSelection:NO];
		[openPanel setTreatsFilePackagesAsDirectories:NO];
		[openPanel setTitle:NSLocalizedString(@"Select a folder",nil)];
		[openPanel setPrompt:NSLocalizedString(@"Select",nil)];
		[openPanel setMessage:NSLocalizedString(@"Select a new location for your Notational Velocity notes.",nil)];
		
		if ([openPanel runModal] == NSModalResponseOK) {
			NSString *filename = [[openPanel URL] path];
			if (filename) {
				
				NVFileReference newParentRef;
				NSURL *url = CFBridgingRelease(CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (__bridge CFStringRef)filename, kCFURLPOSIXPathStyle, true));
				if (!url || !NVURLGetFileReference((__bridge CFURLRef)url, &newParentRef)) {
					NVRunAlert(NSAlertStyleWarning, NSLocalizedString(@"The chosen folder could not be used.", nil), NSLocalizedString(@"Your notes were not moved.",nil), NSLocalizedString(@"OK",nil), NULL, NULL);
					continue;
				}
				
				NVFileReference newNotesDirectory;
				OSStatus err = NVMoveObject(&noteDirectoryRef,  &newParentRef, &newNotesDirectory);
				if (err != noErr) {
					NVRunAlert(NSAlertStyleWarning, [NSString stringWithFormat:NSLocalizedString(@"Couldn't move notes into the chosen folder because %@",nil),
						[NSString reasonStringFromCarbonFSError:err]], NSLocalizedString(@"Your notes were not moved.",nil), NSLocalizedString(@"OK",nil), NULL, NULL);
					continue;
				}
				
				if (NVCompareReferences(&noteDirectoryRef, &newNotesDirectory) != noErr) {
					NSData *aliasData = [NSData aliasDataForFSRef:&newNotesDirectory];
					if (aliasData) [[GlobalPrefs defaultPrefs] setAliasDataForDefaultDirectory:aliasData sender:self];
					//we must quit now, as notes will very likely be re-initialized in the same place
					goto terminate;
				}
				
				//directory move successful! //show the user where new notes are
				NSString *newNotesPath = [[NSFileManager defaultManager] pathWithFSRef:&newNotesDirectory];
				if (newNotesPath) [[NSWorkspace sharedWorkspace] selectFile:newNotesPath inFileViewerRootedAtPath:@""];
				
				break;
			} else {
				goto terminate;
			}
		} else {
terminate:
			[NSApp terminate:nil];
			break;
		}
	}
}

+ (OSStatus)getDefaultNotesDirectoryRef:(NVFileReference *)ref {
    NSError *error = nil;
    NSURL *support = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:&error];
    NVFileReference parent;
    if (!NVURLGetFileReference((__bridge CFURLRef)support, &parent)) return error ? NVStatusFromErrno((int)[error code]) : NVFileNotFoundErr;
    return CreateDirectoryIfNotPresent(&parent, (__bridge CFStringRef)NotesDirectoryName, ref);
}

- (NSString*)uniqueFilenameForTitle:(NSString*)title fromNote:(NoteObject*)note {
    //generate a unique filename based on title, varying numbers
    BOOL isUnique = YES;
    NSString *uniqueFilename = title;
	
	//remove illegal characters
	NSMutableString *sanitizedName = [[uniqueFilename stringByReplacingOccurrencesOfString:@":" withString:@"-"] mutableCopy];
	if ([sanitizedName characterAtIndex:0] == (unichar)'.')	[sanitizedName replaceCharactersInRange:NSMakeRange(0, 1) withString:@"_"];
	uniqueFilename = [sanitizedName copy];
	
	//use the note's current format if the current default format is for a database; get the "ideal" extension for that format
	int noteFormat = [notationPrefs notesStorageFormat] || !note ? [notationPrefs notesStorageFormat] : storageFormatOfNote(note);
	NSString *extension = [notationPrefs chosenPathExtensionForFormat:noteFormat];
	
	//if the note's current extension is compatible with the storage format above, then use the existing extension instead
	if (note && filenameOfNote(note) && [notationPrefs pathExtensionAllowed:[filenameOfNote(note) pathExtension] forFormat:noteFormat])
		extension = [filenameOfNote(note) pathExtension];
	
	//assume that we won't have more than 999 notes with the exact same name and of more than 247 chars
	uniqueFilename = [uniqueFilename filenameExpectingAdditionalCharCount:3 + [extension length] + 2];
	
    unsigned int iteration = 0;
    do {
		isUnique = YES;
		unsigned int i;
		
		//this ought to just use an nsset, but then we'd have to maintain a parallel data structure for marginal benefit
		//also, it won't quite work right for filenames with no (real) extensions and periods in their names
		for (i=0; i<[allNotes count]; i++) {
			NoteObject *aNote = [allNotes objectAtIndex:i];
			NSString *basefilename = [filenameOfNote(aNote) stringByDeletingPathExtension];
			
			if (note != aNote && [basefilename caseInsensitiveCompare:uniqueFilename] == NSOrderedSame) {
				isUnique = NO;
				
				uniqueFilename = [uniqueFilename stringByDeletingPathExtension];
				NSString *numberPath = [@(++iteration) stringValue];
				uniqueFilename = [uniqueFilename stringByAppendingPathExtension:numberPath];
				break;
			}
		}
    } while (!isUnique);
	
    return [uniqueFilename stringByAppendingPathExtension:extension];
}

- (OSStatus)noteFileRenamed:(NVFileReference*)childRef fromName:(NSString*)oldName toName:(NSString*)newName {
    if (![self currentNoteStorageFormat])
		return noErr;
    
    OSStatus err = [self refreshFileRefIfNecessary:childRef withName:oldName];
	if (noErr != err) return err;
    
    if ((err = NVRename(childRef, (__bridge CFStringRef)newName, childRef)) != noErr) {
		NSLog(@"Error renaming file %@ to %@: %d", oldName, newName, err);
		return err;
    }
    
    return noErr;
}

- (OSStatus)fileInNotesDirectory:(NVFileReference*)childRef isOwnedByUs:(BOOL*)owned hasFileInfo:(NVFileInfo *)info {
    NVFileReference parentRef;
    
    if (owned) *owned = NO;
    if (info) bzero(info, sizeof(NVFileInfo));
    
    OSStatus err = noErr;
    
    if ((err = NVGetFileInfo(childRef, info, NULL, &parentRef)) != noErr)
	return err;
    
    if (owned) *owned = (NVCompareReferences(&parentRef, &noteDirectoryRef) == noErr);
    
    return noErr;
}

- (OSStatus)deleteFileInNotesDirectory:(NVFileReference*)childRef forFilename:(NSString*)filename {
    OSStatus err = [self refreshFileRefIfNecessary:childRef withName:filename];
    if (noErr != err) return err;

	if ((err = NVDeleteObject(childRef)) != noErr) {
		NSLog(@"Error deleting file: %d", err);
		return err;
	}
    
    return noErr;
}

- (NSMutableData*)dataFromFileInNotesDirectory:(NVFileReference*)childRef forFilename:(NSString*)filename {
    return [self dataFromFileInNotesDirectory:childRef forFilename:filename fileSize:0];
}

- (NSMutableData*)dataFromFileInNotesDirectory:(NVFileReference*)childRef forCatalogEntry:(NoteCatalogEntry*)catEntry {
    return [self dataFromFileInNotesDirectory:childRef forFilename:(__bridge NSString*)catEntry->filename fileSize:catEntry->logicalSize];
}

- (NSMutableData*)dataFromFileInNotesDirectory:(NVFileReference*)childRef forFilename:(NSString*)filename fileSize:(UInt64)givenFileSize {
	
    UInt64 fileSize = givenFileSize;
    char *notesDataPtr = NULL;
    
	OSStatus err = [self refreshFileRefIfNecessary:childRef withName:filename];
	if (noErr != err) return nil;
	
    if ((err = NVReadFile(childRef, BlockSizeForNotation(self), &fileSize, (void**)&notesDataPtr, true)) != noErr) {
		NSLog(@"%s: error %d", sel_getName(_cmd), err);
		return nil;
	}    
    if (!notesDataPtr)
		return nil;
    
    return [[NSMutableData alloc] initWithBytesNoCopy:notesDataPtr length:fileSize freeWhenDone:YES];
}

- (OSStatus)createFileIfNotPresentInNotesDirectory:(NVFileReference*)childRef forFilename:(NSString*)filename fileWasCreated:(BOOL*)created {
	
	return NVCreateFileIfNotPresent(&noteDirectoryRef, (__bridge CFStringRef)filename, childRef, (Boolean*)created);
}

- (OSStatus)storeDataAtomicallyInNotesDirectory:(NSData*)data withName:(NSString*)filename destinationRef:(NVFileReference*)destRef {
	return [self storeDataAtomicallyInNotesDirectory:data withName:filename destinationRef:destRef verifyWithSelector:NULL verificationDelegate:nil];
}

//either name or destRef must be valid; destRef is declared invalid by filling the struct with 0

- (OSStatus)storeDataAtomicallyInNotesDirectory:(NSData*)data withName:(NSString*)filename destinationRef:(NVFileReference*)destRef
							 verifyWithSelector:(SEL)verificationSel verificationDelegate:(id)verifyDelegate {
    OSStatus err = noErr;
    	
	NVFileReference tempFileRef;
    if ((err = CreateTemporaryFile(&noteDirectoryRef, &tempFileRef)) != noErr) {
		NSLog(@"error creating temporary file: %d", err);
		return err;
    }
    
    //now write to temporary file and swap
    if ((err = NVWriteFile(&tempFileRef, BlockSizeForNotation(self), [data length], [data bytes], false, false)) != noErr) {
		NSLog(@"error writing to temporary file: %d", err);
		
		return err;
    }
	
	//before we try to swap the data contents of this temp file with the (possibly even soon-to-be-created) Notes & Settings file,
	//try to read it back and see if it can be decrypted and decoded:
	if (verifyDelegate && verificationSel) {
		NSNumber *(*verify)(id, SEL, NSValue *, NSString *) = (void *)[verifyDelegate methodForSelector:verificationSel];
		if (noErr != (err = [verify(verifyDelegate, verificationSel, [NSValue valueWithPointer:&tempFileRef], filename) intValue])) {
			NSLog(@"couldn't verify written notes, so not continuing to save");
			(void)NVDeleteObject(&tempFileRef);
			return err;
		}
	}
    
	//don't try to make a new fsref if the file is still inside notes folder, but perhaps under a different name
	BOOL isOwned = NO;
	if (IsZeros(destRef,sizeof(NVFileReference)) || [self fileInNotesDirectory:destRef isOwnedByUs:&isOwned hasFileInfo:NULL] != noErr || !isOwned) {
		
		if ((err = [self createFileIfNotPresentInNotesDirectory:destRef forFilename:filename fileWasCreated:nil]) != noErr) {
			NSLog(@"error creating or getting fsref for file %@: %d", filename, err);
			return err;
		}
    }
    //if destRef is not zeros, just assume that it exists and retry if it doesn't
	NVFileReference newSourceRef, newDestRef;
	
    err = NVExchangeFiles(&tempFileRef, destRef, &newSourceRef, &newDestRef);
    if (err == noErr) {
        tempFileRef = newSourceRef;
        *destRef = newDestRef;
    }

    if (err != noErr) {
		NSLog(@"error exchanging contents of temporary file with destination file %@: %d",filename, err);
		return err;
    }
    
    if ((err = NVDeleteObject(&tempFileRef)) != noErr) {
		NSLog(@"Error deleting temporary file: %d; moving to trash", err);
		if ((err = [self moveFileToTrash:&tempFileRef forFilename:nil]) != noErr)
			NSLog(@"Error moving file to trash: %d\n", err);
    }
    
    return noErr;
}




- (OSStatus)moveFileToTrash:(NVFileReference *)ref forFilename:(NSString *)filename {
    OSStatus error = [self refreshFileRefIfNecessary:ref withName:filename];
    if (error) return error;
    NSString *path = [[NSFileManager defaultManager] pathWithFSRef:ref];
    NSError *failure = nil;
    if (![[NSFileManager defaultManager] trashItemAtURL:[NSURL fileURLWithPath:path] resultingItemURL:NULL error:&failure])
        return NVStatusFromErrno((int)[failure code]);
    memset(ref, 0, sizeof(*ref));
    return noErr;
}

@end
