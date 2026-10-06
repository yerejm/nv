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


#import "URLGetter.h"

@implementation URLGetter

- (id)initWithURL:(NSURL*)aUrl delegate:(id)aDelegate userData:(id)someObj {
	if (!aUrl || [aUrl isFileURL]) {
		return nil;
	}
	if ([super init]) {
		maxExpectedByteCount = 0;
		isImporting = isIndicating = NO;
		delegate = aDelegate;
		url = [aUrl retain];
		userData = [someObj retain];
		
		session = [[NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:self delegateQueue:[NSOperationQueue mainQueue]] retain];
        downloader = [[session downloadTaskWithURL:url] retain];
        [downloader resume];
		
		[self startProgressIndication:self];
	}
	
	return self;
}

- (void)dealloc {
	[downloader release];
    [session release];
    [downloadError release];
	[downloadPath release];
	[url release];
	[userData release];
	
	[super dealloc];
}

- (NSURL*)url {
	return url;
}

- (id)userData {
	return userData;
}

- (IBAction)cancelDownload:(id)sender {
	[downloader cancel];

	[self endDownloadWithPath:nil];
}

- (void)stopProgressIndication {
	[window close];
	[progress stopAnimation:nil];
	
	isImporting = isIndicating = NO;
}

- (void)startProgressIndication:(id)sender {
	if (!window) {
		if (!NVLoadNib(@"URLGetter", self))  {
			NSLog(@"Failed to load URLGetter.nib");
			NSBeep();
			return;
		}
		[progress setUsesThreadedAnimation:YES];
	}
	
	[progress setIndeterminate:YES];
	[progress startAnimation:nil];
	
	[cancelButton setEnabled:YES];
	[progressStatus setStringValue:NSLocalizedString(@"Download: waiting to begin.", @"download dialog status message")];
	[objectURLStatus setStringValue:[url absoluteString]];
	
	[window center];
	[window makeKeyAndOrderFront:sender];
	
	isIndicating = YES;
}

- (void)updateProgress {
	if (isIndicating) {
		[progress setIndeterminate:!maxExpectedByteCount || isImporting];
		[progress setMaxValue:(double)maxExpectedByteCount];
		
		[progress setDoubleValue:(double)totalReceivedByteCount];
		if (isImporting) {
			[progressStatus setStringValue:NSLocalizedString(@"Importing content...", @"Status message after downloading a URL")];
		} else if (maxExpectedByteCount > 0) {
			[progressStatus setStringValue:[NSString stringWithFormat:NSLocalizedString(@"%.0lf KB of %.0lf KB", nil), 
				(double)totalReceivedByteCount / 1024.0, (double)maxExpectedByteCount / 1024.0]];
		} else {
			[progressStatus setStringValue:[NSString stringWithFormat:NSLocalizedString(@"%.0lf KB received",nil), (double)totalReceivedByteCount / 1024.0]];
		}
	}
}

- (void)URLSession:(NSURLSession *)aSession downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected {
    totalReceivedByteCount = total;
    maxExpectedByteCount = MAX(expected, 0);
    [self updateProgress];
}

- (void)URLSession:(NSURLSession *)aSession downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    if (finished) return;
    tempDirectory = [[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]] retain];
    NSError *error = nil;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *name = [[[task response] suggestedFilename] lastPathComponent];
    if (![name length] || [name isEqualToString:@"."] || [name isEqualToString:@".."]) name = @"download";
    downloadPath = [[tempDirectory stringByAppendingPathComponent:name] retain];
    if (![manager createDirectoryAtPath:tempDirectory withIntermediateDirectories:NO attributes:nil error:&error] ||
        ![manager moveItemAtURL:location toURL:[NSURL fileURLWithPath:downloadPath] error:&error]) {
        downloadError = [error retain];
    }
}

- (void)URLSession:(NSURLSession *)aSession task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (finished) return;
    error = error ?: downloadError;
    if (error) {
        if ([error code] != NSURLErrorCancelled)
            NVRunAlert(NSAlertStyleWarning, [NSString stringWithFormat:NSLocalizedString(@"The URL quotemark%@quotemark could not be accessed: %@.", nil), [url absoluteString], [error localizedDescription]], @"", NSLocalizedString(@"OK", nil), nil, nil);
        [self endDownloadWithPath:nil];
    } else {
        [self endDownloadWithPath:downloadPath];
    }
}

- (void)endDownloadWithPath:(NSString*)path {
    if (finished) return;
    finished = YES;
    [session finishTasksAndInvalidate];
	isImporting = YES;
	[self updateProgress];
	
	[self retain];
	[delegate URLGetter:self returnedDownloadedFile:path];
	
	//clean up after ourselves
	NSFileManager *fileMan = [NSFileManager defaultManager];
	if (downloadPath) {
		[fileMan removeItemAtPath:downloadPath error:NULL];
		[downloadPath release];
		downloadPath = nil;
	}
	
	if (tempDirectory) {
		//only remove temporary directory if there's nothing in it
		if (![[fileMan contentsOfDirectoryAtPath:tempDirectory error:NULL] count])
			[fileMan removeItemAtPath:tempDirectory error:NULL];
		else
			NSLog(@"note removing %@ because it still contains files!", tempDirectory);
		[tempDirectory release];
		tempDirectory = nil;
	}
	
	[self stopProgressIndication];
	
	[self release];
}

- (NSString*)downloadPath {
	return downloadPath;
}

- (id)delegate {
	return delegate;
}
- (void)setDelegate:(id)aDelegate {
	delegate = aDelegate;
}

@end
