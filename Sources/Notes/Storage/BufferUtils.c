/*
 *  BufferUtils.c
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


#include "BufferUtils.h"
#include <math.h>
#include <string.h>

static const unsigned char gsToLowerMap[256] = {
'\0', 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, '\t',
'\n', 0x0b, 0x0c, '\r', 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13,
0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d,
0x1e, 0x1f,  ' ',  '!',  '"',  '#',  '$',  '%',  '&', '\'',
'(',  ')',  '*',  '+',  ',',  '-',  '.',  '/',  '0',  '1',
'2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',  ':',  ';',
'<',  '=',  '>',  '?',  '@',  'a',  'b',  'c',  'd',  'e',
'f',  'g',  'h',  'i',  'j',  'k',  'l',  'm',  'n',  'o',
'p',  'q',  'r',  's',  't',  'u',  'v',  'w',  'x',  'y',
'z',  '[', '\\',  ']',  '^',  '_',  '`',  'a',  'b',  'c',
'd',  'e',  'f',  'g',  'h',  'i',  'j',  'k',  'l',  'm',
'n',  'o',  'p',  'q',  'r',  's',  't',  'u',  'v',  'w',
'x',  'y',  'z',  '{',  '|',  '}',  '~', 0x7f, 0x80, 0x81,
0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x8b,
0x8c, 0x8d, 0x8e, 0x8f, 0x90, 0x91, 0x92, 0x93, 0x94, 0x95,
0x96, 0x97, 0x98, 0x99, 0x9a, 0x9b, 0x9c, 0x9d, 0x9e, 0x9f,
0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9,
0xaa, 0xab, 0xac, 0xad, 0xae, 0xaf, 0xb0, 0xb1, 0xb2, 0xb3,
0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xbb, 0xbc, 0xbd,
0xbe, 0xbf, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7,
0xc8, 0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf, 0xd0, 0xd1,
0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xdb,
0xdc, 0xdd, 0xde, 0xdf, 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5,
0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xeb, 0xec, 0xed, 0xee, 0xef,
0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9,
0xfa, 0xfb, 0xfc, 0xfd, 0xfe, 0xff };

#if !defined(MIN)
#define MIN(A,B)	({ __typeof__(A) __a = (A); __typeof__(B) __b = (B); __a < __b ? __a : __b; })
#endif

#if !defined(MAX)
#define MAX(A,B)	({ __typeof__(A) __a = (A); __typeof__(B) __b = (B); __a < __b ? __b : __a; })
#endif


//seconds from the archived dates' 1904 epoch to the Unix and CFAbsoluteTime epochs
#define ArchivedDateUnixEpoch 2082844800LL
#define ArchivedDateAbsoluteTimeEpoch 3061152000.0

NVArchivedDate NVArchivedDateFromTimespec(struct timespec date) {
	if (NVFileDateIsEmpty(date)) return (NVArchivedDate){0, 0, 0};
	//rounded through CFAbsoluteTime as UCConvertCFAbsoluteTimeToUTCDateTime did, so dates it archived still compare equal;
	//unlike that function, a fraction that rounds up to a whole second carries into the seconds
	double total = NVAbsoluteTimeFromTimespec(date) + ArchivedDateAbsoluteTimeEpoch;
	if (total < 0.0) return (NVArchivedDate){0, 0, 0};
	double seconds = floor(total);
	long fraction = lround((total - seconds) * 65536.0);
	if (fraction == 65536) {
		seconds += 1.0;
		fraction = 0;
	}
	uint64_t wholeSeconds = (uint64_t)seconds;
	return (NVArchivedDate){(UInt16)(wholeSeconds >> 32), (UInt32)wholeSeconds, (UInt16)fraction};
}

struct timespec NVTimespecFromArchivedDate(NVArchivedDate date) {
	if (!date.highSeconds && !date.lowSeconds && !date.fraction) return (struct timespec){0, 0};
	int64_t seconds = (int64_t)((uint64_t)date.highSeconds << 32 | date.lowSeconds) - ArchivedDateUnixEpoch;
	long nanoseconds = (long)(((uint64_t)date.fraction * 1000000000ULL + 32768) / 65536);
	return (struct timespec){(time_t)seconds, nanoseconds};
}

CFAbsoluteTime NVAbsoluteTimeFromTimespec(struct timespec date) {
	return (CFAbsoluteTime)date.tv_sec - kCFAbsoluteTimeIntervalSince1970 + (double)date.tv_nsec / 1e9;
}

struct timespec NVTimespecFromAbsoluteTime(CFAbsoluteTime time) {
	double unixTime = time + kCFAbsoluteTimeIntervalSince1970;
	double seconds = floor(unixTime);
	long nanoseconds = lround((unixTime - seconds) * 1e9);
	if (nanoseconds == 1000000000L) {
		seconds += 1.0;
		nanoseconds = 0;
	}
	return (struct timespec){(time_t)seconds, nanoseconds};
}

Boolean NVFileDateIsEmpty(struct timespec date) {
	return !date.tv_sec && !date.tv_nsec;
}

static uint64_t ArchivedTicks(struct timespec date) {
	NVArchivedDate archived = NVArchivedDateFromTimespec(date);
	return ((uint64_t)archived.highSeconds << 48) | ((uint64_t)archived.lowSeconds << 16) | archived.fraction;
}

int NVCompareFileDates(struct timespec a, struct timespec b) {
	uint64_t aTicks = ArchivedTicks(a), bTicks = ArchivedTicks(b);
	return aTicks < bTicks ? -1 : aTicks > bTicks;
}

char *replaceString(char *oldString, const char *newString) {
    size_t newLen = strlen(newString) + 1;

    //realloc is smart enough to do better memory management than we can do right here
    char *resizedString = (char*)realloc(oldString, newLen);
    memmove(resizedString, newString, newLen);
    
    return resizedString;
}


void _ResizeBuffer(void ***buffer, size_t objCount, unsigned int *bufObjCount, size_t elemSize) {
	assert(buffer && bufObjCount);
    if (objCount > UINT_MAX || objCount > SIZE_MAX / elemSize) abort();
	
	if (*bufObjCount < objCount || !*buffer) {
		*buffer = (void **)realloc(*buffer, elemSize * objCount);
		*bufObjCount = (unsigned int)objCount;
	}
	
}

int IsZeros(const void *s1, size_t n) {
	if (n != 0) {
		const unsigned char *p1 = s1;
		
		do {
			if (*p1++ != 0)
				return (0);
		} while (--n != 0);
	}
	return (1);
}

void modp_tolower_copy(char* dest, const char* str, size_t len) {
	size_t i;
	NSUInteger eax, ebx;
	const uint8_t* ustr = (const uint8_t*) str;
	const size_t leftover = len % sizeof(NSUInteger);
	const size_t imax = len / sizeof(NSUInteger);
	const NSUInteger* s = (const NSUInteger*) str;
	NSUInteger* d = (NSUInteger*) dest;
	for (i = 0; i != imax; ++i) {
		eax = s[i];
		/*
		 * This is based on the algorithm by Paul Hsieh
		 * http://www.azillionmonkeys.com/qed/asmexample.html
		 */
		ebx = (0x7f7f7f7f7f7f7f7fllu & eax) + 0x2525252525252525llu;
		ebx = (0x7f7f7f7f7f7f7f7fllu & ebx) + 0x1a1a1a1a1a1a1a1allu;
		ebx = ((ebx & ~eax) >> 2)  & 0x2020202020202020llu;
		*d++ = eax + ebx;
	}
	
	i = imax * sizeof(NSUInteger);
	dest = (char*) d;
	switch (leftover) {
		case 7: *dest++ = (char) gsToLowerMap[ustr[i++]];
		case 6: *dest++ = (char) gsToLowerMap[ustr[i++]];
		case 5: *dest++ = (char) gsToLowerMap[ustr[i++]];
		case 4: *dest++ = (char) gsToLowerMap[ustr[i++]];			
		case 3: *dest++ = (char) gsToLowerMap[ustr[i++]];
		case 2: *dest++ = (char) gsToLowerMap[ustr[i++]];
		case 1: *dest++ = (char) gsToLowerMap[ustr[i]];
		case 0: *dest = '\0';
	}
}

