/*
 * Compresses/decompresses data using zlib (see RFC 1950 and /usr/include/zlib.h)
 *
 * Be sure to add /usr/lib/libz.dylib to the linked frameworks, or add "-lz" to
 * 'Other Linker Flags' in the 'Linker Settings' section of the target's
 * 'Build Settings'
 *
 */

/* NSData_transformations.m */

#import "NSData_transformations.h"
#include "sha1.h"
#include "broken_md5.h"

#include <zlib.h>
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <CommonCrypto/CommonHMAC.h>
#include <CommonCrypto/CommonRandom.h>

#import <WebKit/WebKit.h>

NSData *NVHMACSHA256(NSData *key, NSData *first, NSData *second) {
	CCHmacContext context;
	NSMutableData *tag = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
	CCHmacInit(&context, kCCHmacAlgSHA256, [key bytes], [key length]);
	CCHmacUpdate(&context, [first bytes], [first length]);
	if (second) CCHmacUpdate(&context, [second bytes], [second length]);
	CCHmacFinal(&context, [tag mutableBytes]);
	return tag;
}

BOOL NVTimingSafeEqualData(NSData *a, NSData *b) {
	return a && b && [a length] == [b length] && !timingsafe_bcmp([a bytes], [b bytes], [a length]);
}

@implementation NSData (NVUtilities)

/*
 * Compress the data, default level of compression
 */
- (NSMutableData *)compressedData {
	return [self compressedDataAtLevel:Z_DEFAULT_COMPRESSION];
}


/*
 * Compress the data at the given compression level; stores the original data
 * size at the end of the compressed data
 */
- (NSMutableData *)compressedDataAtLevel:(int)level {
    if ([self length] > UINT32_MAX) return nil;
	
	NSMutableData *newData;
	unsigned long bufferLength;
	int zlibError;
	
	/*
	 * zlib says to make sure the destination has 0.1% more + 12 bytes; last
	 * additional bytes to store the original size (needed for uncompress)
	 */
	bufferLength = ceil( (float) [self length] * 1.001 ) + 12 + sizeof( unsigned );
	newData = [NSMutableData dataWithLength:bufferLength];
	if( newData != nil ) {
		zlibError = compress2([newData mutableBytes], &bufferLength,
							   [self bytes], [self length], level);
		if (zlibError == Z_OK) {
			// Add original size to the end of the buffer, written big-endian
			*( (unsigned *) ([newData mutableBytes] + bufferLength) ) =
            NSSwapHostIntToBig((unsigned int)[self length]);
			[newData setLength:bufferLength + sizeof(unsigned)];
		} else {
			NSLog(@"error compressing: %s", zError(zlibError));
			newData = nil;
		}
	} else
		NSLog(@"error compressing: couldn't allocate memory");
	
	return newData;
}


/*
 * Decompress data
 */
- (NSMutableData *) uncompressedData {
	
	NSMutableData *newData;
	unsigned originalSize;
	unsigned long outSize;
	int zlibError;
	
	newData = nil;
	if ( [self isCompressedFormat] ) {
		originalSize = NSSwapBigIntToHost(*((unsigned *) ([self bytes] + [self length] - sizeof(unsigned))));
		
		//catch the NSInvalidArgumentException that's thrown if originalSize is too large
		NS_DURING
			newData = [ NSMutableData dataWithLength:originalSize ];
		NS_HANDLER
			if ([[localException name] isEqualToString:NSInvalidArgumentException] ) {
				NSLog(@"error decompressing--bad size: %@", [localException reason]);
				NS_VALUERETURN( nil, NSMutableData * );
			} else
				[localException raise];   // This should NEVER happen...
		NS_ENDHANDLER
		
		if( newData != nil ) {
			outSize = originalSize;
			zlibError = uncompress([newData mutableBytes], &outSize, [self bytes], [self length] - sizeof(unsigned));
			if( zlibError != Z_OK ) {
				NSLog(@"decompression failed: %s", zError(zlibError));
				newData = nil;
			} else if (originalSize != outSize)
				NSLog(@"error decompressing: extracted size %lu does not match original of %u", outSize, originalSize);
		} else
			NSLog(@"error allocating memory while decompressing");
	} else
		NSLog(@"error decompressing: data does not seem to be compressed with zlib");
	
	return newData;
}


/*
 * Quick check of the data to avoid obviously-not-compressed data (see RFC)
 */
- (BOOL)isCompressedFormat {
	const unsigned char *bytes;
	
	bytes = [self bytes];
	/*
	 * The checks are:
	 *    ( *bytes & 0x0F ) == 8           : method is deflate (this is called CM compression method, in the RFC)
	 *    ( *bytes & 0x80 ) == 0           : info must be at most seven, this makes sure the MSB is not set, otherwise it
	 *                                       is at least 8 (this is called CINFO, compression info, in the RFC)
	 *    *( (short *) bytes ) ) % 31 == 0 : the two first bytes as a whole (big endian format) must be a multiple of 31
	 *                                       (this is discussed in the FCHECK in FLG, flags, section)
	 */
	if( ( *bytes & 0x0F ) == 8 && ( *bytes & 0x80 ) == 0 &&
		NSSwapBigShortToHost( *( (short *) bytes ) ) % 31 == 0 )
		return YES;
	
	return NO;
}

