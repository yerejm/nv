//
//  TemporaryFileCachePreparer.m
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


#import "TemporaryFileCachePreparer.h"
#import "NotationPrefs.h"
#include <sys/mount.h>

static NSString *const ProtectedSpaceName = @"NVProtectedEditingSpace";
static NSString *const PlainSpaceName = @"NVPlainTextEditingSpace";
static const NSUInteger LargestProtectedNoteBytes = 8 * 1024 * 1024;
//editors that save atomically briefly need a second copy, and HFS+ needs room for its own structures
static const NSUInteger RAMDiskBytes = 2 * LargestProtectedNoteBytes + 4 * 1024 * 1024;

@implementation TemporaryFileCachePreparer

//mounting and detaching run in order on one queue, so a new disk is never mounted over one still being detached
static dispatch_queue_t EditingSpaceQueue(void) {
	static dispatch_queue_t queue;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ queue = dispatch_queue_create("net.notational.velocity.editing-space", DISPATCH_QUEUE_SERIAL); });
	return queue;
}

static NSString *RunTool(NSString *path, NSArray *arguments, int *status) {
	NSTask *task = [[NSTask alloc] init];
	NSPipe *output = [NSPipe pipe];
	[task setExecutableURL:[NSURL fileURLWithPath:path]];
	[task setArguments:arguments];
	[task setStandardOutput:output];
	[task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
	NSError *error = nil;
	if (![task launchAndReturnError:&error]) {
		NSLog(@"couldn't launch %@: %@", path, [error localizedDescription]);
		*status = -1;
		return nil;
	}
	NSData *data = [[output fileHandleForReading] readDataToEndOfFileAndReturnError:NULL];
	[task waitUntilExit];
	*status = [task terminationStatus];
	return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSString *DeviceMountedAt(NSString *path) {
	char resolved[PATH_MAX];
	if (!realpath([path fileSystemRepresentation], resolved)) return nil;
	struct statfs *mounts;
	int count = getmntinfo(&mounts, MNT_NOWAIT);
	for (int i = 0; i < count; i++) {
		if (!strcmp(resolved, mounts[i].f_mntonname)) return [NSString stringWithUTF8String:mounts[i].f_mntfromname];
	}
	return nil;
}

//the volume is mounted with mount(8), outside Disk Arbitration, so hdiutil cannot eject it until it is unmounted
static BOOL DetachDevice(NSString *device, NSString *mountPath) {
	int status = 0;
	if ([DeviceMountedAt(mountPath) isEqualToString:device]) {
		RunTool(@"/sbin/umount", @[mountPath], &status);
		if (status) RunTool(@"/sbin/umount", @[@"-f", mountPath], &status);
	}
	RunTool(@"/usr/bin/hdiutil", @[@"detach", device], &status);
	if (status) RunTool(@"/usr/bin/hdiutil", @[@"detach", @"-force", device], &status);
	if (status) NSLog(@"couldn't detach the editing RAM disk %@", device);
	return status == 0;
}

static BOOL CreatePrivateDirectory(NSString *path) {
	NSError *error = nil;
	NSDictionary *privateAccess = @{NSFilePosixPermissions: @0700};
	BOOL isDirectory = NO;
	NSFileManager *fileManager = [NSFileManager defaultManager];
	BOOL ready = [fileManager fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory ?
		[fileManager setAttributes:privateAccess ofItemAtPath:path error:&error] :
		[fileManager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:privateAccess error:&error];
	if (!ready) NSLog(@"couldn't create directory '%@': %@", path, [error localizedDescription]);
	return ready;
}

//returns the device of a newly mounted RAM disk, or nil after cleaning up a partial attempt
static NSString *MountRAMDisk(NSString *mountPath) {
	int status = 0;
	NSString *output = RunTool(@"/usr/bin/hdiutil", @[@"attach", @"-nomount", @"-nobrowse",
		[NSString stringWithFormat:@"ram://%lu", (unsigned long)(RAMDiskBytes / 512)]], &status);
	NSString *device = [[output componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] firstObject];
	if (status || ![device hasPrefix:@"/dev/"]) {
		NSLog(@"couldn't attach a RAM disk for editing");
		return nil;
	}
	RunTool(@"/sbin/newfs_hfs", @[@"-v", ProtectedSpaceName, device], &status);
	if (!status && CreatePrivateDirectory(mountPath)) {
		RunTool(@"/sbin/mount", @[@"-t", @"hfs", @"-o", @"nobrowse", device, mountPath], &status);
		//the new volume's root replaces the mount point's permissions
		if (!status && [DeviceMountedAt(mountPath) isEqualToString:device] && CreatePrivateDirectory(mountPath)) return device;
	}
	NSLog(@"couldn't prepare the editing RAM disk %@", device);
	DetachDevice(device, mountPath);
	return nil;
}

+ (NSUInteger)largestProtectedNoteLength {
	return LargestProtectedNoteBytes;
}

+ (void)removeStaleEditingSpacesInDirectory:(NSString*)aDirectory {
	NSString *mountPath = [aDirectory stringByAppendingPathComponent:ProtectedSpaceName];
	dispatch_sync(EditingSpaceQueue(), ^{
		NSString *device = DeviceMountedAt(mountPath);
		if (device) DetachDevice(device, mountPath);
	});
	NSFileManager *fileManager = [NSFileManager defaultManager];
	[fileManager removeItemAtPath:[aDirectory stringByAppendingPathComponent:PlainSpaceName] error:NULL];
	if (!DeviceMountedAt(mountPath)) [fileManager removeItemAtPath:mountPath error:NULL];
}

+ (void)alertNoteTooLarge {
	NVRunAlert(NSAlertStyleWarning, NSLocalizedString(@"This note is too large to edit in an external editor.", @"alert title when an encrypted note exceeds the protected editing space"),
			   NVFormatCount(NSLocalizedString(@"Encrypted notes are edited from a protected space in memory, which holds notes of up to %d MB.", @"alert message when an encrypted note exceeds the protected editing space"),
							 [self largestProtectedNoteLength] / (1024 * 1024)), NSLocalizedString(@"OK", nil), nil, nil);
}

+ (void)alertProtectedSpaceUnavailable {
	NVRunAlert(NSAlertStyleWarning, NSLocalizedString(@"The protected editing space could not be created.", @"alert title when the RAM disk for editing encrypted notes fails"),
			   NSLocalizedString(@"Encrypted notes are only edited externally from memory, so this note was not opened.", @"alert message when the RAM disk for editing encrypted notes fails"),
			   NSLocalizedString(@"OK", nil), nil, nil);
}

- (instancetype)initWithNotationPrefs:(NotationPrefs*)prefs {
	NSAssert(prefs != nil, @"prefs are nil");
	return [self initWithDirectory:NSTemporaryDirectory() protectsContents:[prefs notesStorageFormat] == SingleDatabaseFormat &&
			[prefs doesEncryption] && ![[NSUserDefaults standardUserDefaults] boolForKey:@"UseInsecureTempEditing"]];
}

- (instancetype)initWithDirectory:(NSString*)aDirectory protectsContents:(BOOL)protects {
	if ((self = [super init])) {
		directory = [aDirectory copy];
		protectsContents = protects;
		pendingCompletions = [[NSMutableArray alloc] init];
	}
	return self;
}

- (BOOL)protectsContents {
	return protectsContents;
}

- (BOOL)isPreparing {
	return preparing;
}

- (NSString*)preparedCachePath {
	return preparedCachePath;
}

- (NSString*)_spacePath {
	return [directory stringByAppendingPathComponent:protectsContents ? ProtectedSpaceName : PlainSpaceName];
}

- (void)prepareEditingSpace:(void (^)(NSString *path))completion {
	if (preparedCachePath) {
		completion(preparedCachePath);
		return;
	}
	if (!protectsContents) {
		if (CreatePrivateDirectory([self _spacePath])) preparedCachePath = [self _spacePath];
		completion(preparedCachePath);
		return;
	}
	[pendingCompletions addObject:[completion copy]];
	releaseRequested = NO;
	if (preparing) return;
	preparing = YES;
	NSString *mountPath = [self _spacePath];
	dispatch_async(EditingSpaceQueue(), ^{
		NSString *device = MountRAMDisk(mountPath);
		dispatch_async(dispatch_get_main_queue(), ^{
			[self _finishPreparationWithDevice:device];
		});
	});
}

- (void)_finishPreparationWithDevice:(NSString*)device {
	preparing = NO;
	if (releaseRequested) {
		//edits requested before the release are abandoned along with the space
		[pendingCompletions removeAllObjects];
		NSString *mountPath = [self _spacePath];
		if (device) dispatch_async(EditingSpaceQueue(), ^{
			if (DetachDevice(device, mountPath)) [[NSFileManager defaultManager] removeItemAtPath:mountPath error:NULL];
		});
		return;
	}
	if (device) {
		deviceName = [device copy];
		preparedCachePath = [self _spacePath];
	}
	NSArray *completions = [pendingCompletions copy];
	[pendingCompletions removeAllObjects];
	for (void (^completion)(NSString *) in completions) completion(preparedCachePath);
}

- (void)releaseEditingSpaceWaiting:(BOOL)wait {
	if (preparing) releaseRequested = YES;
	preparedCachePath = nil;
	if (!protectsContents) {
		[[NSFileManager defaultManager] removeItemAtPath:[self _spacePath] error:NULL];
		return;
	}
	NSString *device = deviceName;
	deviceName = nil;
	NSString *mountPath = [self _spacePath];
	//with no disk of its own, waiting still lets an abandoned preparation finish detaching
	void (^detach)(void) = ^{
		if (device && DetachDevice(device, mountPath)) [[NSFileManager defaultManager] removeItemAtPath:mountPath error:NULL];
	};
	if (wait) dispatch_sync(EditingSpaceQueue(), detach);
	else dispatch_async(EditingSpaceQueue(), detach);
}

@end
