/*
 *  BufferUtils.h
 *  Notation
 *
 *  Created by Zachary Schneirov on 1/15/06.
 */

/*Copyright (c) 2010, Zachary Schneirov. All rights reserved.
    This file is part of Notational Velocity.

    Notational Velocity is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Notational Velocity is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Notational Velocity.  If not, see <http://www.gnu.org/licenses/>. */


#include <CoreFoundation/CoreFoundation.h>
#include <time.h>

#define ResizeArray(__DirectBuffer, __objCount, __bufObjCount)	_ResizeBuffer((void***)(void *)(__DirectBuffer), (__objCount), (__bufObjCount), sizeof(typeof(**(__DirectBuffer))))

#pragma pack(push, 2)
//the layout of Carbon's UTCDateTime, in which notes archive file dates: seconds since 1904 and 1/65536-second fractions
typedef struct {
	UInt16 highSeconds;
	UInt32 lowSeconds;
	UInt16 fraction;
} NVArchivedDate;

//a PerDiskInfo as notes archive it, in big-endian order
typedef struct {
	UInt32 diskIDIndex;
	UInt32 nodeID;
	NVArchivedDate attrTime;
} NVArchivedPerDiskInfo;
#pragma pack(pop)

typedef struct _PerDiskInfo {
	
	//index in a table of disk UUIDs; should be the disk from which this time was gathered
	//the disk UUIDs table is tracked separately in NotationPrefs; it should only ever be appended-to
	UInt32 diskIDIndex;
	
	//catalog node ID of a file
	UInt32 nodeID;
	
	//the attribute modification time of a file
	struct timespec attrTime;
	
} PerDiskInfo;

//the empty date, which is also the Unix epoch, archives as zero
NVArchivedDate NVArchivedDateFromTimespec(struct timespec date);
struct timespec NVTimespecFromArchivedDate(NVArchivedDate date);
CFAbsoluteTime NVAbsoluteTimeFromTimespec(struct timespec date);
struct timespec NVTimespecFromAbsoluteTime(CFAbsoluteTime time);
Boolean NVFileDateIsEmpty(struct timespec date);
//compares at the resolution in which file dates are archived, so dates read back from an archive still match the disk
int NVCompareFileDates(struct timespec a, struct timespec b);

char *replaceString(char *oldString, const char *newString);
void _ResizeBuffer(void ***buffer, size_t objCount, unsigned int *bufSize, size_t elemSize);
int IsZeros(const void *s1, size_t n);
int ContainsUInteger(const NSUInteger *uintArray, size_t count, NSUInteger auint);
void modp_tolower_copy(char* dest, const char* str, size_t len);
int ContainsHighAscii(const void *s1, size_t n);
unsigned DumbWordCount(const void *s1, size_t len);
NSInteger genericSortContextFirst(int (*context) (void*, void*), void* one, void* two);
NSInteger genericSortContextLast(void* one, void* two, int (*context) (void*, void*));
void QuickSortBuffer(void **buffer, unsigned int objCount, int (*compar)(const void *, const void *));

void RemovePerDiskInfoWithTableIndex(UInt32 diskIndex, PerDiskInfo **perDiskGroups, unsigned int *groupCount);
unsigned int SetPerDiskInfoWithTableIndex(struct timespec *dateTime, UInt32 *nodeID, UInt32 diskIndex, PerDiskInfo **perDiskGroups, unsigned int *groupCount);
void DecodePerDiskInfoGroups(PerDiskInfo **perDiskGroups, unsigned int *groupCount, const void *bytes, size_t length);
//the caller frees the returned buffer of groupCount entries
NVArchivedPerDiskInfo *CreateArchivedPerDiskInfoGroups(const PerDiskInfo *perDiskGroups, unsigned int groupCount);

CFStringRef CreateRandomizedFileName(void);
