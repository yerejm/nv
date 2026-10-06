#include "NVFileReference.h"
#include <sys/fsgetpath.h>
#include <sys/stat.h>
#include <sys/attr.h>
#include <sys/xattr.h>
#include <sys/stdio.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
#include <copyfile.h>

OSStatus NVStatusFromErrno(int error) {
    switch (error) {
        case 0: return noErr;
        case ENOENT: return fnfErr;
        case EEXIST: return dupFNErr;
        case EACCES: case EPERM: return permErr;
        case EXDEV: return diffVolErr;
        case ENOSPC: return dskFulErr;
        case ENAMETOOLONG: return errFSNameTooLong;
        case EINVAL: return paramErr;
        default: return ioErr;
    }
}

OSStatus NVPathMakeReference(const UInt8 *path, NVFileReference *ref, Boolean *isDirectory) {
    if (!path || !ref) return paramErr;
    struct stat info;
    struct statfs volume;
    char resolved[PATH_MAX];
    if (!realpath((const char *)path, resolved) || stat(resolved, &info) || statfs(resolved, &volume))
        return NVStatusFromErrno(errno);
    memset(ref, 0, sizeof(*ref));
    ref->volume = volume.f_fsid;
    ref->inode = info.st_ino;
    strlcpy(ref->path, resolved, sizeof(ref->path));
    if (isDirectory) *isDirectory = S_ISDIR(info.st_mode);
    return noErr;
}

OSStatus NVReferenceMakePath(const NVFileReference *ref, UInt8 *path, size_t size) {
    if (!ref || !path || !size || !ref->inode) return paramErr;
    fsid_t volume = ref->volume;
    if (fsgetpath((char *)path, size, &volume, ref->inode) >= 0) return noErr;
    struct stat info;
    struct statfs currentVolume;
    if (stat(ref->path, &info) || statfs(ref->path, &currentVolume)) return NVStatusFromErrno(errno);
    if (info.st_ino != ref->inode || memcmp(&currentVolume.f_fsid, &ref->volume, sizeof(fsid_t))) return fnfErr;
    if (strlcpy((char *)path, ref->path, size) >= size) return errFSNameTooLong;
    return noErr;
}

Boolean NVURLGetFileReference(CFURLRef url, NVFileReference *ref) {
    UInt8 path[PATH_MAX];
    return url && CFURLGetFileSystemRepresentation(url, true, path, sizeof(path)) && NVPathMakeReference(path, ref, NULL) == noErr;
}

OSStatus NVCompareReferences(const NVFileReference *a, const NVFileReference *b) {
    return a && b && a->inode == b->inode && !memcmp(&a->volume, &b->volume, sizeof(fsid_t)) ? noErr : fnfErr;
}

static OSStatus ChildPath(const NVFileReference *parent, CFIndex length, const UniChar *name, char path[PATH_MAX]) {
    OSStatus error = NVReferenceMakePath(parent, (UInt8 *)path, PATH_MAX);
    if (error) return error;
    if (length < 1 || length > 255 || !name) return errFSNameTooLong;
    CFMutableStringRef string = CFStringCreateMutable(NULL, 0);
    CFStringAppendCharacters(string, name, length);
    CFStringFindAndReplace(string, CFSTR("/"), CFSTR(":"), CFRangeMake(0, length), 0);
    char component[PATH_MAX];
    Boolean converted = CFStringGetFileSystemRepresentation(string, component, sizeof(component));
    CFRelease(string);
    if (!converted || !strcmp(component, ".") || !strcmp(component, "..")) return paramErr;
    if (strlcat(path, "/", PATH_MAX) >= PATH_MAX || strlcat(path, component, PATH_MAX) >= PATH_MAX) return errFSNameTooLong;
    return noErr;
}

OSStatus NVMakeReferenceUnicode(const NVFileReference *parent, CFIndex length, const UniChar *name, TextEncoding encoding, NVFileReference *ref) {
    char path[PATH_MAX];
    OSStatus error = ChildPath(parent, length, name, path);
    return error ? error : NVPathMakeReference((UInt8 *)path, ref, NULL);
}

OSStatus NVCreateFileUnicode(const NVFileReference *parent, CFIndex length, const UniChar *name, FSCatalogInfoBitmap fields, const FSCatalogInfo *info, NVFileReference *ref, FSSpec *spec) {
    char path[PATH_MAX];
    OSStatus error = ChildPath(parent, length, name, path);
    if (error) return error;
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) return NVStatusFromErrno(errno);
    if (close(descriptor)) return NVStatusFromErrno(errno);
    error = NVPathMakeReference((UInt8 *)path, ref, NULL);
    return !error && info ? NVSetCatalogInfo(ref, fields, info) : error;
}