+ (NSMutableData *)randomDataOfLength:(int)len {
	NSMutableData *randomData = [NSMutableData dataWithLength:len];
	if (CCRandomGenerateBytes([randomData mutableBytes], len) != kCCSuccess) {
		NSLog(@"error generating random data");
		return nil;
	}
	return randomData;
}

- (NSMutableData*)derivedKeyOfLength:(NSUInteger)len salt:(NSData*)salt iterations:(int)count {
	return [self derivedKeyOfLength:len salt:salt iterations:count PRF:kCCPRFHmacAlgSHA1];
}

- (NSMutableData*)derivedKeyOfLength:(NSUInteger)len salt:(NSData*)salt iterations:(int)count PRF:(CCPseudoRandomAlgorithm)prf {
	NSMutableData *derivedKey = [NSMutableData dataWithLength:len];
	if (CCKeyDerivationPBKDF(kCCPBKDF2, [self bytes], [self length], [salt bytes], [salt length], prf,
							 (unsigned)count, [derivedKey mutableBytes], len) != kCCSuccess)
		return nil;
	return derivedKey;
}

//separates the keys that one secret yields for different uses, such as encryption and authentication
- (NSMutableData*)subkeyForPurpose:(const char*)purpose salt:(NSData*)salt {
	NSMutableData *labelledSalt = [NSMutableData dataWithBytes:purpose length:strlen(purpose)];
	if (salt) [labelledSalt appendData:salt];
	return [self derivedKeyOfLength:kCCKeySizeAES256 salt:labelledSalt iterations:1 PRF:kCCPRFHmacAlgSHA256];
}

- (unsigned long)CRC32 {
	uLong crc = crc32(0L, Z_NULL, 0);
    const Bytef *bytes = [self bytes];
    NSUInteger remaining = [self length];
    while (remaining) {
        uInt length = (uInt)MIN(remaining, (NSUInteger)UINT_MAX);
        crc = crc32(crc, bytes, length);
        bytes += length;
        remaining -= length;
    }
    return crc;
}

- (NSData*)SHA1Digest {
	sha1_ctx_nv keyhash;
	
	NSMutableData *mutableData = [NSMutableData dataWithLength:20];
	
	sha1_init_ctx(&keyhash);
	sha1_process_bytes([self bytes], [self length], &keyhash);
	sha1_finish_ctx(&keyhash, [mutableData mutableBytes]);
	
	return mutableData;
}

- (NSData*)BrokenMD5Digest {
	BrokenMD5_CTX context;
	NSMutableData *digest = [NSMutableData dataWithLength:16];
    
    BrokenMD5Init(&context);
    const unsigned char *bytes = [self bytes];
    NSUInteger remaining = [self length];
    while (remaining) {
        unsigned length = (unsigned)MIN(remaining, (NSUInteger)UINT_MAX);
        BrokenMD5Update(&context, bytes, length);
        bytes += length;
        remaining -= length;
    }
    BrokenMD5Final([digest mutableBytes], &context);
	
	return digest;
}

- (NSString *)pathURLFromWebArchive {
    id archive = [NSPropertyListSerialization propertyListWithData:self options:NSPropertyListImmutable format:NULL error:NULL];
    if (![archive isKindOfClass:[NSDictionary class]]) return nil;
    id resource = [archive objectForKey:@"WebMainResource"];
    if (![resource isKindOfClass:[NSDictionary class]]) return nil;
    id string = [resource objectForKey:@"WebResourceURL"];
    if (![string isKindOfClass:[NSString class]]) return nil;
    NSURL *url = [NSURL URLWithString:string];
    if ([[url scheme] isEqualToString:@"applewebdata"] || [[url scheme] isEqualToString:@"x-msg"]) return nil;
    return [url absoluteString];
}

static NSURL *NVResolveBookmark(NSData *data, NSURLBookmarkResolutionOptions options) {
    NSURL *url = [NSURL URLByResolvingBookmarkData:data options:options relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];
    if (!url) {
        CFDataRef bookmark = NVBookmarkFromLegacyAlias((__bridge CFDataRef)data);
        if (bookmark) {
            url = [NSURL URLByResolvingBookmarkData:(__bridge NSData *)bookmark options:options relativeToURL:nil bookmarkDataIsStale:NULL error:NULL];
            CFRelease(bookmark);
        }
    }
    return url;
}

- (BOOL)fsRefAsAlias:(NVFileReference *)ref {
    return NVURLGetFileReference((__bridge CFURLRef)NVResolveBookmark(self, NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting), ref);
}

