//
//  ODBEditor.m
//  B-Quartic

// http://gusmueller.com/odb/

/**
    
    Nov 30- Updates from Eric Blair:
        removed entries from the _filesBeingEdited dictionary when the odb connection is closed.
        added support for handling Save As messages.
 
    Nov 30- Updates from Gus Mueller:
        Added stringByResolvingSymlinksInPath around the file paths passed around, because it seems if you write to
        /tmp/, sometimes you'll get back /private/tmp as a param

*/


#import "NSAppleEventDescriptor-Extensions.h"
#import "ODBEditor.h"
#import "ODBEditorSuite.h"
#import "NotationPrefs.h"
#import "TemporaryFileCachePreparer.h"
#import "ExternalEditorListController.h"
#import "NoteObject.h"
#import <Carbon/Carbon.h>

NSString * const ODBEditorCustomPathKey		= @"ODBEditorCustomPath";
NSString * const ODBEditorNonRetainedClient = @"ODBEditorNonRetainedClient";
NSString * const ODBEditorClientContext		= @"ODBEditorClientContext";
NSString * const ODBEditorFileName			= @"ODBEditorFileName";

@interface ODBEditor(Private)

- (NSString*)_nonexistingTemporaryPathForFilename:(NSString*)filename;
- (BOOL)_editFile:(NSString *)path inEditor:(ExternalEditor*)ed options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context;
- (void)handleModifiedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent;
- (void)handleClosedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent;

@end

@implementation ODBEditor

static ODBEditor	*_sharedODBEditor;

+ (id)sharedODBEditor {
	if (_sharedODBEditor == nil) {
		_sharedODBEditor = [[ODBEditor alloc] init];
	}
	return _sharedODBEditor;
}

- (id)init {
	self = [super init];
	if (self != nil) {
		UInt32  packageType = 0;
		UInt32  packageCreator = 0;
		
		if (_sharedODBEditor != nil) {
			[self autorelease];
			[NSException raise: NSInternalInconsistencyException format: @"ODBEditor is a singleton - use [ODBEditor sharedODBEditor]"];
			return nil;
		}
		// our initialization
		
		CFBundleGetPackageInfo(CFBundleGetMainBundle(), &packageType, &packageCreator);
		_signature = packageCreator;
		
		_filePathsBeingEdited = [[NSMutableDictionary alloc] init];

		// setup our event handlers
		
		NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
		[appleEventManager setEventHandler: self andSelector: @selector(handleModifiedFileEvent:withReplyEvent:) forEventClass: kODBEditorSuite andEventID: kAEModifiedFile];
		[appleEventManager setEventHandler: self andSelector: @selector(handleClosedFileEvent:withReplyEvent:) forEventClass: kODBEditorSuite andEventID: kAEClosedFile];
				
	}
	
	return self;
}

- (void)dealloc {
	NSAppleEventManager *appleEventManager = [NSAppleEventManager sharedAppleEventManager];
	[appleEventManager removeEventHandlerForEventClass: kODBEditorSuite andEventID: kAEModifiedFile];
	[appleEventManager removeEventHandlerForEventClass: kODBEditorSuite andEventID: kAEClosedFile];
	[_filePathsBeingEdited release];
	[editingSpacePreparer release];
	[super dealloc];
}

- (void)initializeDatabase:(NotationPrefs*)prefs {
	if (editingSpacePreparer) {
		[editingSpacePreparer setDelegate:nil];
		[editingSpacePreparer release];
	}
	[(editingSpacePreparer = [[TemporaryFileCachePreparer alloc] init]) setDelegate:self];
	[editingSpacePreparer prepEditingSpaceIfNecessaryForNotationPrefs:prefs];
}

- (void)temporaryFileCachePreparerDidNotFinish:(TemporaryFileCachePreparer*)preparer {
	NSLog(@"preparer failed");
}
- (void)temporaryFileCachePreparerFinished:(TemporaryFileCachePreparer*)preparer {
	NSLog(@"finished: '%@'", [preparer preparedCachePath]);
}

