//
//  NotationDirectoryManager.h
//  Notation
//
//  Created by Zachary Schneirov on 11/29/09.

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

#import "NotationController.h"
@class NoteObject;

@interface NotationController (NotationDirectoryManager)

NSInteger compareCatalogEntryName(const void *one, const void *two);
NSInteger compareCatalogValueNodeID(id *a, id *b);
NSInteger compareCatalogValueFileSize(id *a, id *b);

- (NSSet<NoteObject *> *)notesWithFilenames:(NSArray<NSString *> *)filenames unknownFiles:(NSArray<NSString *> **)unknownFiles;

- (BOOL)_readFilesInDirectory;
- (BOOL)modifyNoteIfNecessary:(NoteObject*)aNoteObject usingCatalogEntry:(NoteCatalogEntry*)catEntry;
- (void)makeNotesMatchCatalogEntries:(NoteCatalogEntry**)catEntriesPtrs ofSize:(size_t)catCount;
- (void)processNotesAddedByCNID:(NSMutableArray<NSValue *> *)addedEntries removed:(NSMutableArray<NoteObject *> *)removedEntries;
- (void)processNotesAddedByContent:(NSMutableArray<NSValue *> *)addedEntries removed:(NSMutableArray<NoteObject *> *)removedEntries;
- (BOOL)synchronizeNotesFromDirectory;
- (void)_destroyDirEventStream;
- (void)_configureDirEventStream;
- (void)startFileNotifications;
- (void)stopFileNotifications;

@end
