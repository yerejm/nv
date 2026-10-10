//
//  TemporaryFileCachePreparer.h
//  Notation
//

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


#import <Cocoa/Cocoa.h>

@class NotationPrefs;

//encrypted notes are edited externally only from a RAM disk, so their plaintext never reaches persistent storage;
//other notes use a private temporary directory
@interface TemporaryFileCachePreparer : NSObject {
	NSString *directory;
	BOOL protectsContents, preparing, releaseRequested;
	NSString *deviceName, *preparedCachePath;
	NSMutableArray *pendingCompletions;
}

+ (NSUInteger)largestProtectedNoteLength;
+ (void)removeStaleEditingSpacesInDirectory:(NSString*)aDirectory;
+ (void)alertNoteTooLarge;
+ (void)alertProtectedSpaceUnavailable;

- (instancetype)initWithNotationPrefs:(NotationPrefs*)prefs;
- (instancetype)initWithDirectory:(NSString*)aDirectory protectsContents:(BOOL)protects;

- (BOOL)protectsContents;
- (BOOL)isPreparing;
- (NSString*)preparedCachePath;

//the completion runs on the main thread with the editing space's path, or nil if it could not be prepared
- (void)prepareEditingSpace:(void (^)(NSString *path))completion;
- (void)releaseEditingSpaceWaiting:(BOOL)wait;

@end
