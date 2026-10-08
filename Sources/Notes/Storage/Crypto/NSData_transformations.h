#import <Foundation/Foundation.h>

@interface NSData (NVUtilities)

- (NSMutableData *) compressedData;
- (NSMutableData *) compressedDataAtLevel:(int)level;
- (NSMutableData *) uncompressedData;
- (BOOL) isCompressedFormat;

+ (NSMutableData *)randomDataOfLength:(int)len;
- (NSMutableData*)derivedKeyOfLength:(NSUInteger)len salt:(NSData*)salt iterations:(int)count;
- (unsigned long)CRC32;
- (NSData*)SHA1Digest;
- (NSData*)MD5Digest;
- (NSData*)BrokenMD5Digest;

- (NSString*)pathURLFromWebArchive;

- (BOOL)fsRefAsAlias:(NVFileReference*)fsRef;
//may block until the volume mounts or its server times out; can show authentication UI
- (BOOL)fsRefAsAliasMountingVolume:(NVFileReference*)fsRef;
+ (NSData*)aliasDataForFSRef:(NVFileReference*)fsRef;
- (NSMutableString*)newStringUsingBOMReturningEncoding:(NSStringEncoding*)encoding;
+ (NSData*)uncachedDataFromFile:(NSString*)filename;

- (NSString *)encodeBase64;
- (NSString *)encodeBase64WithNewlines:(BOOL)encodeWithNewlines;

@end

@interface NSMutableData (NVCryptoRelated)

- (BOOL)encryptAESDataWithKey:(NSData*)key iv:(NSData*)iv;
- (BOOL)decryptAESDataWithKey:(NSData*)key iv:(NSData*)iv;


@end
