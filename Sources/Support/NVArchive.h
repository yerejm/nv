#ifndef NV_ARCHIVE_H
#define NV_ARCHIVE_H

#import <Foundation/Foundation.h>

//lets these inline helpers compile in both manual and automatic reference counting sources during the ARC migration
#ifndef NV_AUTORELEASE
#if __has_feature(objc_arc)
#define NV_AUTORELEASE(object) (object)
#else
#define NV_AUTORELEASE(object) [(object) autorelease]
#endif
#endif

static inline NSData *NVArchiveObject(id object) {
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:object requiringSecureCoding:YES error:&error];
    if (!data) NSLog(@"Unable to archive %@: %@", [object class], error);
    return data;
}

static inline NSKeyedUnarchiver *NVUnarchiverForData(NSData *data) {
    NSError *error = nil;
    NSKeyedUnarchiver *coder = NV_AUTORELEASE([[NSKeyedUnarchiver alloc] initForReadingFromData:data error:&error]);
    if (!coder) [NSException raise:NSInvalidUnarchiveOperationException format:@"%@", error];
    [coder setRequiresSecureCoding:YES];
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
    NSUnarchiver *coder = NV_AUTORELEASE([[NSUnarchiver alloc] initForReadingWithData:data]);
    [coder decodeClassName:@"Document" asClassName:@"StickiesDocument"];
    return [coder decodeObject];
}
#pragma clang diagnostic pop

static inline NSSet *NVPropertyListClasses(void) {
    static NSSet *classes = nil;
    if (!classes) classes = [[NSSet alloc] initWithObjects:[NSDictionary class], [NSArray class], [NSString class],
                             [NSNumber class], [NSDate class], [NSData class], nil];
    return classes;
}

//nested values may be any of the allowed classes, but the value itself must be a rootClass
static inline id NVDecodeObjectOfClasses(NSCoder *decoder, NSSet *classes, Class rootClass, NSString *key) {
    id object = [decoder decodeObjectOfClasses:classes forKey:key];
    if (object && ![object isKindOfClass:rootClass]) {
        NSString *reason = [NSString stringWithFormat:@"value for key '%@' is not a %@", key, rootClass];
        [decoder failWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError
                                               userInfo:@{NSDebugDescriptionErrorKey: reason}]];
        return nil;
    }
    return object;
}

//unlike -decodeArrayOfObjectsOfClass:forKey:, this permits elements that themselves hold nested collections
static inline NSArray *NVDecodeArrayOfObjectsOfClass(NSCoder *decoder, Class elementClass, NSString *key) {
    NSArray *array = NVDecodeObjectOfClasses(decoder, [NSSet setWithObjects:[NSArray class], elementClass, nil], [NSArray class], key);
    for (id element in array) {
        if (![element isKindOfClass:elementClass]) {
            NSString *reason = [NSString stringWithFormat:@"array for key '%@' holds a %@ instead of a %@", key, [element class], elementClass];
            [decoder failWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSCoderReadCorruptError
                                                   userInfo:@{NSDebugDescriptionErrorKey: reason}]];
            return nil;
        }
    }
    return array;
}

static inline id NVUnarchiveObject(NSData *data, Class rootClass) {
    if (!data) return nil;
    NSKeyedUnarchiver *coder = NVUnarchiverForData(data);
    id object = [coder decodeObjectOfClass:rootClass forKey:NSKeyedArchiveRootObjectKey];
    [coder finishDecoding];
    return object;
}

static inline id NVUnarchivePreference(NSData *data, Class expectedClass) {
    return data ? [NSKeyedUnarchiver unarchivedObjectOfClass:expectedClass fromData:data error:NULL] : nil;
}

#endif
