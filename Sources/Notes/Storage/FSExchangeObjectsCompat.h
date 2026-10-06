/*
 *  FSExchangeObjectsCompat.h
 *  Notation
 *
 */

#include <Carbon/Carbon.h>

OSErr FSExchangeObjectsEmulate(const NVFileReference *sourceRef, const NVFileReference *destRef, NVFileReference *newSourceRef, NVFileReference *newDestRef);
Boolean VolumeOfFSRefSupportsExchangeObjects(const NVFileReference *fsRef);
u_int32_t volumeCapabilities(const char *path);
