/*
 *  FSExchangeObjectsCompat.c
 *  based on MoreFilesX
 */

#include "FSExchangeObjectsCompat.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/mount.h>

u_int32_t volumeCapabilities(const char *path)
{
    struct attrlist alist;
    bzero(&alist, sizeof(alist));
    alist.bitmapcount = ATTR_BIT_MAP_COUNT;
    alist.volattr = ATTR_VOL_INFO|ATTR_VOL_CAPABILITIES; // XXX: VOL_INFO must always be set

    struct {
        u_int32_t v_size;
       /* Fixed storage */
       vol_capabilities_attr_t v_caps;
    } vinfo;
    bzero(&vinfo, sizeof(vinfo));
    if (0 == getattrlist(path, &alist, &vinfo, sizeof(vinfo), 0)
        && 0 != (alist.volattr & ATTR_VOL_CAPABILITIES)) {
        return (vinfo.v_caps.capabilities[VOL_CAPABILITIES_INTERFACES]);
    }
    
    return (0);
}

OSErr FSExchangeObjectsEmulate(const NVFileReference *source, const NVFileReference *destination, NVFileReference *newSource, NVFileReference *newDestination) {
    return (OSErr)NVExchangeFilesByRenaming(source, destination, newSource, newDestination);
}