- (BOOL)fsRefAsAliasMountingVolume:(NVFileReference *)ref {
    return NVURLGetFileReference((__bridge CFURLRef)NVResolveBookmark(self, 0), ref);
}

+ (NSData*)uncachedDataFromFile:(NSString*)filename {
			
	return [NSData dataWithContentsOfFile:filename options:NSDataReadingUncached error:NULL];
}

+ (NSData *)aliasDataForFSRef:(NVFileReference *)ref {
    char path[PATH_MAX];
    if (NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path))) return nil;
    NSURL *url = [NSURL fileURLWithFileSystemRepresentation:path isDirectory:NO relativeToURL:nil];
    return [url bookmarkDataWithOptions:NSURLBookmarkCreationSuitableForBookmarkFile includingResourceValuesForKeys:nil relativeToURL:nil error:NULL];
}

- (NSMutableString*)newStringUsingBOMReturningEncoding:(NSStringEncoding*)encoding {
	NSUInteger len = [self length];
	NSMutableString *string = nil;
	
	if (len % 2 != 0 || !len) {
		return nil;
	}
	const unichar byteOrderMark = 0xFEFF;
	const unichar byteOrderMarkSwapped = 0xFFFE;
	
	BOOL foundBOM = NO;
	BOOL swapped = NO;
	unsigned char *b = (unsigned char*)[self bytes];
	unichar *uptr = (unichar*)b;
	
	if (*uptr == byteOrderMark) {
		b = (unsigned char*)++uptr;
		len -= sizeof(unichar);
		foundBOM = YES;
	} else if (*uptr == byteOrderMarkSwapped) {
		b = (unsigned char*)++uptr;
		len -= sizeof(unichar);
		swapped = YES;
		foundBOM = YES;
	} else if (len > 2 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
		len -= 3;
		b += 3;
		
		string = [[NSMutableString alloc] initWithBytes:b length:len encoding:NSUTF8StringEncoding];
		if (string)
			*encoding = NSUTF8StringEncoding;
		
		return string;
	}
	
	if (foundBOM) {
		unsigned char *u = (unsigned char*)malloc(len);
		if (swapped) {
			NSUInteger i;
			
			for (i = 0; i < len; i += 2) {
				u[i] = b[i + 1];
				u[i + 1] = b[i];
			}
		} else {
			memcpy(u, b, len);
		}
		
		
		string = CFBridgingRelease(CFStringCreateMutableWithExternalCharactersNoCopy(NULL, (UniChar *)u, (CFIndex)len/2, (CFIndex)len/2, kCFAllocatorDefault));
		if (string)
			*encoding = NSUnicodeStringEncoding;
		return string;
	}
	
	return nil;
}


- (NSString *)encodeBase64 {
    return [self encodeBase64WithNewlines:YES];
}

- (NSString *)encodeBase64WithNewlines:(BOOL)encodeWithNewlines {
    NSString *encoded = [self base64EncodedStringWithOptions:0];
    if (!encodeWithNewlines || ![encoded length]) return encoded;
    NSMutableString *wrapped = [NSMutableString string];
    for (NSUInteger location = 0; location < [encoded length]; location += 64) {
        [wrapped appendString:[encoded substringWithRange:NSMakeRange(location, MIN(64, [encoded length] - location))]];
        [wrapped appendString:@"\n"];
    }
    return wrapped;
}


@end

@implementation NSMutableData (NVCryptoRelated)

//extends nsmutabledata if necessary

static BOOL TransformAESData(NSMutableData *data, NSData *key, NSData *iv, CCOperation operation) {
    if ([key length] != kCCKeySizeAES256 || [iv length] != kCCBlockSizeAES128) return NO;
    NSMutableData *output = [NSMutableData dataWithLength:[data length] + kCCBlockSizeAES128];
    size_t written = 0;
    CCOptions options = operation == kCCEncrypt ? kCCOptionPKCS7Padding : 0;
    CCCryptorStatus status = CCCrypt(operation, kCCAlgorithmAES, options,
                                   [key bytes], [key length], [iv bytes],
                                   [data bytes], [data length], [output mutableBytes], [output length], &written);
    if (status != kCCSuccess) return NO;
    if (operation == kCCDecrypt) {
        if (!written || written % kCCBlockSizeAES128) return NO;
        const unsigned char *bytes = [output bytes];
        unsigned char padding = bytes[written - 1];
        if (!padding || padding > kCCBlockSizeAES128) return NO;
        for (NSUInteger index = 0; index < padding; index++) {
            if (bytes[written - 1 - index] != padding) return NO;
        }
        written -= padding;
    }
    [output setLength:written];
    [data setData:output];
    return YES;
}

- (BOOL)encryptAESDataWithKey:(NSData*)key iv:(NSData*)iv {
    return TransformAESData(self, key, iv, kCCEncrypt);
}

- (BOOL)decryptAESDataWithKey:(NSData*)key iv:(NSData*)iv {
    return TransformAESData(self, key, iv, kCCDecrypt);
}

@end