OSStatus NVCreateDirectoryUnicode(const NVFileReference *parent, CFIndex length, const UniChar *name, FSCatalogInfoBitmap fields, const FSCatalogInfo *info, NVFileReference *ref, FSSpec *spec, UInt32 *directoryID) {
    char path[PATH_MAX];
    OSStatus error = ChildPath(parent, length, name, path);
    if (error) return error;
    if (mkdir(path, 0700)) return NVStatusFromErrno(errno);
    error = NVPathMakeReference((UInt8 *)path, ref, NULL);
    if (!error && directoryID) *directoryID = (UInt32)ref->inode;
    return !error && info ? NVSetCatalogInfo(ref, fields, info) : error;
}

static UTCDateTime CatalogDate(struct timespec time) {
    UTCDateTime date = {0};
    UCConvertCFAbsoluteTimeToUTCDateTime((CFAbsoluteTime)time.tv_sec - kCFAbsoluteTimeIntervalSince1970 + (double)time.tv_nsec / 1e9, &date);
    return date;
}

OSStatus NVGetCatalogInfo(const NVFileReference *ref, FSCatalogInfoBitmap fields, FSCatalogInfo *info, HFSUniStr255 *name, FSSpec *spec, NVFileReference *parent) {
    char path[PATH_MAX];
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path));
    if (error) return error;
    struct stat attributes;
    if (stat(path, &attributes)) return NVStatusFromErrno(errno);
    if (info) {
        memset(info, 0, sizeof(*info));
        info->nodeID = (UInt32)attributes.st_ino;
        info->nodeFlags = S_ISDIR(attributes.st_mode) ? kFSNodeIsDirectoryMask : 0;
        info->dataLogicalSize = (UInt64)attributes.st_size;
        info->dataPhysicalSize = (UInt64)attributes.st_blocks * 512;
        info->createDate = CatalogDate(attributes.st_birthtimespec);
        info->contentModDate = CatalogDate(attributes.st_mtimespec);
        info->attributeModDate = CatalogDate(attributes.st_ctimespec);
        info->accessDate = CatalogDate(attributes.st_atimespec);
        if (fields & kFSCatInfoFinderInfo) getxattr(path, "com.apple.FinderInfo", info->finderInfo, sizeof(info->finderInfo), 0, 0);
    }
    char *component = strrchr(path, '/');
    if (name) {
        const char *base = component && component[1] ? component + 1 : path;
        CFMutableStringRef string = CFStringCreateMutable(NULL, 0);
        CFStringRef utf8 = CFStringCreateWithFileSystemRepresentation(NULL, base);
        if (!utf8) { CFRelease(string); return paramErr; }
        CFStringAppend(string, utf8);
        CFRelease(utf8);
        CFStringNormalize(string, kCFStringNormalizationFormC);
        CFStringFindAndReplace(string, CFSTR(":"), CFSTR("/"), CFRangeMake(0, CFStringGetLength(string)), 0);
        name->length = (UInt16)MIN(CFStringGetLength(string), 255);
        CFStringGetCharacters(string, CFRangeMake(0, name->length), name->unicode);
        CFRelease(string);
    }
    if (parent) {
        if (component == path) path[1] = '\0'; else if (component) *component = '\0';
        error = NVPathMakeReference((UInt8 *)path, parent, NULL);
    }
    return error;
}

OSStatus NVSetCatalogInfo(const NVFileReference *ref, FSCatalogInfoBitmap fields, const FSCatalogInfo *info) {
    if (!info) return paramErr;
    char path[PATH_MAX];
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path));
    if (error) return error;
    struct attrlist attributes = { .bitmapcount = ATTR_BIT_MAP_COUNT };
    struct timespec times[2];
    size_t count = 0;
    if (fields & kFSCatInfoCreateDate) {
        CFAbsoluteTime time;
        UCConvertUTCDateTimeToCFAbsoluteTime(&info->createDate, &time);
        double unixTime = time + kCFAbsoluteTimeIntervalSince1970;
        times[count++] = (struct timespec){ (time_t)unixTime, (long)((unixTime - floor(unixTime)) * 1e9) };
        attributes.commonattr |= ATTR_CMN_CRTIME;
    }
    if (fields & kFSCatInfoContentMod) {
        CFAbsoluteTime time;
        UCConvertUTCDateTimeToCFAbsoluteTime(&info->contentModDate, &time);
        double unixTime = time + kCFAbsoluteTimeIntervalSince1970;
        times[count++] = (struct timespec){ (time_t)unixTime, (long)((unixTime - floor(unixTime)) * 1e9) };
        attributes.commonattr |= ATTR_CMN_MODTIME;
    }
    if (count && setattrlist(path, &attributes, times, count * sizeof(*times), 0)) return NVStatusFromErrno(errno);
    if ((fields & kFSCatInfoFinderInfo) && setxattr(path, "com.apple.FinderInfo", info->finderInfo, sizeof(info->finderInfo), 0, 0)) return NVStatusFromErrno(errno);
    return noErr;
}

