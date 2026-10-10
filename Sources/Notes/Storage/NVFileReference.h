#ifndef NV_FILE_REFERENCE_H
#define NV_FILE_REFERENCE_H

#include <CoreFoundation/CoreFoundation.h>
#include <sys/mount.h>
#include <limits.h>
#include <time.h>

//the values are the Carbon File Manager codes that CarbonErrorStrings.plist is keyed by
enum {
    NVDiskFullErr = -34,
    NVIOErr = -36,
    NVEndOfFileErr = -39,
    NVFileNotFoundErr = -43,
    NVDuplicateFilenameErr = -48,
    NVParameterErr = -50,
    NVPermissionErr = -54,
    NVMemoryFullErr = -108,
    NVDifferentVolumeErr = -1303,
    NVNameTooLongErr = -1410,
    NVNoMoreItemsErr = -1417
};

typedef struct {
    fsid_t volume;
    uint64_t inode;
    char path[PATH_MAX];
} NVFileReference;

typedef struct {
    uint64_t nodeID;
    uint64_t logicalSize;
    Boolean isDirectory;
    OSType fileType;
    struct timespec creationDate;
    struct timespec contentModificationDate;
    struct timespec attributeModificationDate;
} NVFileInfo;

typedef struct NVDirectoryIterator *NVDirectoryIterator;

OSStatus NVStatusFromErrno(int error);
OSStatus NVPathMakeReference(const UInt8 *path, NVFileReference *ref, Boolean *isDirectory);
OSStatus NVReferenceMakePath(const NVFileReference *ref, UInt8 *path, size_t size);
Boolean NVURLGetFileReference(CFURLRef url, NVFileReference *ref);
OSStatus NVCompareReferences(const NVFileReference *a, const NVFileReference *b);
OSStatus NVMakeReference(const NVFileReference *parent, CFStringRef name, NVFileReference *ref);
OSStatus NVCreateFile(const NVFileReference *parent, CFStringRef name, NVFileReference *ref);
OSStatus NVCreateDirectory(const NVFileReference *parent, CFStringRef name, NVFileReference *ref);
OSStatus NVCreateFileIfNotPresent(const NVFileReference *parent, CFStringRef name, NVFileReference *ref, Boolean *created);
OSStatus NVGetFileInfo(const NVFileReference *ref, NVFileInfo *info, CFStringRef *name, NVFileReference *parent);
//either date may be NULL to leave it unchanged
OSStatus NVSetFileDates(const NVFileReference *ref, const struct timespec *creationDate, const struct timespec *modificationDate);
OSStatus NVRename(const NVFileReference *ref, CFStringRef name, NVFileReference *result);
OSStatus NVMoveObject(const NVFileReference *ref, const NVFileReference *parent, NVFileReference *result);
OSStatus NVDeleteObject(const NVFileReference *ref);
OSStatus NVOpenIterator(const NVFileReference *ref, NVDirectoryIterator *iterator);
//returns regular files only; each name is created and must be released by the caller
OSStatus NVIterateFiles(NVDirectoryIterator iterator, size_t maximum, size_t *count, NVFileInfo *info, NVFileReference *refs, CFStringRef *names);
OSStatus NVCloseIterator(NVDirectoryIterator iterator);
OSStatus NVReadFile(const NVFileReference *ref, size_t chunkSize, UInt64 *size, void **buffer, Boolean uncached);
OSStatus NVWriteFile(const NVFileReference *ref, size_t chunkSize, UInt64 size, const void *buffer, Boolean uncached, Boolean truncate);
OSStatus NVExchangeFiles(const NVFileReference *source, const NVFileReference *destination, NVFileReference *newSource, NVFileReference *newDestination);

OSStatus NVExchangeFilesByRenaming(const NVFileReference *source, const NVFileReference *destination, NVFileReference *newSource, NVFileReference *newDestination);

#endif
