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
#include <copyfile.h>

OSStatus NVStatusFromErrno(int error) {
    switch (error) {
        case 0: return noErr;
        case ENOENT: return NVFileNotFoundErr;
        case EEXIST: return NVDuplicateFilenameErr;
        case EACCES: case EPERM: return NVPermissionErr;
        case EXDEV: return NVDifferentVolumeErr;
        case ENOSPC: return NVDiskFullErr;
        case ENAMETOOLONG: return NVNameTooLongErr;
        case EINVAL: return NVParameterErr;
        default: return NVIOErr;
    }
}

OSStatus NVPathMakeReference(const UInt8 *path, NVFileReference *ref, Boolean *isDirectory) {
    if (!path || !ref) return NVParameterErr;
    struct stat info;
    struct statfs volume;
    char resolved[PATH_MAX];
    if (!realpath((const char *)path, resolved) || stat(resolved, &info) || statfs(resolved, &volume))
        return errno ? NVStatusFromErrno(errno) : NVIOErr;
    memset(ref, 0, sizeof(*ref));
    ref->volume = volume.f_fsid;
    ref->inode = info.st_ino;
    strlcpy(ref->path, resolved, sizeof(ref->path));
    if (isDirectory) *isDirectory = S_ISDIR(info.st_mode);
    return noErr;
}

OSStatus NVReferenceMakePath(const NVFileReference *ref, UInt8 *path, size_t size) {
    if (!ref || !path || !size || !ref->inode) return NVParameterErr;
    fsid_t volume = ref->volume;
    if (fsgetpath((char *)path, size, &volume, ref->inode) >= 0) return noErr;
    struct stat info;
    struct statfs currentVolume;
    if (stat(ref->path, &info) || statfs(ref->path, &currentVolume)) return NVStatusFromErrno(errno);
    if (info.st_ino != ref->inode || memcmp(&currentVolume.f_fsid, &ref->volume, sizeof(fsid_t))) return NVFileNotFoundErr;
    if (strlcpy((char *)path, ref->path, size) >= size) return NVNameTooLongErr;
    return noErr;
}

Boolean NVURLGetFileReference(CFURLRef url, NVFileReference *ref) {
    UInt8 path[PATH_MAX];
    return url && CFURLGetFileSystemRepresentation(url, true, path, sizeof(path)) && NVPathMakeReference(path, ref, NULL) == noErr;
}

OSStatus NVCompareReferences(const NVFileReference *a, const NVFileReference *b) {
    return a && b && a->inode == b->inode && !memcmp(&a->volume, &b->volume, sizeof(fsid_t)) ? noErr : NVFileNotFoundErr;
}

static OSStatus ChildPath(const NVFileReference *parent, CFStringRef name, char path[PATH_MAX]) {
    OSStatus error = NVReferenceMakePath(parent, (UInt8 *)path, PATH_MAX);
    if (error) return error;
    CFIndex length = name ? CFStringGetLength(name) : 0;
    if (length < 1 || length > 255) return NVNameTooLongErr;
    CFMutableStringRef string = CFStringCreateMutableCopy(NULL, 0, name);
    CFStringFindAndReplace(string, CFSTR("/"), CFSTR(":"), CFRangeMake(0, length), 0);
    char component[PATH_MAX];
    Boolean converted = CFStringGetFileSystemRepresentation(string, component, sizeof(component));
    CFRelease(string);
    if (!converted || !strcmp(component, ".") || !strcmp(component, "..")) return NVParameterErr;
    if (strlcat(path, "/", PATH_MAX) >= PATH_MAX || strlcat(path, component, PATH_MAX) >= PATH_MAX) return NVNameTooLongErr;
    return noErr;
}

OSStatus NVMakeReference(const NVFileReference *parent, CFStringRef name, NVFileReference *ref) {
    char path[PATH_MAX];
    OSStatus error = ChildPath(parent, name, path);
    return error ? error : NVPathMakeReference((UInt8 *)path, ref, NULL);
}

OSStatus NVCreateFile(const NVFileReference *parent, CFStringRef name, NVFileReference *ref) {
    char path[PATH_MAX];
    OSStatus error = ChildPath(parent, name, path);
    if (error) return error;
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (descriptor < 0) return NVStatusFromErrno(errno);
    if (close(descriptor)) return NVStatusFromErrno(errno);
    return NVPathMakeReference((UInt8 *)path, ref, NULL);
}