OSStatus NVRenameUnicode(const NVFileReference *ref, CFIndex length, const UniChar *name, TextEncoding encoding, NVFileReference *result) {
    char source[PATH_MAX], destination[PATH_MAX];
    NVFileReference parent;
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)source, sizeof(source));
    if (!error) error = NVGetCatalogInfo(ref, 0, NULL, NULL, NULL, &parent);
    if (!error) error = ChildPath(&parent, length, name, destination);
    if (error) return error;
    if (!strcmp(source, destination)) { if (result) *result = *ref; return noErr; }
    if (renamex_np(source, destination, RENAME_EXCL)) return NVStatusFromErrno(errno);
    return result ? NVPathMakeReference((UInt8 *)destination, result, NULL) : noErr;
}

OSStatus NVMoveObject(const NVFileReference *ref, const NVFileReference *parent, NVFileReference *result) {
    char source[PATH_MAX], destination[PATH_MAX];
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)source, sizeof(source));
    if (!error) error = NVReferenceMakePath(parent, (UInt8 *)destination, sizeof(destination));
    if (error) return error;
    if (strlcat(destination, strrchr(source, '/'), sizeof(destination)) >= sizeof(destination)) return errFSNameTooLong;
    if (renamex_np(source, destination, RENAME_EXCL)) return NVStatusFromErrno(errno);
    return result ? NVPathMakeReference((UInt8 *)destination, result, NULL) : noErr;
}

OSStatus NVDeleteObject(const NVFileReference *ref) {
    char path[PATH_MAX];
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path));
    return error ? error : (unlink(path) ? NVStatusFromErrno(errno) : noErr);
}

struct NVDirectoryIterator { DIR *directory; NVFileReference parent; };

OSStatus NVOpenIterator(const NVFileReference *ref, FSIteratorFlags flags, NVDirectoryIterator *iterator) {
    char path[PATH_MAX];
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path));
    if (error) return error;
    DIR *directory = opendir(path);
    if (!directory) return NVStatusFromErrno(errno);
    *iterator = malloc(sizeof(**iterator));
    if (!*iterator) { closedir(directory); return memFullErr; }
    **iterator = (struct NVDirectoryIterator){directory, *ref};
    return noErr;
}

OSStatus NVGetCatalogInfoBulk(NVDirectoryIterator iterator, ItemCount maximum, ItemCount *count, Boolean *changed, FSCatalogInfoBitmap fields, FSCatalogInfo *info, NVFileReference *refs, FSSpec *specs, HFSUniStr255 *names) {
    *count = 0;
    if (changed) *changed = false;
    while (*count < maximum) {
        errno = 0;
        struct dirent *entry = readdir(iterator->directory);
        if (!entry) return errno ? NVStatusFromErrno(errno) : errFSNoMoreItems;
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        char path[PATH_MAX];
        OSStatus error = NVReferenceMakePath(&iterator->parent, (UInt8 *)path, sizeof(path));
        if (error) return error;
        if (strlcat(path, "/", sizeof(path)) >= sizeof(path) || strlcat(path, entry->d_name, sizeof(path)) >= sizeof(path)) return errFSNameTooLong;
        struct stat attributes;
        if (lstat(path, &attributes) || !S_ISREG(attributes.st_mode)) continue;
        NVFileReference ref;
        error = NVPathMakeReference((UInt8 *)path, &ref, NULL);
        if (error == fnfErr) continue;
        if (!error) error = NVGetCatalogInfo(&ref, fields, info ? info + *count : NULL, names ? names + *count : NULL, NULL, NULL);
        if (error) return error;
        if (refs) refs[*count] = ref;
        ++*count;
    }
    return noErr;
}

OSStatus NVCloseIterator(NVDirectoryIterator iterator) {
    int result = closedir(iterator->directory);
    free(iterator);
    return result ? NVStatusFromErrno(errno) : noErr;
}

static int OpenReference(const NVFileReference *ref, int flags) {
    char path[PATH_MAX];
    if (NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path))) { errno = ENOENT; return -1; }
    int descriptor = open(path, flags | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) return descriptor;
    struct stat info;
    if (fstat(descriptor, &info) || info.st_ino != ref->inode) { close(descriptor); errno = ENOENT; return -1; }
    return descriptor;
}

