#ifndef NV_FILE_REFERENCE_H
#define NV_FILE_REFERENCE_H

#include <Carbon/Carbon.h>
#include <sys/mount.h>
#include <limits.h>

typedef struct {
    fsid_t volume;
    uint64_t inode;
    char path[PATH_MAX];
} NVFileReference;

typedef struct NVDirectoryIterator *NVDirectoryIterator;

OSStatus NVStatusFromErrno(int error);
OSStatus NVPathMakeReference(const UInt8 *path, NVFileReference *ref, Boolean *isDirectory);
OSStatus NVReferenceMakePath(const NVFileReference *ref, UInt8 *path, size_t size);
Boolean NVURLGetFileReference(CFURLRef url, NVFileReference *ref);
OSStatus NVCompareReferences(const NVFileReference *a, const NVFileReference *b);
OSStatus NVMakeReferenceUnicode(const NVFileReference *parent, CFIndex length, const UniChar *name, TextEncoding encoding, NVFileReference *ref);
OSStatus NVCreateFileUnicode(const NVFileReference *parent, CFIndex length, const UniChar *name, FSCatalogInfoBitmap fields, const FSCatalogInfo *info, NVFileReference *ref, FSSpec *spec);
OSStatus NVCreateDirectoryUnicode(const NVFileReference *parent, CFIndex length, const UniChar *name, FSCatalogInfoBitmap fields, const FSCatalogInfo *info, NVFileReference *ref, FSSpec *spec, UInt32 *directoryID);
OSStatus NVGetCatalogInfo(const NVFileReference *ref, FSCatalogInfoBitmap fields, FSCatalogInfo *info, HFSUniStr255 *name, FSSpec *spec, NVFileReference *parent);
OSStatus NVSetCatalogInfo(const NVFileReference *ref, FSCatalogInfoBitmap fields, const FSCatalogInfo *info);
OSStatus NVRenameUnicode(const NVFileReference *ref, CFIndex length, const UniChar *name, TextEncoding encoding, NVFileReference *result);
OSStatus NVMoveObject(const NVFileReference *ref, const NVFileReference *parent, NVFileReference *result);
OSStatus NVDeleteObject(const NVFileReference *ref);
OSStatus NVOpenIterator(const NVFileReference *ref, FSIteratorFlags flags, NVDirectoryIterator *iterator);
OSStatus NVGetCatalogInfoBulk(NVDirectoryIterator iterator, ItemCount maximum, ItemCount *count, Boolean *changed, FSCatalogInfoBitmap fields, FSCatalogInfo *info, NVFileReference *refs, FSSpec *specs, HFSUniStr255 *names);
OSStatus NVCloseIterator(NVDirectoryIterator iterator);
OSStatus NVReadFile(const NVFileReference *ref, size_t chunkSize, UInt64 *size, void **buffer, UInt16 options);
OSStatus NVWriteFile(const NVFileReference *ref, size_t chunkSize, UInt64 size, const void *buffer, UInt16 options, Boolean truncate);
OSStatus NVExchangeFiles(const NVFileReference *source, const NVFileReference *destination, NVFileReference *newSource, NVFileReference *newDestination);

OSStatus NVExchangeFilesByRenaming(const NVFileReference *source, const NVFileReference *destination, NVFileReference *newSource, NVFileReference *newDestination);

#endif
