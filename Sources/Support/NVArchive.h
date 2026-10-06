#ifndef NV_ARCHIVE_H
#define NV_ARCHIVE_H

#import <Foundation/Foundation.h>

static inline NSData *NVArchiveObject(id object) {
    return [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:NO error:NULL];
}

static inline NSKeyedUnarchiver *NVUnarchiverForData(NSData *data) {
    NSError *error = nil;
    NSKeyedUnarchiver *coder = [[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error];
    if (!coder) [NSException raise:NSInvalidUnarchiveOperationException format:@"%@", error];
    [coder setRequiresSecureCoding:NO];
    [coder setDecodingFailurePolicy:NSDecodingFailurePolicyRaiseException];
    return coder;
}

// Legacy positional archives and Carbon aliases require their original format readers.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static inline CFDataRef NVBookmarkFromLegacyAlias(CFDataRef data) {
    return CFURLCreateBookmarkDataFromAliasRecord(NULL, data);
}

static inline id NVUnarchiveLegacyObject(NSData *data) {
    return [NSUnarchiver unarchiveObjectWithData:data];
}

static inline id NVUnarchiveLegacyStickies(NSData *data) {
    NSUnarchiver *coder = [[NSUnarchiver alloc] initForReadingWithData:data];
    [coder decodeClassName:@"Document" asClassName:@"StickiesDocument"];
    id object = [[coder decodeObject] retain];
    [coder release];
    return [object autorelease];
}
#pragma clang diagnostic pop

static inline id NVUnarchiveObject(NSData *data) {
    if (!data) return nil;
    NSKeyedUnarchiver *coder = NVUnarchiverForData(data);
    id object = nil;
    @try {
        object = [coder decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        [coder finishDecoding];
        [[object retain] autorelease];
    } @finally {
        [coder release];
    }
    return object;
}

static inline id NVUnarchivePreference(NSData *data) {
    @try { return NVUnarchiveObject(data); }
    @catch (NSException *exception) { return NVUnarchiveLegacyObject(data); }
}

#endif
