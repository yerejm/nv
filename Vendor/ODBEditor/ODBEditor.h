
#import <Cocoa/Cocoa.h>

// http://gusmueller.com/odb/

extern NSString * const ODBEditorCustomPathKey;

@class TemporaryFileCachePreparer;
@class ExternalEditor;
@class NotationPrefs;
@class NoteObject;

@interface ODBEditor : NSObject
{
	UInt32					_signature;
	NSMutableDictionary		*_filePathsBeingEdited;
	
	TemporaryFileCachePreparer *editingSpacePreparer;
}
+ (id)sharedODBEditor;

- (void)abortAllEditingSessionsForClient:(id)client;

- (void)initializeDatabase:(NotationPrefs*)prefs;

// NOTE that the note is never retained - it must abort its editing sessions before it is dealloc'd
- (BOOL)editNote:(NoteObject*)aNote inEditor:(ExternalEditor*)ed context:(NSDictionary *)context;

@end

@interface NSObject(ODBEditorClient)

// see the ODB Editor documentation for when newFileLocation is sent
// if the file wasn't subject to a save as newpath will be nil

-(void)odbEditor:(ODBEditor *)editor didModifyFile:(NSString *)path newFileLocation:(NSString *)newPath  context:(NSDictionary *)context;
-(void)odbEditor:(ODBEditor *)editor didClosefile:(NSString *)path context:(NSDictionary *)context;

@end