int ContainsUInteger(const NSUInteger *uintArray, size_t count, NSUInteger auint) {
	size_t i;
	for (i=0; i<count; i++) {
		if (uintArray[i] == auint) return 1;
	}
	return 0;
}


int ContainsHighAscii(const void *s1, size_t n) {
	
	register NSUInteger *intBuffer = (NSUInteger*)s1;
	register NSUInteger i, integerCount = n/sizeof(NSUInteger);	
	register NSUInteger pattern = 
	0x8080808080808080;
	
	for (i=0; i<integerCount; i++ ) {
		if (pattern & intBuffer[i]) {
			return 1;
		}
	}
	
	unsigned char *charBuffer = (unsigned char*)s1;
	NSUInteger leftOverCharCount = n % sizeof(NSUInteger);
	
	for (i = n - leftOverCharCount; i<n; i++) {
		if (charBuffer[i] > 127) {
			return 1;
		}
	}
	
	return 0;
}

unsigned DumbWordCount(const void *s1, size_t len) {

	unsigned count = len > 0;
	//we could do a lot more here, but we don't.
	const void *ptr = s1;
	while ((ptr = memchr(ptr + 1, 0x20, len))) {
		count++;
	}

	return count;
}

NSInteger genericSortContextFirst(int (*context) (void*, void*), void* one, void* two) {
	
	return context(one, two);
}