OSStatus NVCreateDirectory(const NVFileReference *parent, CFStringRef name, NVFileReference *ref) {
    char path[PATH_MAX];
    OSStatus error = ChildPath(parent, name, path);
    if (error) return error;
    if (mkdir(path, 0700)) return NVStatusFromErrno(errno);
    return NVPathMakeReference((UInt8 *)path, ref, NULL);
}

OSStatus NVCreateFileIfNotPresent(const NVFileReference *parent, CFStringRef name, NVFileReference *ref, Boolean *created) {
    if (created) *created = false;
    OSStatus error = NVMakeReference(parent, name, ref);
    if (error != NVFileNotFoundErr) return error;
    if (created) *created = true;
    return NVCreateFile(parent, name, ref);
}

static OSType FileTypeAtPath(const char *path) {
    //Finder info is stored big-endian, and starts with the file type
    uint8_t finderInfo[32];
    if (getxattr(path, XATTR_FINDERINFO_NAME, finderInfo, sizeof(finderInfo), 0, 0) < 4) return 0;
    return (OSType)finderInfo[0] << 24 | (OSType)finderInfo[1] << 16 | (OSType)finderInfo[2] << 8 | finderInfo[3];
}

OSStatus NVGetFileInfo(const NVFileReference *ref, NVFileInfo *info, CFStringRef *name, NVFileReference *parent) {
    char path[PATH_MAX];
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path));
    if (error) return error;
    struct stat attributes;
    if (stat(path, &attributes)) return NVStatusFromErrno(errno);
    if (info) {
        *info = (NVFileInfo){
            .nodeID = attributes.st_ino,
            .logicalSize = (uint64_t)attributes.st_size,
            .isDirectory = S_ISDIR(attributes.st_mode),
            .fileType = FileTypeAtPath(path),
            .creationDate = attributes.st_birthtimespec,
            .contentModificationDate = attributes.st_mtimespec,
            .attributeModificationDate = attributes.st_ctimespec,
        };
    }
    char *component = strrchr(path, '/');
    if (name) {
        const char *base = component && component[1] ? component + 1 : path;
        CFStringRef decoded = CFStringCreateWithFileSystemRepresentation(NULL, base);
        if (!decoded) return NVParameterErr;
        CFMutableStringRef string = CFStringCreateMutableCopy(NULL, 0, decoded);
        CFRelease(decoded);
        CFStringNormalize(string, kCFStringNormalizationFormC);
        CFStringFindAndReplace(string, CFSTR(":"), CFSTR("/"), CFRangeMake(0, CFStringGetLength(string)), 0);
        *name = string;
    }
    if (parent) {
        if (component == path) path[1] = '\0'; else if (component) *component = '\0';
        error = NVPathMakeReference((UInt8 *)path, parent, NULL);
        if (error && name) { CFRelease(*name); *name = NULL; }
    }
    return error;
}

OSStatus NVSetFileDates(const NVFileReference *ref, const struct timespec *creationDate, const struct timespec *modificationDate) {
    char path[PATH_MAX];
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path));
    if (error) return error;
    struct attrlist attributes = { .bitmapcount = ATTR_BIT_MAP_COUNT };
    struct timespec times[2];
    size_t count = 0;
    if (creationDate) {
        times[count++] = *creationDate;
        attributes.commonattr |= ATTR_CMN_CRTIME;
    }
    if (modificationDate) {
        times[count++] = *modificationDate;
        attributes.commonattr |= ATTR_CMN_MODTIME;
    }
    if (count && setattrlist(path, &attributes, times, count * sizeof(*times), 0)) return NVStatusFromErrno(errno);
    return noErr;
}

OSStatus NVRename(const NVFileReference *ref, CFStringRef name, NVFileReference *result) {
    char source[PATH_MAX], destination[PATH_MAX];
    NVFileReference parent;
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)source, sizeof(source));
    if (!error) error = NVGetFileInfo(ref, NULL, NULL, &parent);
    if (!error) error = ChildPath(&parent, name, destination);
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
    if (strlcat(destination, strrchr(source, '/'), sizeof(destination)) >= sizeof(destination)) return NVNameTooLongErr;
    if (renamex_np(source, destination, RENAME_EXCL)) return NVStatusFromErrno(errno);
    return result ? NVPathMakeReference((UInt8 *)destination, result, NULL) : noErr;
}

OSStatus NVDeleteObject(const NVFileReference *ref) {
    char path[PATH_MAX];
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path));
    return error ? error : (unlink(path) ? NVStatusFromErrno(errno) : noErr);
}

struct NVDirectoryIterator { DIR *directory; NVFileReference parent; };

