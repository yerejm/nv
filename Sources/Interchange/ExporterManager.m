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


#import "ExporterManager.h"
#import "NoteObject.h"
#import "NotationPrefs.h"
#import "NSString_NV.h"
#import "GlobalPrefs.h"

@implementation ExporterManager

+ (ExporterManager *)sharedManager {
	static ExporterManager *man = nil;
	if (!man)
		man = [[ExporterManager alloc] init];
	return man;
}

- (void)awakeFromNib {
	
	NSInteger storageFormat = [[[GlobalPrefs defaultPrefs] notationPrefs] notesStorageFormat];
	[formatSelectorPopup selectItemWithTag:storageFormat];
}

- (IBAction)formatSelectorChanged:(id)sender {
    [exportPanel setAllowedContentTypes:@[]];
    [exportPanel setAllowsOtherFileTypes:YES];
    //keep a format's own extension in step with the chosen format, but leave any other name alone
    NSString *name = [exportPanel nameFieldStringValue];
    NSString *extension = [NotationPrefs pathExtensionForFormat:(int)[[formatSelectorPopup selectedItem] tag]];
    for (int format = PlainTextFormat; format <= WordXMLFormat; format++) {
        if ([[name pathExtension] caseInsensitiveCompare:[NotationPrefs pathExtensionForFormat:format]] == NSOrderedSame) {
            [exportPanel setNameFieldStringValue:[[name stringByDeletingPathExtension] stringByAppendingPathExtension:extension]];
            break;
        }
    }
}

- (void)exportPanelDidEnd:(NSSavePanel *)sheet returnCode:(NSModalResponse)returnCode contextInfo:(void  *)contextInfo {
	NSArray *notes = (NSArray *)contextInfo;
	if (returnCode == NSModalResponseOK && notes) {
		//write notes in chosen format
		unsigned int i;
		NSModalResponse result;
    int storageFormat = (int)[[formatSelectorPopup selectedItem] tag];
		NSString *directory = nil, *filename = nil;
		BOOL overwriteNotes = NO;
		
		if ([sheet isKindOfClass:[NSOpenPanel class]]) {
			directory = [[sheet URL] path];
		} else {
			filename = [[[sheet URL] path] lastPathComponent];
			directory = [[[sheet URL] path] stringByDeletingLastPathComponent];
			
			NSAssert([notes count] == 1, @"We returned from a save panel with more than one note?!");
			
			//user wanted us to overwrite this one--otherwise dialog would have been cancelled
			if ([[NSFileManager defaultManager] fileExistsAtPath:[[sheet URL] path]]) overwriteNotes = YES;
			
			if ([filename compare:filenameOfNote([notes lastObject]) options:NSCaseInsensitiveSearch] != NSOrderedSame) {
				//undo any POSIX-safe crap NSSavePanel gave us--otherwise NVCreateFileUnicode will fail
				filename = [filename stringByReplacingOccurrencesOfString:@":" withString:@"/"];
			}
		}
		
		NVFileReference directoryRef;
		CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)directory, kCFURLPOSIXPathStyle, true);
		[(id)url autorelease];
		if (!url || !NVURLGetFileReference(url, &directoryRef)) {
			NVRunAlert(NSAlertStyleWarning, [NSString stringWithFormat:NSLocalizedString(@"The notes couldn't be exported because the directory quotemark%@quotemark couldn't be accessed.",nil),
				[directory stringByAbbreviatingWithTildeInPath]], @"", NSLocalizedString(@"OK",nil), nil, nil);
			return;
		}
		
		//re-uniqify file names here (if [notes count] > 1)?
		
		for (i=0; i<[notes count]; i++) {
			BOOL lastNote = i != [notes count] - 1;
			NoteObject *note = [notes objectAtIndex:i];
			
			OSStatus err = [note exportToDirectoryRef:&directoryRef withFilename:filename usingFormat:storageFormat overwrite:overwriteNotes];
			
			if (err == dupFNErr) {
				//ask about overwriting
				NSString *existingName = filename ? filename : filenameOfNote(note);
				if (!filename) existingName = [[existingName stringByDeletingPathExtension] stringByAppendingPathExtension:[NotationPrefs pathExtensionForFormat:storageFormat]];
				result = NVRunAlert(NSAlertStyleWarning, [NSString stringWithFormat:NSLocalizedString(@"A file named quotemark%@quotemark already exists.",nil), existingName], NSLocalizedString(@"Replace its current contents with that of the note?", @"replace the file's contents?"), NSLocalizedString(@"Replace",nil), NSLocalizedString(@"Don't Replace",nil), lastNote ? NSLocalizedString(@"Replace All",nil) : nil);
				if (result == NSAlertFirstButtonReturn || result == NSAlertThirdButtonReturn) {
					if (result == NSAlertThirdButtonReturn) overwriteNotes = YES;
					err = [note exportToDirectoryRef:&directoryRef withFilename:filename usingFormat:storageFormat overwrite:YES];
				} else continue;
			}
			
			if (err != noErr) {
				NSString *exportErrorTitleString = [NSString stringWithFormat:NSLocalizedString(@"The note quotemark%@quotemark couldn't be exported because %@.",nil), 
					titleOfNote(note), [NSString reasonStringFromCarbonFSError:err]];
				if (!lastNote) {
					NVRunAlert(NSAlertStyleWarning, exportErrorTitleString, @"", NSLocalizedString(@"OK",nil), nil, nil);
				} else {
					result = NVRunAlert(NSAlertStyleWarning, exportErrorTitleString, NSLocalizedString(@"Continue exporting?", @"alert title for exporter interruption"), NSLocalizedString(@"Continue", @"(exporting notes?)"), NSLocalizedString(@"Stop Exporting", @"(notes?)"), nil);
					if (result != NSAlertFirstButtonReturn) break;
				}
			}
		}
		

		
	}
    [notes release];
    [exportPanel release];
    exportPanel = nil;
}