NSInteger genericSortContextLast(void* one, void* two, int (*context) (void*, void*)) {
	
	return context(&one, &two);
}

void QuickSortBuffer(void **buffer, unsigned int objCount, int (*compar)(const void *, const void *)) {
	qsort_r((void *)buffer, (size_t)objCount, sizeof(void*), compar, (int (*)(void *, const void *, const void *))genericSortContextFirst);
}

//these two methods manipulate notes' perdiskinfo groups, changing the buffers in place
//on return, groupCount will be set to the number of perdiskinfo structs currently in the buffer

void RemovePerDiskInfoWithTableIndex(UInt32 diskIndex, PerDiskInfo **perDiskGroups, unsigned int *groupCount) {
	//used to periodically clean out attr-mod-times for disks that have not been seen in a while
	
	//if an entry exists, push everything below it upward and resize the buffer (or just copy to a new buffer)
	//otherwise do nothing
	
	unsigned int i = 0, count = *groupCount;
	
	PerDiskInfo *groups = *perDiskGroups;
	for (i=0; i<count; i++) {
		if (groups[i].diskIDIndex == diskIndex) {
			
			if (i < count - 1) {
				//if pair isn't the last struct, then bring everything after pair up one spot
				memmove(&groups[i], &groups[i + 1], sizeof(PerDiskInfo) * ((count - 1) - i));
			}
			ResizeArray(perDiskGroups, count - 1, groupCount);
			return;
		}
	}
}

