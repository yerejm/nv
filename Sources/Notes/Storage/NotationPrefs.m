//
//  NotationPrefs.m
//  Notation
//
//  Created by Zachary Schneirov on 4/1/06.

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


#import "NotationPrefs.h"
#import "GlobalPrefs.h"
#import "NSString_NV.h"
#import "NSCollection_utils.h"
#import "NotationPrefsViewController.h"
#import "NSData_transformations.h"
#import "NotationFileManager.h"
#import "SecureTextEntryManager.h"
#import "DiskUUIDEntry.h"
#include <Security/Security.h>
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonHMAC.h>
#include <ApplicationServices/ApplicationServices.h>

#define DEFAULT_HASH_ITERATIONS 8000
#define DEFAULT_KEY_LENGTH 256

#define KEYCHAIN_SERVICENAME "Notational Velocity"

#define DATA_ENCRYPTION_PURPOSE "Notational Velocity database encryption"
#define DATA_AUTHENTICATION_PURPOSE "Notational Velocity database authentication"


NSString *NotationPrefsDidChangeNotification = @"NotationPrefsDidChangeNotification";

@implementation NotationPrefs


- (instancetype)init {
    if ((self = [super init])) {
		allowedTypes = NULL;
		
		unsigned int i;
		for (i=0; i<4; i++) {
			typeStrings[i] = [NotationPrefs defaultTypeStringsForFormat:i];
			pathExtensions[i] = [NotationPrefs defaultPathExtensionsForFormat:i];
			chosenExtIndices[i] = 0;
		}
		
		confirmFileDeletion = YES;
		storesPasswordInKeychain = secureTextEntry = doesEncryption = NO;
		syncServiceAccounts = [[NSMutableDictionary alloc] init];
		seenDiskUUIDEntries = [[NSMutableArray alloc] init];
		notesStorageFormat = SingleDatabaseFormat;
		hashIterationCount = DEFAULT_HASH_ITERATIONS;
		keyLengthInBits = DEFAULT_KEY_LENGTH;
		keyDerivationPRF = kCCPRFHmacAlgSHA256;
		formatEpoch = EPOC_ITERATION;
		authenticatesData = YES;
		baseBodyFont = [[GlobalPrefs defaultPrefs] noteBodyFont];
		foregroundColor = [[GlobalPrefs defaultPrefs] foregroundTextColor];
		epochIteration = 0;
		
		[self updateOSTypesArray];
		
		firstTimeUsed = preferencesChanged = YES;
		
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
	return YES;
}

- (instancetype)initWithCoder:(NSCoder*)decoder {
    if ((self = [super init])) {
		NSAssert([decoder allowsKeyedCoding], @"Keyed decoding only!");
		
		//if we're initializing from an archive, we've obviously been run at least once before
		firstTimeUsed = NO;
		
		preferencesChanged = NO;
		
		epochIteration = [decoder decodeInt32ForKey:VAR_STR(epochIteration)];
		notesStorageFormat = [decoder decodeIntForKey:VAR_STR(notesStorageFormat)];
		doesEncryption = [decoder decodeBoolForKey:VAR_STR(doesEncryption)];
		storesPasswordInKeychain = [decoder decodeBoolForKey:VAR_STR(storesPasswordInKeychain)];
		secureTextEntry = [decoder decodeBoolForKey:VAR_STR(secureTextEntry)];
		
		if (!(hashIterationCount = [decoder decodeIntForKey:VAR_STR(hashIterationCount)]))
			hashIterationCount = DEFAULT_HASH_ITERATIONS;
		if (!(keyLengthInBits = [decoder decodeIntForKey:VAR_STR(keyLengthInBits)]))
			keyLengthInBits = DEFAULT_KEY_LENGTH;
		keyDerivationPRF = [decoder containsValueForKey:VAR_STR(keyDerivationPRF)] ?
			(CCPseudoRandomAlgorithm)[decoder decodeInt32ForKey:VAR_STR(keyDerivationPRF)] : kCCPRFHmacAlgSHA1;
		authenticatesData = epochIteration >= FIRST_AUTHENTICATED_EPOCH;
		formatEpoch = authenticatesData ? EPOC_ITERATION : LAST_COMPATIBLE_EPOCH;
		
		@try {
			baseBodyFont = [decoder decodeObjectOfClass:[NSFont class] forKey:VAR_STR(baseBodyFont)];
		} @catch (NSException *e) {
			NSLog(@"Error trying to unarchive default base body font (%@, %@)", [e name], [e reason]);
		}
		if (!baseBodyFont || ![baseBodyFont isKindOfClass:[NSFont class]]) {
			baseBodyFont = [[GlobalPrefs defaultPrefs] noteBodyFont];
			NSLog(@"setting base body to current default: %@", baseBodyFont);
			preferencesChanged = YES;
		}
		//foregroundColor does not receive the same treatment as basebodyfont; in the event of a discrepancy between global and per-db settings,
		//the former is applied to the notes in the database, while the latter is restored from the database itself
		@try {
			foregroundColor = [decoder decodeObjectOfClass:[NSColor class] forKey:VAR_STR(foregroundColor)];
		} @catch (NSException *e) {
			NSLog(@"Error trying to unarchive foreground text color (%@, %@)", [e name], [e reason]);
		}
		if (!foregroundColor || ![foregroundColor isKindOfClass:[NSColor class]]) {
			foregroundColor = [[GlobalPrefs defaultPrefs] foregroundTextColor];
			preferencesChanged = YES;
		}
		
		confirmFileDeletion = [decoder decodeBoolForKey:VAR_STR(confirmFileDeletion)];
		
		unsigned int i;
		for (i=0; i<4; i++) {
			if (!(typeStrings[i] = [[decoder decodeArrayOfObjectsOfClass:[NSString class] forKey:[VAR_STR(typeStrings) stringByAppendingFormat:@".%d",i]] mutableCopy]))
				typeStrings[i] = [NotationPrefs defaultTypeStringsForFormat:i];
			if (!(pathExtensions[i] = [[decoder decodeArrayOfObjectsOfClass:[NSString class] forKey:[VAR_STR(pathExtensions) stringByAppendingFormat:@".%d",i]] mutableCopy]))
				pathExtensions[i] = [NotationPrefs defaultPathExtensionsForFormat:i];
			chosenExtIndices[i] = [decoder decodeIntForKey:[VAR_STR(chosenExtIndices) stringByAppendingFormat:@".%d",i]];
		}
		
		if (!(syncServiceAccounts = [NVDecodeObjectOfClasses(decoder, NVPropertyListClasses(), [NSDictionary class], VAR_STR(syncServiceAccounts)) mutableCopy]))
			syncServiceAccounts = [[NSMutableDictionary alloc] init];
		keychainDatabaseIdentifier = [decoder decodeObjectOfClass:[NSString class] forKey:VAR_STR(keychainDatabaseIdentifier)];
		
		if (!(seenDiskUUIDEntries = [[decoder decodeArrayOfObjectsOfClass:[DiskUUIDEntry class] forKey:VAR_STR(seenDiskUUIDEntries)] mutableCopy]))
			seenDiskUUIDEntries = [[NSMutableArray alloc] init];
		
		masterSalt = [decoder decodeObjectOfClass:[NSData class] forKey:VAR_STR(masterSalt)];
		dataSessionSalt = [decoder decodeObjectOfClass:[NSData class] forKey:VAR_STR(dataSessionSalt)];
		verifierKey = [decoder decodeObjectOfClass:[NSData class] forKey:VAR_STR(verifierKey)];
		
		doesEncryption = doesEncryption && verifierKey && masterSalt;
		
		[self updateOSTypesArray];
    }
	
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	NSAssert([coder allowsKeyedCoding], @"Keyed encoding only!");
	
	/* epochIteration:
	 0: .Blor files
	 1: First NSArchiver (was unused--maps to 0)
	 2: First NSKeyedArchiver
	 3: First syncServicesMD and date created/modified syncing to files
	 4: tracking of file size and attribute mod dates, font foreground colors, openmeta labels
	 5: encrypt-then-MAC for notes and journal records; PBKDF2-SHA256 for passphrases set from now on
	    (new databases only; existing ones stay at 4 until the user upgrades them)
	 */
	[coder encodeInt32:formatEpoch forKey:VAR_STR(epochIteration)];
	
	[coder encodeInt:notesStorageFormat forKey:VAR_STR(notesStorageFormat)];
	[coder encodeBool:doesEncryption forKey:VAR_STR(doesEncryption)];
	[coder encodeBool:storesPasswordInKeychain forKey:VAR_STR(storesPasswordInKeychain)];
	[coder encodeInt:hashIterationCount forKey:VAR_STR(hashIterationCount)];
	[coder encodeInt:keyLengthInBits forKey:VAR_STR(keyLengthInBits)];
	if ([self usesAuthenticatedFormat])
		[coder encodeInt32:(int32_t)keyDerivationPRF forKey:VAR_STR(keyDerivationPRF)];
	[coder encodeBool:secureTextEntry forKey:VAR_STR(secureTextEntry)];
	
	[coder encodeBool:confirmFileDeletion forKey:VAR_STR(confirmFileDeletion)];
	[coder encodeObject:baseBodyFont forKey:VAR_STR(baseBodyFont)];
	[coder encodeObject:foregroundColor forKey:VAR_STR(foregroundColor)];
	
	unsigned int i;
	for (i=0; i<4; i++) {	
		[coder encodeObject:typeStrings[i] forKey:[VAR_STR(typeStrings) stringByAppendingFormat:@".%d",i]];
		[coder encodeObject:pathExtensions[i] forKey:[VAR_STR(pathExtensions) stringByAppendingFormat:@".%d",i]];
		[coder encodeInt:chosenExtIndices[i] forKey:[VAR_STR(chosenExtIndices) stringByAppendingFormat:@".%d",i]];
	}
	
	[coder encodeObject:[self syncServiceAccountsForArchiving] forKey:VAR_STR(syncServiceAccounts)];
	
	[coder encodeObject:keychainDatabaseIdentifier forKey:VAR_STR(keychainDatabaseIdentifier)];
	
	[coder encodeObject:seenDiskUUIDEntries forKey:VAR_STR(seenDiskUUIDEntries)];
	
	[coder encodeObject:masterSalt forKey:VAR_STR(masterSalt)];
	[coder encodeObject:dataSessionSalt forKey:VAR_STR(dataSessionSalt)];
	[coder encodeObject:verifierKey forKey:VAR_STR(verifierKey)];
}


- (void)dealloc {
    if (allowedTypes)
	free(allowedTypes);
}

+ (NSMutableArray*)defaultTypeStringsForFormat:(int)formatID {
    switch (formatID) {
	case SingleDatabaseFormat:
	    return [NSMutableArray arrayWithCapacity:0];
	case PlainTextFormat: 
	    return [NSMutableArray arrayWithObjects:CFBridgingRelease(NVStringFromOSType(TEXT_TYPE_ID)),
			CFBridgingRelease(NVStringFromOSType(UTXT_TYPE_ID)), nil];
	case RTFTextFormat: 
	    return [NSMutableArray arrayWithObjects:CFBridgingRelease(NVStringFromOSType(RTF_TYPE_ID)), nil];
	case HTMLFormat:
	    return [NSMutableArray arrayWithObjects:CFBridgingRelease(NVStringFromOSType(HTML_TYPE_ID)), nil];
	case WordDocFormat:
		return [NSMutableArray arrayWithObjects:CFBridgingRelease(NVStringFromOSType(WORD_DOC_TYPE_ID)), nil];
	default:
	    NSLog(@"Unknown format ID: %d", formatID);
    }
    
    return [NSMutableArray arrayWithCapacity:0];
}

+ (NSMutableArray*)defaultPathExtensionsForFormat:(int)formatID {
    switch (formatID) {
	case SingleDatabaseFormat:
	    return [NSMutableArray arrayWithCapacity:0];
	case PlainTextFormat: 
	    return [NSMutableArray arrayWithObjects:@"txt", @"text", @"utf8", @"taskpaper", nil];
	case RTFTextFormat: 
	    return [NSMutableArray arrayWithObjects:@"rtf", nil];
	case HTMLFormat:
	    return [NSMutableArray arrayWithObjects:@"html", @"htm", nil];
	case WordDocFormat:
		return [NSMutableArray arrayWithObjects:@"doc", nil];
	case WordXMLFormat:
		return [NSMutableArray arrayWithObjects:@"docx", nil];
	default:
	    NSLog(@"Unknown format ID: %d", formatID);
    }
    
    return [NSMutableArray arrayWithCapacity:0];
}

- (BOOL)preferencesChanged {
	return preferencesChanged;
}

- (BOOL)storesPasswordInKeychain {
	return storesPasswordInKeychain;
}

- (int)notesStorageFormat {
	return notesStorageFormat;
}
- (BOOL)confirmFileDeletion {
    return confirmFileDeletion;
}

- (BOOL)doesEncryption {
	return doesEncryption;
}

- (BOOL)secureTextEntry {
	return secureTextEntry;
}

- (NSDictionary*)syncServiceAccounts {
	return syncServiceAccounts;
}

- (NSDictionary*)syncServiceAccountsForArchiving {
	NSMutableDictionary *tempDict = [syncServiceAccounts mutableCopy];
	
	NSEnumerator *enumerator = [tempDict objectEnumerator];
	NSMutableDictionary *account = nil;
	while ((account = [enumerator nextObject])) {
		
		if (![(NSString*)[account objectForKey:@"username"] length]) {
			//don't store the "enabled" flag if the account has no username
			//give password the benefit of the doubt as it may eventually become available via the keychain
			[account removeObjectForKey:@"enabled"];
		}
		[account removeObjectForKey:@"password"];
	}
	return tempDict;
}

- (unsigned int)keyLengthInBits {
    return keyLengthInBits;
}

- (unsigned int)hashIterationCount {
	return hashIterationCount;
}

- (void)setPreferencesAreStored {
	preferencesChanged = NO;
}

- (UInt32)epochIteration {
	return epochIteration;
}

- (UInt32)formatEpoch {
	return formatEpoch;
}

- (BOOL)usesAuthenticatedFormat {
	return formatEpoch >= FIRST_AUTHENTICATED_EPOCH;
}

- (void)setUsesAuthenticatedFormat:(BOOL)value {
	formatEpoch = value ? EPOC_ITERATION : LAST_COMPATIBLE_EPOCH;
	preferencesChanged = YES;
}

- (BOOL)firstTimeUsed {
	return firstTimeUsed;
}

- (void)setForegroundTextColor:(NSColor*)aColor {
	foregroundColor = aColor;
	
	preferencesChanged = YES;
}

- (NSColor*)foregroundColor {
	return foregroundColor;
}

- (void)setBaseBodyFont:(NSFont*)aFont {
	baseBodyFont = aFont;
		
	preferencesChanged = YES;
}

- (NSFont*)baseBodyFont {
	
	return baseBodyFont;
}

- (void)forgetKeychainIdentifier {
	
	keychainDatabaseIdentifier = nil;
	
	preferencesChanged = YES;
}

- (const char *)setKeychainIdentifier {
	if (!keychainDatabaseIdentifier) {
		CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
		keychainDatabaseIdentifier = CFBridgingRelease(CFUUIDCreateString(kCFAllocatorDefault, uuidRef));
		CFRelease(uuidRef);

		preferencesChanged = YES;
	}
	
	return [keychainDatabaseIdentifier UTF8String];
}

- (NSDictionary *)keychainQuery {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @KEYCHAIN_SERVICENAME,
             (__bridge id)kSecAttrAccount: [NSString stringWithUTF8String:[self setKeychainIdentifier]]};
}