- (void)exportNotes:(NSArray*)notes forWindow:(NSWindow*)window {
	
	if (!accessoryView) {
		if (!NVLoadNib(@"ExporterManager", self)) {
			NSLog(@"Failed to load ExporterManager.nib");
			NSBeep();
			return;
		}
	}
	
	if ([notes count] == 1) {
		NSSavePanel *savePanel = [NSSavePanel savePanel];
        exportPanel = [savePanel retain];
		[savePanel setAccessoryView:accessoryView];
		[savePanel setCanCreateDirectories:YES];
		[savePanel setCanSelectHiddenExtension:YES];
		
		[self formatSelectorChanged:formatSelectorPopup];
		
		NSString *filename = filenameOfNote([notes lastObject]);
		filename = [filename stringByDeletingPathExtension];
		filename = [filename stringByAppendingPathExtension:[NotationPrefs pathExtensionForFormat:(int)[[formatSelectorPopup selectedItem] tag]]];
			
		[savePanel setNameFieldStringValue:filename];
        NVBeginPanel(savePanel, window, self, @selector(exportPanelDidEnd:returnCode:contextInfo:), (void *)[notes retain]);
		
	} else if ([notes count] > 1) {
		NSOpenPanel *openPanel = [NSOpenPanel openPanel];
		[openPanel setAccessoryView:accessoryView];
		[openPanel setCanCreateDirectories:YES];
		[openPanel setCanChooseFiles:NO];
		[openPanel setCanChooseDirectories:YES];
		[openPanel setPrompt:NSLocalizedString(@"Export",@"title of button to export notes from folder selection dialog")];
		[openPanel setTitle:NSLocalizedString(@"Export Notes", @"title of export notes dialog")];
		[openPanel setMessage:NVFormatCount(NSLocalizedString(@"Choose a folder into which %d notes will be exported",nil), [notes count])];

		NVBeginPanel(openPanel, window, self, @selector(exportPanelDidEnd:returnCode:contextInfo:), (void *)[notes retain]);
	} else {
		NVRunAlert(NSAlertStyleWarning, NSLocalizedString(@"No notes were selected for exporting.",nil), NSLocalizedString(@"You must select at least one note to export.",nil), NSLocalizedString(@"OK",nil), NULL, NULL);
	}
}

@end