OSStatus NVReadFile(const NVFileReference *ref, size_t chunkSize, UInt64 *size, void **buffer, UInt16 options) {
    if (!ref || !size || !buffer || !chunkSize) return paramErr;
    *buffer = NULL;
    int descriptor = OpenReference(ref, O_RDONLY);
    if (descriptor < 0) return NVStatusFromErrno(errno);
    struct stat info;
    if (fstat(descriptor, &info)) { OSStatus error = NVStatusFromErrno(errno); close(descriptor); return error; }
    UInt64 requested = *size ? *size : (UInt64)info.st_size;
    if (requested > SIZE_MAX) { close(descriptor); return memFullErr; }
    void *bytes = malloc(requested ? (size_t)requested : 1);
    if (!bytes) { close(descriptor); return memFullErr; }
    if (options & noCacheMask) fcntl(descriptor, F_NOCACHE, 1);
    size_t total = 0;
    OSStatus error = noErr;
    while (total < requested) {
        ssize_t amount = read(descriptor, (char *)bytes + total, MIN(chunkSize, (size_t)requested - total));
        if (amount < 0) { if (errno == EINTR) continue; error = NVStatusFromErrno(errno); break; }
        if (!amount) break;
        total += (size_t)amount;
    }
    if (close(descriptor) && !error) error = NVStatusFromErrno(errno);
    if (error) { free(bytes); return error; }
    *buffer = bytes;
    *size = total;
    return noErr;
}

OSStatus NVWriteFile(const NVFileReference *ref, size_t chunkSize, UInt64 size, const void *buffer, UInt16 options, Boolean truncate) {
    if (!ref || (!buffer && size) || !chunkSize || size > SIZE_MAX) return paramErr;
    int descriptor = OpenReference(ref, O_WRONLY);
    if (descriptor < 0) return NVStatusFromErrno(errno);
    if (options & noCacheMask) fcntl(descriptor, F_NOCACHE, 1);
    size_t total = 0;
    OSStatus error = noErr;
    while (total < size) {
        ssize_t amount = write(descriptor, (const char *)buffer + total, MIN(chunkSize, (size_t)size - total));
        if (amount < 0) { if (errno == EINTR) continue; error = NVStatusFromErrno(errno); break; }
        if (!amount) { error = ioErr; break; }
        total += (size_t)amount;
    }
    if (!error && truncate && ftruncate(descriptor, (off_t)size)) error = NVStatusFromErrno(errno);
    if (!error && fsync(descriptor)) error = NVStatusFromErrno(errno);
    if (close(descriptor) && !error) error = NVStatusFromErrno(errno);
    return error;
}

static OSStatus ExchangeFiles(const NVFileReference *source, const NVFileReference *destination, NVFileReference *newSource, NVFileReference *newDestination, Boolean useSwap) {
    char sourcePath[PATH_MAX], destinationPath[PATH_MAX];
    OSStatus error = NVReferenceMakePath(source, (UInt8 *)sourcePath, sizeof(sourcePath));
    if (!error) error = NVReferenceMakePath(destination, (UInt8 *)destinationPath, sizeof(destinationPath));
    if (error) return error;
    if (copyfile(destinationPath, sourcePath, NULL, COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)) return NVStatusFromErrno(errno);
    int swapped = useSwap ? renamex_np(sourcePath, destinationPath, RENAME_SWAP) : -1;
    if (!useSwap) errno = ENOTSUP;
    if (swapped) {
        if (errno != ENOTSUP && errno != ENOSYS && errno != EINVAL) return NVStatusFromErrno(errno);
        // Keep the original file available until replacement succeeds on filesystems without swap support.
        char backup[PATH_MAX];
        if (snprintf(backup, sizeof(backup), "%s.swap.XXXXXX", sourcePath) >= (int)sizeof(backup)) return errFSNameTooLong;
        int descriptor = mkstemp(backup);
        if (descriptor < 0) return NVStatusFromErrno(errno);
        close(descriptor);
        if (rename(destinationPath, backup)) {
            int failure = errno;
            unlink(backup);
            return NVStatusFromErrno(failure);
        }
        if (rename(sourcePath, destinationPath)) {
            int failure = errno;
            if (rename(backup, destinationPath)) return NVStatusFromErrno(errno);
            return NVStatusFromErrno(failure);
        }
        if (rename(backup, sourcePath)) return NVStatusFromErrno(errno);
    }
    if (newSource) error = NVPathMakeReference((UInt8 *)sourcePath, newSource, NULL);
    if (!error && newDestination) error = NVPathMakeReference((UInt8 *)destinationPath, newDestination, NULL);
    return error;
}

OSStatus NVExchangeFiles(const NVFileReference *source, const NVFileReference *destination, NVFileReference *newSource, NVFileReference *newDestination) {
    return ExchangeFiles(source, destination, newSource, newDestination, true);
}

OSStatus NVExchangeFilesByRenaming(const NVFileReference *source, const NVFileReference *destination, NVFileReference *newSource, NVFileReference *newDestination) {
    return ExchangeFiles(source, destination, newSource, newDestination, false);
}