unsigned int SetPerDiskInfoWithTableIndex(struct timespec *dateTime, UInt32 *nodeID, UInt32 diskIndex, PerDiskInfo **perDiskGroups, unsigned int *groupCount) {
	//if an entry for this diskIndex already exists, then just update it in place
	//if an entry does not exist, then resize the buffer and add one at the end
	//if one of dateTime or nodeID is NULL, then do not set it
	
	assert(nodeID || dateTime);
	
	unsigned int i = 0, count = *groupCount;
	
	PerDiskInfo *groups = *perDiskGroups;
	for (i=0; i<count; i++) {
		//use this slot if the diskIndex matches OR it's the first one listed and its attrTime and nodeID haven't been touched
		if (groups[i].diskIDIndex == diskIndex || (!i && groups[i].nodeID == 0U && NVFileDateIsEmpty(groups[i].attrTime))) {
			if (dateTime) groups[i].attrTime = *dateTime;
			if (nodeID) groups[i].nodeID = *nodeID;
			groups[i].diskIDIndex = diskIndex;
			return i;
		}
	}
	
	//diskID not found in existing buffer; add a new entry one or both attributes
	ResizeArray(perDiskGroups, count + 1, groupCount);
	
	//items not currently being set are initialized to a known value, so that they can be initialized later by attrsModifiedDateOfNote and fileNodeIDOfNote
	//although those functions do not initialize these to anything particularly useful, anyway
	groups = *perDiskGroups;
	groups[count].attrTime = dateTime ? *dateTime : (struct timespec){0, 0};
	groups[count].nodeID = nodeID ? *nodeID : 0;
	groups[count].diskIDIndex = diskIndex;
	
	return count;
}

COMPILE_ASSERT(sizeof(NVArchivedDate) == 8, ARCHIVED_DATE_MUST_BE_8_BYTES);
COMPILE_ASSERT(sizeof(NVArchivedPerDiskInfo) == 16, ARCHIVED_PER_DISK_INFO_MUST_BE_16_BYTES);

void DecodePerDiskInfoGroups(PerDiskInfo **perDiskGroups, unsigned int *groupCount, const void *bytes, size_t length) {
	//resizes perDiskGroups if it is too small (based on *groupCount)
	size_t i, count = length / sizeof(NVArchivedPerDiskInfo);
	
	ResizeArray(perDiskGroups, count, groupCount);
	PerDiskInfo *groups = *perDiskGroups;
	
	for (i=0; i<count; i++) {
		NVArchivedPerDiskInfo group;
		memcpy(&group, (const char *)bytes + i * sizeof(group), sizeof(group));
		NVArchivedDate attrTime = {
			CFSwapInt16BigToHost(group.attrTime.highSeconds),
			CFSwapInt32BigToHost(group.attrTime.lowSeconds),
			CFSwapInt16BigToHost(group.attrTime.fraction)
		};
		groups[i].attrTime = NVTimespecFromArchivedDate(attrTime);
		groups[i].nodeID = CFSwapInt32BigToHost(group.nodeID);
		groups[i].diskIDIndex = CFSwapInt32BigToHost(group.diskIDIndex);
	}
}

NVArchivedPerDiskInfo *CreateArchivedPerDiskInfoGroups(const PerDiskInfo *perDiskGroups, unsigned int groupCount) {
	NVArchivedPerDiskInfo *archivedGroups = calloc(groupCount ? groupCount : 1, sizeof(NVArchivedPerDiskInfo));
	if (!archivedGroups) abort();
	
	unsigned int i;
	for (i=0; i<groupCount; i++) {
		NVArchivedDate attrTime = NVArchivedDateFromTimespec(perDiskGroups[i].attrTime);
		archivedGroups[i].attrTime.highSeconds = CFSwapInt16HostToBig(attrTime.highSeconds);
		archivedGroups[i].attrTime.lowSeconds = CFSwapInt32HostToBig(attrTime.lowSeconds);
		archivedGroups[i].attrTime.fraction = CFSwapInt16HostToBig(attrTime.fraction);
		archivedGroups[i].nodeID = CFSwapInt32HostToBig(perDiskGroups[i].nodeID);
		archivedGroups[i].diskIDIndex = CFSwapInt32HostToBig(perDiskGroups[i].diskIDIndex);
	}
	return archivedGroups;
}

CFStringRef CreateRandomizedFileName(void) {
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    CFStringRef string = CFUUIDCreateString(NULL, uuid);
    CFStringRef name = CFStringCreateWithFormat(NULL, NULL, CFSTR(".%@"), string);
    CFRelease(string);
    CFRelease(uuid);
    return name;
}
