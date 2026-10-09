#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonKeyDerivation.h>

//HMAC-SHA256 over the concatenation of first and second; second may be nil
NSData *NVHMACSHA256(NSData *key, NSData *first, NSData *second);
BOOL NVTimingSafeEqualData(NSData *a, NSData *b);

@interface NSData (NVUtilities)

- (NSMutableData *) compressedData;
- (NSMutableData *) compressedDataAtLevel:(int)level;
- (NSMutableData *) uncompressedData;
- (BOOL) isCompressedFormat;

+ (NSMutableData *)randomDataOfLength:(int)len;
- (NSMutableData*)derivedKeyOfLength:(NSUInteger)len salt:(NSData*)salt iterations:(int)count;
- (NSMutableData*)derivedKeyOfLength:(NSUInteger)len salt:(NSData*)salt iterations:(int)count PRF:(CCPseudoRandomAlgorithm)prf;
- (NSMutableData*)subkeyForPurpose:(const char*)purpose salt:(NSData*)salt;
- (unsigned long)CRC32;
- (NSData*)SHA1Digest;
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
