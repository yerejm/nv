//
//  FrozenNotation.m
//  Notation
//
//  Created by Zachary Schneirov on 4/4/06.

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


#import "FrozenNotation.h"
#import "PassphraseRetriever.h"
#import "NSData_transformations.h"
#import "NotationPrefs.h"
#import "NoteObject.h"
#import "DeletedNoteObject.h"

@implementation FrozenNotation

+ (BOOL)supportsSecureCoding {
	return YES;
}

- (id)initWithCoder:(NSCoder*)decoder {
	if ([decoder containsValueForKey:VAR_STR(prefs)]) {
		prefs = [decoder decodeObjectOfClass:[NotationPrefs class] forKey:VAR_STR(prefs)];
		notesData = [decoder decodeObjectOfClass:[NSMutableData class] forKey:VAR_STR(notesData)];
		deletedNoteSet = [NVDecodeObjectOfClasses(decoder, [NSSet setWithObjects:[NSSet class], [DeletedNoteObject class], nil],
												  [NSSet class], VAR_STR(deletedNoteSet)) mutableCopy];
	} else {
		NSLog(@"FrozenNotation: decoding legacy %@", decoder);
		prefs = [decoder decodeObject];
		notesData = [decoder decodeObject];
		(void)[decoder decodeObject];
	}	
	return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	if ([coder allowsKeyedCoding]) {
		[coder encodeObject:prefs forKey:VAR_STR(prefs)];
		[coder encodeObject:notesData forKey:VAR_STR(notesData)];
		[coder encodeObject:deletedNoteSet forKey:VAR_STR(deletedNoteSet)];
	} else {
		[coder encodeObject:prefs];
		[coder encodeObject:notesData];
		[coder encodeObject:deletedNoteSet];
	}
}

- (id)initWithNotes:(NSMutableArray*)notes deletedNotes:(NSMutableSet*)antiNotes prefs:(NotationPrefs*)somePrefs {
	
	if ((self = [super init])) {

		notesData = [[NSMutableData alloc] init];
		NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
		[archiver encodeObject:notes forKey:@"notes"];
        [archiver finishEncoding];
        [notesData setData:[archiver encodedData]];
		
		prefs = somePrefs;
		deletedNoteSet = antiNotes;		
		
		notesData = [notesData compressedData];
		
		
		if ([somePrefs doesEncryption]) {
			//compress?, reverse?, encrypt notesData based on notationprefs
			//we also want to have the salt reset here, but that requires knowing the original password
			
			if (![prefs encryptDataInNewSession:notesData]) {
				NSLog(@"Couldn't encrypt data!");
				return nil;
			}
		}
		
		if (![notesData length]) {
			NSLog(@"%s: empty notesData; returning nil", sel_getName(_cmd));
			return nil;
		}
	}
	
	return self;
}

+ (NSData*)frozenDataWithExistingNotes:(NSMutableArray*)notes 
						  deletedNotes:(NSMutableSet*)antiNotes 
								 prefs:(NotationPrefs*)prefs {
	FrozenNotation *frozenNotation = [[FrozenNotation alloc] initWithNotes:notes deletedNotes:antiNotes prefs:prefs];

	if (!frozenNotation)
		return nil;
	
	NSData *encodedNotationData = NVArchiveObject(frozenNotation);
	
	return encodedNotationData;
}

- (NSMutableArray*)unpackedNotesWithPrefs:(NotationPrefs*)somePrefs returningError:(OSStatus*)err {
	
	//decrypt notesData if necessary, then unarchive
	
	*err = noErr;
	
	@try {
		if ([somePrefs doesEncryption] && (*err = [somePrefs decryptAndVerifyData:notesData]) != noErr) {
			NSLog(@"Error decrypting data: %d", (int)*err);
			return nil;
		}
		
		notesData = [notesData uncompressedData];
		
		if (!notesData) {
			*err = kCompressionErr;
			NSLog(@"Error decompressing data");
			return nil;
		}
		NSKeyedUnarchiver *unarchiver = NVUnarchiverForData(notesData);
		allNotes = [NVDecodeArrayOfObjectsOfClass(unarchiver, [NoteObject class], @"notes") mutableCopy];
		
	} @catch (NSException *e) {
		*err = kCoderErr;
		NSLog(@"(VERIFY) Error unarchiving notes from data (%@, %@)", [e name], [e reason]);
		return nil;
	}
	
	return allNotes;
}


- (NSMutableArray*)unpackedNotesReturningError:(OSStatus*)err {
	
	//decrypt notesData, grabbing password from from keychain or user as necessary, then unarchive
	
	*err = noErr;
	
	if (!allNotes) {
		
		@try {
			if ([prefs doesEncryption]) {
				BOOL keychainGood = YES;
				if (![prefs storesPasswordInKeychain] || !(keychainGood = [prefs canLoadPassphraseData:[prefs passwordDataFromKeychain]])) {
					
					if (!keychainGood) {
						//reset keychain identifier in case database file was duplicated and password was changed, and this is the old DB
						[prefs forgetKeychainIdentifier];
					}
					NSModalResponse result = [[PassphraseRetriever retrieverWithNotationPrefs:prefs] loadedUserPassphraseData];
					
					if (!result) {
						//must have clicked cancel or equivalent
						*err = kPassCanceledErr;
						return (nil);
					}
					//if result is 1, passphrase should already be loaded
				}
				if ((*err = [prefs decryptAndVerifyData:notesData]) != noErr) {
					NSLog(@"Error decrypting data: %d", (int)*err);
					return(nil);
				}
			}
			
			
			notesData = [notesData uncompressedData];
			
			if (!notesData) {
				*err = kCompressionErr;
				NSLog(@"Error decompressing data");
				return(nil);
			}
            @try {
                NSKeyedUnarchiver *unarchiver = NVUnarchiverForData(notesData);
                allNotes = [NVDecodeArrayOfObjectsOfClass(unarchiver, [NoteObject class], @"notes") mutableCopy];
            } @catch (NSException *e) {
                //only databases from before the first keyed format (epoch 2) can hold positional archives
                if ([prefs epochIteration] >= 2) @throw;
                allNotes = NVUnarchiveLegacyObject(notesData);
            }
		} @catch (NSException *e) {
			*err = kCoderErr;
			NSLog(@"Error unarchiving notes from data (%@, %@)", [e name], [e reason]);
			return(nil);
		}
	}
	
	return allNotes;
}

- (NSMutableSet*)deletedNotes {
	return deletedNoteSet;
}

- (NotationPrefs*)notationPrefs {
	return prefs;
}


@end