OSStatus NVOpenIterator(const NVFileReference *ref, NVDirectoryIterator *iterator) {
    char path[PATH_MAX];
    OSStatus error = NVReferenceMakePath(ref, (UInt8 *)path, sizeof(path));
    if (error) return error;
    DIR *directory = opendir(path);
    if (!directory) return NVStatusFromErrno(errno);
    *iterator = malloc(sizeof(**iterator));
    if (!*iterator) { closedir(directory); return NVMemoryFullErr; }
    **iterator = (struct NVDirectoryIterator){directory, *ref};
    return noErr;
}

OSStatus NVIterateFiles(NVDirectoryIterator iterator, size_t maximum, size_t *count, NVFileInfo *info, NVFileReference *refs, CFStringRef *names) {
    *count = 0;
    while (*count < maximum) {
        errno = 0;
        struct dirent *entry = readdir(iterator->directory);
        if (!entry) return errno ? NVStatusFromErrno(errno) : NVNoMoreItemsErr;
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        char path[PATH_MAX];
        OSStatus error = NVReferenceMakePath(&iterator->parent, (UInt8 *)path, sizeof(path));
        if (error) return error;
        if (strlcat(path, "/", sizeof(path)) >= sizeof(path) || strlcat(path, entry->d_name, sizeof(path)) >= sizeof(path)) return NVNameTooLongErr;
        struct stat attributes;
        if (lstat(path, &attributes) || !S_ISREG(attributes.st_mode)) continue;
        NVFileReference ref;
        error = NVPathMakeReference((UInt8 *)path, &ref, NULL);
        if (error == NVFileNotFoundErr) continue;
        if (!error) error = NVGetFileInfo(&ref, info ? info + *count : NULL, names ? names + *count : NULL, NULL);
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

OSStatus NVReadFile(const NVFileReference *ref, size_t chunkSize, UInt64 *size, void **buffer, Boolean uncached) {
    if (!ref || !size || !buffer || !chunkSize) return NVParameterErr;
    *buffer = NULL;
    int descriptor = OpenReference(ref, O_RDONLY);
    if (descriptor < 0) return NVStatusFromErrno(errno);
    struct stat info;
    if (fstat(descriptor, &info)) { OSStatus error = NVStatusFromErrno(errno); close(descriptor); return error; }
    UInt64 requested = *size ? *size : (UInt64)info.st_size;
    if (requested > SIZE_MAX) { close(descriptor); return NVMemoryFullErr; }
    void *bytes = malloc(requested ? (size_t)requested : 1);
    if (!bytes) { close(descriptor); return NVMemoryFullErr; }
    if (uncached) fcntl(descriptor, F_NOCACHE, 1);
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

OSStatus NVWriteFile(const NVFileReference *ref, size_t chunkSize, UInt64 size, const void *buffer, Boolean uncached, Boolean truncate) {
    if (!ref || (!buffer && size) || !chunkSize || size > SIZE_MAX) return NVParameterErr;
    int descriptor = OpenReference(ref, O_WRONLY);
    if (descriptor < 0) return NVStatusFromErrno(errno);
    if (uncached) fcntl(descriptor, F_NOCACHE, 1);
    size_t total = 0;
    OSStatus error = noErr;
    while (total < size) {
        ssize_t amount = write(descriptor, (const char *)buffer + total, MIN(chunkSize, (size_t)size - total));
        if (amount < 0) { if (errno == EINTR) continue; error = NVStatusFromErrno(errno); break; }
        if (!amount) { error = NVIOErr; break; }
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
    struct stat written;
    if (lstat(sourcePath, &written)) return NVStatusFromErrno(errno);
    if (copyfile(destinationPath, sourcePath, NULL, COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)) return NVStatusFromErrno(errno);
    // The replacement inherits the old file's creation date, permissions and attributes, but not its modification dates.
    const struct timespec writtenDates[2] = {written.st_atimespec, written.st_mtimespec};
    if (utimensat(AT_FDCWD, sourcePath, writtenDates, AT_SYMLINK_NOFOLLOW)) return NVStatusFromErrno(errno);
    int swapped = useSwap ? renamex_np(sourcePath, destinationPath, RENAME_SWAP) : -1;
    if (!useSwap) errno = ENOTSUP;
    if (swapped) {
        if (errno != ENOTSUP && errno != ENOSYS && errno != EINVAL) return NVStatusFromErrno(errno);
        // Keep the original file available until replacement succeeds on filesystems without swap support.
        char backup[PATH_MAX];
        if (snprintf(backup, sizeof(backup), "%s.swap.XXXXXX", sourcePath) >= (int)sizeof(backup)) return NVNameTooLongErr;
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