- (void)abortAllEditingSessionsForClient:(id)client {
	if (![_filePathsBeingEdited count]) return;
	
	NSEnumerator *enumerator = [_filePathsBeingEdited objectEnumerator];
	NSMutableArray *keysToRemove = [NSMutableArray array];
	NSDictionary *dictionary = nil;
	
	while (nil != (dictionary = [enumerator nextObject])) {
		id  iterClient = [[dictionary objectForKey: ODBEditorNonRetainedClient] nonretainedObjectValue];
		
		if (iterClient == client) {
			[keysToRemove addObject:[dictionary objectForKey: ODBEditorFileName]];
		}
	}
	
	[_filePathsBeingEdited removeObjectsForKeys: keysToRemove];
}

- (BOOL)editNote:(NoteObject*)aNote inEditor:(ExternalEditor*)ed context:(NSDictionary *)context {
	if (!aNote) goto beepReturn;
	
	//see comments in -[TemporaryFileCachePreprer prepEditingSpaceIfNecessaryForNotationPrefs:]
	
	//let's first see if we can avoid this whole ODB protocol rigmarole altogether, and ideally even allow non-plain-text editors to be used		
	if ([ed canEditNoteDirectly:aNote]) {
		NSString *path = [aNote noteFilePath];
		
		[[NSWorkspace sharedWorkspace] openURLs:@[[NSURL fileURLWithPath:path]] withApplicationAtURL:[ed resolvedURL] configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:^(NSRunningApplication *application, NSError *error) {
            if (error) dispatch_async(dispatch_get_main_queue(), ^{ NSLog(@"Could not open note in external editor: %@", error); NSBeep(); });
        }];
		return YES;
	}

	//weren't able to edit the note-file directly, so fall back to opening a copy of it using an ODB editor
	//what if this editor is not an ODB editor? what if the path doesn't exist?
	
	if (![editingSpacePreparer preparedCachePath]) {
		NSLog(@"not editing '%@' because temporary cache path was not initialized", aNote);
		goto beepReturn;
	}
	if (![ed isODBEditor]) {
		NSLog(@"not editing '%@' with '%@' because it is not an ODB editor and the note-file cannot be saved directly", aNote, ed);
		goto beepReturn;
	}
	
	//now write aNote as text to path?
	NSString *path = [self _nonexistingTemporaryPathForFilename:filenameOfNote(aNote)];	
	NSError *error = nil;
	if (![[[aNote contentString] string] writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:&error]) {
		NSLog(@"not editing '%@' because it could not be written to '%@'", aNote, path);
		goto beepReturn;
	}
	
	return [self _editFile:path inEditor:ed options:[NSDictionary dictionaryWithObject:titleOfNote(aNote) forKey:ODBEditorCustomPathKey] forClient:aNote context:context];
beepReturn:
	NSBeep();
	return NO;
}

@end

@implementation ODBEditor(Private)

- (NSString*)_nonexistingTemporaryPathForFilename:(NSString*)filename {
	unsigned int sTempFileSequence = 0;
	NSString *path = nil;
	NSString *basename = [filename stringByDeletingPathExtension];
	NSFileManager *fileManager = [NSFileManager defaultManager];
	
	NSAssert([editingSpacePreparer preparedCachePath] != nil, @"cache path does not exist!");
	
	do {
		path = sTempFileSequence++ ? [NSString stringWithFormat: @"%@ %03d.txt", basename, sTempFileSequence] : [basename stringByAppendingPathExtension:@"txt"];
		path = [[editingSpacePreparer preparedCachePath] stringByAppendingPathComponent: path];
	} while ([fileManager fileExistsAtPath:path]);
	
	return path;
}

