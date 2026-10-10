#import <XCTest/XCTest.h>
#import "TemporaryFileCachePreparer.h"
#include <sys/mount.h>
#include <sys/stat.h>

@interface EditingSpaceTests : XCTestCase {
    NSString *root;
}
@end
@implementation EditingSpaceTests
- (void)setUp {
    root = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
}
- (void)tearDown {
    [TemporaryFileCachePreparer removeStaleEditingSpacesInDirectory:root];
    [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
    root = nil;
}
- (NSString *)preparedPathOf:(TemporaryFileCachePreparer *)preparer {
    __block NSString *prepared = nil;
    XCTestExpectation *done = [self expectationWithDescription:@"prepared"];
    [preparer prepareEditingSpace:^(NSString *path) {
        prepared = [path copy];
        [done fulfill];
    }];
    [self waitForExpectations:@[done] timeout:20];
    return prepared;
}
static BOOL IsHFSMountAt(NSString *path) {
    struct statfs volume;
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) && statfs(resolved, &volume) == 0 &&
        !strcmp(volume.f_mntonname, resolved) && !strcmp(volume.f_fstypename, "hfs");
}
static mode_t PermissionsOf(NSString *path) {
    struct stat info;
    return stat(path.fileSystemRepresentation, &info) == 0 ? info.st_mode & 0777 : 0;
}
- (void)testProtectedSpaceIsMountedOnlyWhenNeededAndDetachedOnRelease {
    TemporaryFileCachePreparer *preparer = [[TemporaryFileCachePreparer alloc] initWithDirectory:root protectsContents:YES];
    NSString *expected = [root stringByAppendingPathComponent:@"NVProtectedEditingSpace"];
    XCTAssertNil(preparer.preparedCachePath);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:expected]);
    NSString *path = [self preparedPathOf:preparer];
    XCTAssertEqualObjects(path, expected);
    XCTAssertTrue(IsHFSMountAt(path));
    XCTAssertEqual(PermissionsOf(path), (mode_t)0700);
    NSData *note = [NSMutableData dataWithLength:[TemporaryFileCachePreparer largestProtectedNoteLength]];
    XCTAssertTrue([note writeToFile:[path stringByAppendingPathComponent:@"first.txt"] atomically:NO]);
    XCTAssertTrue([note writeToFile:[path stringByAppendingPathComponent:@"atomic save.txt"] atomically:NO]);
    XCTAssertEqualObjects([self preparedPathOf:preparer], path);
    [preparer releaseEditingSpaceWaiting:YES];
    XCTAssertNil(preparer.preparedCachePath);
    XCTAssertFalse(IsHFSMountAt(path));
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
}
- (void)testReleaseDuringPreparationAbandonsTheSpace {
    TemporaryFileCachePreparer *preparer = [[TemporaryFileCachePreparer alloc] initWithDirectory:root protectsContents:YES];
    __block BOOL completed = NO;
    [preparer prepareEditingSpace:^(NSString *path) { completed = YES; }];
    XCTAssertTrue(preparer.isPreparing);
    [preparer releaseEditingSpaceWaiting:NO];
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:20];
    while (preparer.isPreparing && limit.timeIntervalSinceNow > 0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    [preparer releaseEditingSpaceWaiting:YES];
    XCTAssertFalse(completed);
    XCTAssertNil(preparer.preparedCachePath);
    XCTAssertFalse(IsHFSMountAt([root stringByAppendingPathComponent:@"NVProtectedEditingSpace"]));
}
- (void)testSpacesLeftByACrashAreRemoved {
    TemporaryFileCachePreparer *crashed = [[TemporaryFileCachePreparer alloc] initWithDirectory:root protectsContents:YES];
    NSString *protectedPath = [self preparedPathOf:crashed];
    TemporaryFileCachePreparer *plain = [[TemporaryFileCachePreparer alloc] initWithDirectory:root protectsContents:NO];
    NSString *plainPath = [self preparedPathOf:plain];
    XCTAssertTrue([@"left behind" writeToFile:[plainPath stringByAppendingPathComponent:@"note.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL]);
    [TemporaryFileCachePreparer removeStaleEditingSpacesInDirectory:root];
    XCTAssertFalse(IsHFSMountAt(protectedPath));
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:protectedPath]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:plainPath]);
}
- (void)testPlainSpaceIsPrivateAndRemovedOnRelease {
    TemporaryFileCachePreparer *preparer = [[TemporaryFileCachePreparer alloc] initWithDirectory:root protectsContents:NO];
    NSString *path = [self preparedPathOf:preparer];
    XCTAssertEqualObjects(path, [root stringByAppendingPathComponent:@"NVPlainTextEditingSpace"]);
    XCTAssertFalse(IsHFSMountAt(path));
    XCTAssertEqual(PermissionsOf(path), (mode_t)0700);
    [preparer releaseEditingSpaceWaiting:YES];
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:path]);
}
@end