- (SecKeychainItemRef)currentKeychainItem {
    NSMutableDictionary *query = [[self keychainQuery] mutableCopy];
    [query setObject:@YES forKey:(__bridge id)kSecReturnRef];
    CFTypeRef item = NULL;
    return SecItemCopyMatching((__bridge CFDictionaryRef)query, &item) == errSecSuccess ? (SecKeychainItemRef)item : NULL;
}

- (void)removeKeychainData {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)[self keychainQuery]);
    if (status != errSecSuccess && status != errSecItemNotFound) NSLog(@"Error deleting keychain item: %d", (int)status);
}

- (NSData *)passwordDataFromKeychain {
    NSMutableDictionary *query = [[self keychainQuery] mutableCopy];
    [query setObject:@YES forKey:(__bridge id)kSecReturnData];
    CFTypeRef data = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &data);
    if (status != errSecSuccess) return nil;
    return CFBridgingRelease(data);
}

- (void)setKeychainData:(NSData *)data {
    NSDictionary *query = [self keychainQuery];
    NSDictionary *attributes = @{(__bridge id)kSecValueData: data};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [query mutableCopy];
        [item addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    if (status != errSecSuccess) NSLog(@"Error storing passphrase in keychain: %d", (int)status);
}

- (void)setStoresPasswordInKeychain:(BOOL)value {
	storesPasswordInKeychain = value;
	preferencesChanged = YES;
	
	if (!storesPasswordInKeychain)
		[self removeKeychainData];
}

- (BOOL)canLoadPassphraseData:(NSData*)passData {
	
	int keyLength = keyLengthInBits/8;
	
	//compute master key given stored salt and # of iterations
	NSData *computedMasterKey = [passData derivedKeyOfLength:keyLength salt:masterSalt iterations:hashIterationCount PRF:keyDerivationPRF];

	//compute verify key given "verify" salt and 1 iteration
	NSData *verifySalt = [NSData dataWithBytesNoCopy:VERIFY_SALT length:sizeof(VERIFY_SALT) freeWhenDone:NO];
	NSData *computedVerifyKey = [computedMasterKey derivedKeyOfLength:keyLength salt:verifySalt iterations:1 PRF:keyDerivationPRF];
	
	//check against verify key data
	if ([computedVerifyKey isEqualToData:verifierKey]) {
		//if computedMasterKey is good, and we don't already have a master key, then this is it
		if (!masterKey)
			masterKey = computedMasterKey;
		
		return YES;
	}
	
	return NO;
	
}

- (BOOL)canLoadPassphrase:(NSString*)pass {
	return [self canLoadPassphraseData:[pass dataUsingEncoding:NSUTF8StringEncoding]];
}

- (BOOL)encryptDataInNewSession:(NSMutableData*)data {
	//ideally we would vary AES algo between 128 and 256 bits depending on key length, 
	//and scale beyond with triplets, quintuplets, and septuplets--but key is not currently user-settable

	//create new dataSessionSalt and key here
	dataSessionSalt = [NSData randomDataOfLength:256];
	authenticatesData = [self usesAuthenticatedFormat];
	
	NSData *iv = [dataSessionSalt subdataWithRange:NSMakeRange(0, kCCBlockSizeAES128)];
	if (!authenticatesData)
		return [data encryptAESDataWithKey:[masterKey derivedKeyOfLength:keyLengthInBits/8 salt:dataSessionSalt iterations:1] iv:iv];
	
	if (![data encryptAESDataWithKey:[masterKey subkeyForPurpose:DATA_ENCRYPTION_PURPOSE salt:dataSessionSalt] iv:iv])
		return NO;
	
	//encrypt-then-MAC: the tag covers the IV and ciphertext and is appended to the ciphertext
	[data appendData:NVHMACSHA256([masterKey subkeyForPurpose:DATA_AUTHENTICATION_PURPOSE salt:dataSessionSalt], iv, data)];
	return YES;
}

- (OSStatus)decryptAndVerifyData:(NSMutableData*)data {
	if (!masterKey || [dataSessionSalt length] < kCCBlockSizeAES128) return kNoAuthErr;
	NSData *iv = [dataSessionSalt subdataWithRange:NSMakeRange(0, kCCBlockSizeAES128)];
	
	if (!authenticatesData) {
		NSData *dataSessionKey = [masterKey derivedKeyOfLength:keyLengthInBits/8 salt:dataSessionSalt iterations:1];
		return [data decryptAESDataWithKey:dataSessionKey iv:iv] ? noErr : kNoAuthErr;
	}
	
	if ([data length] < CC_SHA256_DIGEST_LENGTH) return kDataIntegrityErr;
	NSUInteger ciphertextLength = [data length] - CC_SHA256_DIGEST_LENGTH;
	NSData *ciphertext = [NSData dataWithBytesNoCopy:[data mutableBytes] length:ciphertextLength freeWhenDone:NO];
	NSData *tag = [NSData dataWithBytesNoCopy:(char*)[data mutableBytes] + ciphertextLength length:CC_SHA256_DIGEST_LENGTH freeWhenDone:NO];
	NSData *expectedTag = NVHMACSHA256([masterKey subkeyForPurpose:DATA_AUTHENTICATION_PURPOSE salt:dataSessionSalt], iv, ciphertext);
	if (!NVTimingSafeEqualData(tag, expectedTag)) return kDataIntegrityErr;
	
	[data setLength:ciphertextLength];
	return [data decryptAESDataWithKey:[masterKey subkeyForPurpose:DATA_ENCRYPTION_PURPOSE salt:dataSessionSalt] iv:iv] ? noErr : kDataIntegrityErr;
}

- (BOOL)acceptsUnauthenticatedJournal {
	return ![self usesAuthenticatedFormat];
}

- (void)setPassphraseData:(NSData*)passData inKeychain:(BOOL)inKeychain {
	[self setPassphraseData:passData inKeychain:inKeychain withIterations:hashIterationCount];
}

- (void)setPassphraseData:(NSData*)passData inKeychain:(BOOL)inKeychain withIterations:(int)iterationCount {
	
	hashIterationCount = iterationCount;
	//older versions can only verify passphrases derived with SHA-1
	keyDerivationPRF = [self usesAuthenticatedFormat] ? kCCPRFHmacAlgSHA256 : kCCPRFHmacAlgSHA1;
	int keyLength = keyLengthInBits/8;
	
	//generate and set random salt
	masterSalt = [NSData randomDataOfLength:256];

	//compute and set master key given salt and # of iterations
	masterKey = [passData derivedKeyOfLength:keyLength salt:masterSalt iterations:hashIterationCount PRF:keyDerivationPRF];
	
	//compute and set verify key from master key
	NSData *verifySalt = [NSData dataWithBytesNoCopy:VERIFY_SALT length:sizeof(VERIFY_SALT) freeWhenDone:NO];
	verifierKey = [masterKey derivedKeyOfLength:keyLength salt:verifySalt iterations:1 PRF:keyDerivationPRF];

	//update keychain
	[self setStoresPasswordInKeychain:inKeychain];
	if (inKeychain)
		[self setKeychainData:passData];
	
	preferencesChanged = YES;
	
	if ([delegate respondsToSelector:@selector(databaseEncryptionSettingsChanged)])
		[delegate databaseEncryptionSettingsChanged];
}

- (NSData*)WALSessionKey {
	#define CONST_WAL_KEY "This is a 32 byte temporary key"
	NSData *sessionSalt = [NSData dataWithBytesNoCopy:LOG_SESSION_SALT length:sizeof(LOG_SESSION_SALT) freeWhenDone:NO];
	
	if (!doesEncryption)
		return [NSData dataWithBytesNoCopy:CONST_WAL_KEY length:sizeof(CONST_WAL_KEY) freeWhenDone:NO];

	return [masterKey derivedKeyOfLength:keyLengthInBits/8 salt:sessionSalt iterations:1];
}

- (void)setNotesStorageFormat:(int)formatID {
	if (formatID != notesStorageFormat) {
		int oldFormat = notesStorageFormat;
		notesStorageFormat = formatID;	
		preferencesChanged = YES;
		
		[self updateOSTypesArray];
		
		if ([delegate respondsToSelector:@selector(databaseSettingsChangedFromOldFormat:)])
			[delegate databaseSettingsChangedFromOldFormat:oldFormat];
		
		//should notationprefs need to do this?
		if ([delegate respondsToSelector:@selector(flushEverything)])
			[delegate flushEverything];
	}
}

- (BOOL)shouldDisplaySheetForProposedFormat:(int)proposedFormat {
	BOOL notesExist = YES;
	
	if ([delegate respondsToSelector:@selector(totalNoteCount)])
		notesExist = [delegate totalNoteCount] > 0;

	return (proposedFormat == SingleDatabaseFormat && notesStorageFormat != SingleDatabaseFormat && notesExist);
}

- (void)noteFilesCleanupSheetDidEnd:(NSWindow *)sheet returnCode:(NSModalResponse)returnCode contextInfo:(void *)contextInfo {
	
	NotationPrefsViewController *controller = (__bridge NotationPrefsViewController *)contextInfo;
	NSAssert(controller, @"No contextInfo passed to noteFilesCleanupSheetDidEnd");
	NSAssert([controller respondsToSelector:@selector(notesStorageFormatInProgress)],
			 @"can't get notesStorageFormatInProgress method for changing");

	int newNoteStorageFormat = [controller notesStorageFormatInProgress];
	
	if (returnCode != NSAlertSecondButtonReturn)
		//didn't cancel
		[self setNotesStorageFormat:newNoteStorageFormat];
	
	if (returnCode == NSAlertThirdButtonReturn)
		//tell delegate to delete all its notes' files
		[delegate trashRemainingNoteFilesInDirectory];
	//but what if the files remain after switching to a single-db format--and then the user deletes a bunch of the files themselves?
	//should we switch the currentFormatIDs of those notes to single-db? I guess.
	
	if ([controller respondsToSelector:@selector(notesStorageFormatDidChange)])
		[controller notesStorageFormatDidChange];
	
	if (returnCode != NSAlertSecondButtonReturn) {
		//run queued method
		NSAssert([controller respondsToSelector:@selector(runQueuedStorageFormatChangeInvocation)],
				 @"can't get runQueuedStorageFormatChangeInvocation method for changing");

		[controller runQueuedStorageFormatChangeInvocation];
	}
}

- (void)setConfirmsFileDeletion:(BOOL)value {
    confirmFileDeletion = value;
    preferencesChanged = YES;
}

- (void)setDoesEncryption:(BOOL)value {
	BOOL oldValue = doesEncryption;
	doesEncryption = value;
	
	preferencesChanged = YES;

	if (!doesEncryption) {
		[self removeKeychainData];
	
		//clear out the verifier key and salt?
		verifierKey = nil;
		masterKey = nil;
	}
	
	if (oldValue != value) {
		if ([delegate respondsToSelector:@selector(databaseEncryptionSettingsChanged)])
			[delegate databaseEncryptionSettingsChanged];
	}
}

- (void)setSecureTextEntry:(BOOL)value {
	
	secureTextEntry = value;
	
	preferencesChanged = YES;
	
	SecureTextEntryManager *tem = [SecureTextEntryManager sharedInstance];
	
	if (secureTextEntry) {
		[tem enableSecureTextEntry];
		[tem checkForIncompatibleApps];
	} else {
		//"forget" that the user had disabled the warning dialog when disabling this feature permanently
		[[NSUserDefaults standardUserDefaults] removeObjectForKey:ShouldHideSecureTextEntryWarningKey];
		[tem disableSecureTextEntry];
	}
}

- (NSUInteger)tableIndexOfDiskUUID:(CFUUIDRef)UUIDRef {
	//if this UUID doesn't yet exist, then add it and return the last index
	
	DiskUUIDEntry *diskEntry = [[DiskUUIDEntry alloc] initWithUUIDRef:UUIDRef];
	
	NSUInteger idx = [seenDiskUUIDEntries indexOfObject: diskEntry];
	if (NSNotFound != idx) {
		[[seenDiskUUIDEntries objectAtIndex:idx] see];
		return idx;
	}
	
	NSLog(@"saw new disk UUID: %@ (other disks are: %@)", diskEntry, seenDiskUUIDEntries);
	[seenDiskUUIDEntries addObject:diskEntry];
	
	preferencesChanged = YES;
	
	return [seenDiskUUIDEntries count] - 1;
}

- (void)setKeyLengthInBits:(unsigned int)newLength {
	//can't do this because we don't have password string
}

+ (NSString*)pathExtensionForFormat:(int)format {
    switch (format) {
	case SingleDatabaseFormat:
	case PlainTextFormat:
	    
	    return @"txt";
	case RTFTextFormat:
	    
	    return @"rtf";
	case HTMLFormat:
	    
	    return @"html";
	case WordDocFormat:
		
		return @"doc";
	case WordXMLFormat:
		
		return @"docx";
	default:
	    NSLog(@"storage format ID is unknown: %d", format);
    }
    
    return @"";
}

//for our nstableview data source
- (NSInteger)typeStringsCount {
	if (typeStrings[notesStorageFormat])
		return [typeStrings[notesStorageFormat] count];
	
	return 0;
}
- (NSInteger)pathExtensionsCount {
	if (pathExtensions[notesStorageFormat])
	    return [pathExtensions[notesStorageFormat] count];
	
	return 0;
}

- (NSString*)typeStringAtIndex:(NSInteger)typeIndex {

    return [typeStrings[notesStorageFormat] objectAtIndex:typeIndex];
}
- (NSString*)pathExtensionAtIndex:(NSInteger)pathIndex {
    return [pathExtensions[notesStorageFormat] objectAtIndex:pathIndex];
}
- (unsigned int)indexOfChosenPathExtension {
	return chosenExtIndices[notesStorageFormat];
}
- (NSString*)chosenPathExtensionForFormat:(int)format {
	if (chosenExtIndices[format] >= [pathExtensions[format] count])
		return [NotationPrefs pathExtensionForFormat:format];
	
	return [pathExtensions[format] objectAtIndex:chosenExtIndices[format]];
}

- (void)updateOSTypesArray {
    if (!typeStrings[notesStorageFormat])
	return;
    
    NSUInteger i, newSize = sizeof(OSType) * [typeStrings[notesStorageFormat] count];
    allowedTypes = (OSType*)realloc(allowedTypes, newSize);
	
    for (i=0; i<[typeStrings[notesStorageFormat] count]; i++)
		allowedTypes[i] = NVOSTypeFromString((__bridge CFStringRef)[typeStrings[notesStorageFormat] objectAtIndex:i]);
}

- (void)addAllowedPathExtension:(NSString*)extension {
    
    NSString *actualExt = [extension stringAsSafePathExtension];
	[pathExtensions[notesStorageFormat] addObject:actualExt];
	
	preferencesChanged = YES;
}

- (BOOL)removeAllowedPathExtensionAtIndex:(NSUInteger)extensionIndex {

	if ([pathExtensions[notesStorageFormat] count] > 1 && extensionIndex < [pathExtensions[notesStorageFormat] count]) {
		[pathExtensions[notesStorageFormat] removeObjectAtIndex:extensionIndex];
		
		if (chosenExtIndices[notesStorageFormat] >= [pathExtensions[notesStorageFormat] count])
			chosenExtIndices[notesStorageFormat] = 0;
		
		preferencesChanged = YES;
		return YES;
	}
	return NO;
}
- (BOOL)setChosenPathExtensionAtIndex:(NSUInteger)extensionIndex {
	if ([pathExtensions[notesStorageFormat] count] > extensionIndex &&
		[[pathExtensions[notesStorageFormat] objectAtIndex:extensionIndex] length]) {
		if (extensionIndex > UINT_MAX) return NO;
        chosenExtIndices[notesStorageFormat] = (unsigned int)extensionIndex;
		
		preferencesChanged = YES;
		return YES;
	}
	return NO;
}

- (BOOL)addAllowedType:(NSString*)type {
    
	if (type) {
		[typeStrings[notesStorageFormat] addObject:[type fourCharTypeString]];
		[self updateOSTypesArray];
		
		preferencesChanged = YES;
		return YES;
	}
	return NO;
}

- (void)removeAllowedTypeAtIndex:(NSUInteger)typeIndex {
	[typeStrings[notesStorageFormat] removeObjectAtIndex:typeIndex];
	[self updateOSTypesArray];
	
	preferencesChanged = YES;
}

- (BOOL)setExtension:(NSString*)newExtension atIndex:(unsigned int)oldIndex {
	
    if (oldIndex < [pathExtensions[notesStorageFormat] count]) {
		
		if ([newExtension length] > 0) { 
			[pathExtensions[notesStorageFormat] replaceObjectAtIndex:oldIndex withObject:[newExtension stringAsSafePathExtension]];
			
			preferencesChanged = YES;
		} else if (![(NSString*)[pathExtensions[notesStorageFormat] objectAtIndex:oldIndex] length]) {
			return NO;
		}
    }
	
	return YES;
}

- (BOOL)setType:(NSString*)newType atIndex:(unsigned int)oldIndex {
	
    if (oldIndex < [typeStrings[notesStorageFormat] count]) {
		
		if ([newType length] > 0) {
			[typeStrings[notesStorageFormat] replaceObjectAtIndex:oldIndex withObject:[newType fourCharTypeString]];
			[self updateOSTypesArray];
				
			preferencesChanged = YES;
				
			return YES;
		}
		if (!NVOSTypeFromString((__bridge CFStringRef)[typeStrings[notesStorageFormat] objectAtIndex:oldIndex])) {
			return NO;
		}
    }
	
	return YES;
}

- (BOOL)pathExtensionAllowed:(NSString*)anExtension forFormat:(int)formatID {
	NSUInteger i;
    for (i=0; i<[pathExtensions[formatID] count]; i++) {
		if ([anExtension compare:[pathExtensions[formatID] objectAtIndex:i] 
						 options:NSCaseInsensitiveSearch] == NSOrderedSame) {
			return YES;
		}
    }
	return NO;
}

- (BOOL)catalogEntryAllowed:(NoteCatalogEntry*)catEntry {
    NSString *filename = (__bridge NSString*)catEntry->filename;
	
	if (![filename length])
		return NO;
	
	//ignore hidden files and our own database-related files (e.g. if by chance they are given a TEXT file type)
	if ([filename characterAtIndex:0] == '.') {
		return NO;
	}
	if ([filename isEqualToString:NotesDatabaseFileName] || [filename isEqualToString:PreUpgradeDatabaseFileName]) {
		return NO;
	}
	if ([filename isEqualToString:@"Interim Note-Changes"] || [filename isEqualToString:UnverifiedJournalFileName]) {
		return NO;
	}
	
	if ([self pathExtensionAllowed:[filename pathExtension] forFormat:notesStorageFormat])
		return YES;
    
	NSUInteger i;
    for (i=0; i<[typeStrings[notesStorageFormat] count]; i++) {
		if (catEntry->fileType == allowedTypes[i]) {
			return YES;
		}
    }
    
    return NO;
    
}

- (id)delegate {
	return delegate;
}

- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}


@end