- (BOOL)_editFile:(NSString *)path inEditor:(ExternalEditor *)editor options:(NSDictionary *)options forClient:(id)client context:(NSDictionary *)context {
    if (!editor) editor = [[ExternalEditorListController sharedInstance] defaultExternalEditor];
    NSURL *applicationURL = [editor resolvedURL];
    if (!applicationURL || !path || !client) return NO;
    NSData *identifier = [[editor bundleIdentifier] dataUsingEncoding:NSUTF8StringEncoding];
    NSAppleEventDescriptor *target = [NSAppleEventDescriptor descriptorWithDescriptorType:typeApplicationBundleID data:identifier];
    NSAppleEventDescriptor *event = [NSAppleEventDescriptor appleEventWithEventClass:kCoreEventClass eventID:kAEOpenDocuments targetDescriptor:target returnID:kAutoGenerateReturnID transactionID:kAnyTransactionID];
    [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithFilePath:path] forKeyword:keyDirectObject];
    [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithTypeCode:_signature] forKeyword:keyFileSender];
    NSString *customPath = [options objectForKey:ODBEditorCustomPathKey];
    if (customPath) [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:customPath] forKeyword:keyFileCustomPath];

    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSValue valueWithNonretainedObject:client], ODBEditorNonRetainedClient,
        path, ODBEditorFileName, nil];
    if (context) [record setObject:context forKey:ODBEditorClientContext];
    [_filePathsBeingEdited setObject:record forKey:path];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    [configuration setAppleEvent:event];
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:applicationURL configuration:configuration completionHandler:^(NSRunningApplication *application, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error && [_filePathsBeingEdited objectForKey:path] == record) {
                [_filePathsBeingEdited removeObjectForKey:path];
                NSLog(@"Could not open external editing session: %@", error);
                NSBeep();
            }
        });
    }];
    return YES;
}

- (void)handleModifiedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	NSAppleEventDescriptor *fpDescriptor = [[event paramDescriptorForKeyword: keyDirectObject] coerceToDescriptorType: typeFileURL];
	NSString *urlString = [[[NSString alloc] initWithData: [fpDescriptor data] encoding: NSUTF8StringEncoding] autorelease];
	NSString *path = [[[NSURL URLWithString: urlString] path] stringByResolvingSymlinksInPath];
	NSAppleEventDescriptor	*nfpDescription = [[event paramDescriptorForKeyword: keyNewLocation] coerceToDescriptorType: typeFileURL];
	NSString *newUrlString = [[[NSString alloc] initWithData: [nfpDescription data] encoding: NSUTF8StringEncoding] autorelease];
	NSString *newPath = [[NSURL URLWithString: newUrlString] path];
	NSDictionary *dictionary = [_filePathsBeingEdited objectForKey: path];
	
	if (dictionary != nil)
	{
		id  client		= [[dictionary objectForKey: ODBEditorNonRetainedClient] nonretainedObjectValue];
		NSDictionary *context	= [dictionary objectForKey: ODBEditorClientContext];
		
		[client odbEditor:self didModifyFile:path newFileLocation:newPath context:context];

		// if we've received a Save As message, remove the file from the list of edited files
		// This may be break compatibility with BBEdit versioner < 6.0, since these versions
		// continue to send notifications after after doing a Save As...
		if(newPath) {
			[_filePathsBeingEdited removeObjectForKey: newPath];
	    }

	}
	else
	{
		NSLog(@"Got ODB editor event for unknown file '%@'", path);
	}
}

- (void)handleClosedFileEvent:(NSAppleEventDescriptor *)event withReplyEvent:(NSAppleEventDescriptor *)replyEvent {
	NSAppleEventDescriptor  *descriptor = [[event paramDescriptorForKeyword: keyDirectObject] coerceToDescriptorType: typeFileURL];
	NSString				*urlString = [[[NSString alloc] initWithData: [descriptor data] encoding: NSUTF8StringEncoding] autorelease];
	NSString				*fileName = [[[NSURL URLWithString: urlString] path] stringByResolvingSymlinksInPath];
	NSDictionary			*dictionary = [_filePathsBeingEdited objectForKey: fileName];
	
	if (dictionary != nil) {
		id client		= [[dictionary objectForKey: ODBEditorNonRetainedClient] nonretainedObjectValue];
		NSDictionary *context	= [dictionary objectForKey: ODBEditorClientContext];
		
		[client odbEditor:self didClosefile:fileName context:context];
	}
	else
	{
		NSLog(@"Got ODB editor event for unknown file '%@'", fileName);
	}
	if (fileName)
		[_filePathsBeingEdited removeObjectForKey: fileName];
}

@end

