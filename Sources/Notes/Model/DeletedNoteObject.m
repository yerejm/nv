//
//  DeletedNoteObject.m
//  Notation
//
//  Created by Zachary Schneirov on 4/16/06.

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


#import "DeletedNoteObject.h"
#import "NSString_NV.h"

@implementation DeletedNoteObject

+ (id)deletedNoteWithNote:(id <SynchronizedNote>)aNote {
	return [[DeletedNoteObject alloc] initWithExistingObject:aNote];
}

- (id)initWithExistingObject:(id<SynchronizedNote>)note {
    if ((self = [super init])) {
		CFUUIDBytes *bytes = [note uniqueNoteIDBytes];
		uniqueNoteIDBytes = *bytes;
		syncServicesMD = [[note syncServicesMD] mutableCopy];
		logSequenceNumber = [note logSequenceNumber];
		//not serialized: for runtime lookup purposes only
		originalNote = note;
    }
    return self;
}

+ (BOOL)supportsSecureCoding {
	return YES;
}

- (id)initWithCoder:(NSCoder*)decoder {
    if ((self = [super init])) {
		
		if ([decoder allowsKeyedCoding]) {
			NSUInteger decodedByteCount;
			const uint8_t *decodedBytes = [decoder decodeBytesForKey:VAR_STR(uniqueNoteIDBytes) returnedLength:&decodedByteCount];
			memcpy(&uniqueNoteIDBytes, decodedBytes, MIN(decodedByteCount, sizeof(CFUUIDBytes)));
			syncServicesMD = [NVDecodeObjectOfClasses(decoder, NVPropertyListClasses(), [NSDictionary class], VAR_STR(syncServicesMD)) mutableCopy];
			logSequenceNumber = [decoder decodeInt32ForKey:VAR_STR(logSequenceNumber)];
		} else {
			[decoder decodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes size:sizeof(uniqueNoteIDBytes)];
			syncServicesMD = [decoder decodeObject];
			[decoder decodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber size:sizeof(logSequenceNumber)];
		}
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
	
	if ([coder allowsKeyedCoding]) {
		[coder encodeBytes:(const uint8_t *)&uniqueNoteIDBytes length:sizeof(CFUUIDBytes) forKey:VAR_STR(uniqueNoteIDBytes)];
		[coder encodeObject:syncServicesMD forKey:VAR_STR(syncServicesMD)];
		[coder encodeInt32:logSequenceNumber forKey:VAR_STR(logSequenceNumber)];
	} else {
		[coder encodeValueOfObjCType:@encode(CFUUIDBytes) at:&uniqueNoteIDBytes];
		[coder encodeObject:syncServicesMD];
		[coder encodeValueOfObjCType:@encode(unsigned int) at:&logSequenceNumber];
	}
}

- (id<SynchronizedNote>)originalNote {
	return originalNote;
}

- (NSString*)description {
	return [NSString stringWithFormat:@"DeletedNoteObj(%@) %@", [NSString uuidStringWithBytes:uniqueNoteIDBytes], syncServicesMD];
}

#include "SynchronizedNoteMixIns.h"

@end
