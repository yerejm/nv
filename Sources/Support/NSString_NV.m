//
//  NSString_NV.m
//  Notation
//
//  Created by Zachary Schneirov on 1/13/06.

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

#import "NSString_NV.h"
#import "NSData_transformations.h"
#import "NSFileManager_NV.h"
#import "NoteObject.h"
#import "GlobalPrefs.h"
#import "LabelObject.h"

@implementation NSString (NV)

static int dayFromAbsoluteTime(CFAbsoluteTime absTime);

enum {NoSpecialDay = -1, ThisDay = 0, NextDay = 1, PriorDay = 2};

static const double dayInSeconds = 86400.0;
static CFTimeInterval secondsAfterGMT = 0.0;
static int currentDay = 0;
static CFMutableDictionaryRef dateStringsCache = NULL;
static CFDateFormatterRef dateAndTimeFormatter = NULL;

unsigned int hoursFromAbsoluteTime(CFAbsoluteTime absTime) {
	return (unsigned int)floor(absTime / 3600.0);
}

//should be called after midnight, and then all the notes should have their date-strings recomputed
void resetCurrentDayTime(void) {
    CFAbsoluteTime current = CFAbsoluteTimeGetCurrent();
    
    CFTimeZoneRef timeZone = CFTimeZoneCopyDefault();
    secondsAfterGMT = CFTimeZoneGetSecondsFromGMT(timeZone, current);
    
    currentDay = (int)floor((current + secondsAfterGMT) / dayInSeconds); // * dayInSeconds - secondsAfterGMT;
	
	if (dateStringsCache)
		CFDictionaryRemoveAllValues(dateStringsCache);
	
	if (dateAndTimeFormatter) {
		CFRelease(dateAndTimeFormatter);
		dateAndTimeFormatter = NULL;
	}
		
	CFRelease(timeZone);
}
//the epoch is defined at midnight GMT, so we have to convert from GMT to find the days

static int dayFromAbsoluteTime(CFAbsoluteTime absTime) {
    if (currentDay == 0)
	resetCurrentDayTime();
    
    int timeDay = (int)floor((absTime + secondsAfterGMT) / dayInSeconds); // * dayInSeconds - secondsAfterGMT;
    if (timeDay == currentDay) {
	return ThisDay;
    } else if (timeDay == currentDay + 1 /*dayInSeconds*/) {
	return NextDay;
    } else if (timeDay == currentDay - 1 /*dayInSeconds*/) {
	return PriorDay;
    }
    
    return NoSpecialDay;
}

+ (NSString*)relativeTimeStringWithDate:(CFDateRef)date relativeDay:(int)day {
    static CFDateFormatterRef timeOnlyFormatter = nil;
    static NSString *days[3] = { NULL };
    
    if (!timeOnlyFormatter) {
		timeOnlyFormatter = CFDateFormatterCreate(kCFAllocatorDefault, (__bridge CFLocaleRef)[NSLocale currentLocale], kCFDateFormatterNoStyle, kCFDateFormatterShortStyle);
    }
    
    if (!days[ThisDay]) {
		days[ThisDay] = NSLocalizedString(@"Today", nil);
		days[NextDay] = NSLocalizedString(@"Tomorrow", nil);
		days[PriorDay] = NSLocalizedString(@"Yesterday", nil);
    }

    NSString *dateString = CFBridgingRelease(CFDateFormatterCreateStringWithDate(kCFAllocatorDefault, timeOnlyFormatter, date));
	
	if ([[GlobalPrefs defaultPrefs] horizontalLayout]) {
		//if today, return the time only; otherwise say "Yesterday", etc.; and this method shouldn't be called unless day != NoSpecialDay
		if (day == PriorDay || day == NextDay)
			return days[day];
		return dateString;
	}
    
	return [days[day] stringByAppendingFormat:@"  %@", dateString];
}

//take into account yesterday/today thing
//this method _will_ affect application launch time
+ (NSString*)relativeDateStringWithAbsoluteTime:(CFAbsoluteTime)absTime {
	if (!dateStringsCache) {
		CFDictionaryKeyCallBacks keyCallbacks = { kCFTypeDictionaryKeyCallBacks.version, (CFDictionaryRetainCallBack)NULL, (CFDictionaryReleaseCallBack)NULL, 
			(CFDictionaryCopyDescriptionCallBack)NULL, (CFDictionaryEqualCallBack)NULL, (CFDictionaryHashCallBack)NULL };
		dateStringsCache = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &keyCallbacks, &kCFTypeDictionaryValueCallBacks);
	}
	NSInteger minutesCount = (NSInteger)((NSInteger)absTime / 60);
	
	NSString *dateString = (__bridge NSString*)CFDictionaryGetValue(dateStringsCache, (const void *)minutesCount);
	
	if (!dateString) {
		int day = dayFromAbsoluteTime(absTime);
		
		if (!dateAndTimeFormatter) {
			BOOL horiz = [[GlobalPrefs defaultPrefs] horizontalLayout];
			dateAndTimeFormatter = CFDateFormatterCreate(kCFAllocatorDefault, (__bridge CFLocaleRef)[NSLocale currentLocale], 
														 horiz ? kCFDateFormatterShortStyle : kCFDateFormatterMediumStyle, 
														 horiz ? kCFDateFormatterNoStyle : kCFDateFormatterShortStyle);
		}
		
		CFDateRef date = CFDateCreate(kCFAllocatorDefault, absTime);
		
		if (day == NoSpecialDay) {
			dateString = CFBridgingRelease(CFDateFormatterCreateStringWithDate(kCFAllocatorDefault, dateAndTimeFormatter, date));
		} else {
			dateString = [NSString relativeTimeStringWithDate:date relativeDay:day];
		}
		
		CFRelease(date);
		
		//ints as pointers ints as pointers ints as pointers
		CFDictionarySetValue(dateStringsCache, (const void *)minutesCount, (__bridge const void *)dateString);
	}
	
    return dateString;
}

- (NSArray*)labelCompatibleWords {
	NSArray *array = [self componentsSeparatedByCharactersInSet:[NSCharacterSet labelSeparatorCharacterSet]];
	NSMutableArray *titles = [NSMutableArray arrayWithCapacity:[array count]];
	
	NSUInteger i;
	for (i=0; i<[array count]; i++) {
		NSString *aWord = [array objectAtIndex:i];
		if ([aWord length] > 0) {
			[titles addObject:aWord];
		}
	}
	return titles;
}

+ (NSString*)customPasteboardTypeOfCode:(int)code {
	//returns something like CorePasteboardFlavorType 0x4D5A0003
	return [NSString stringWithFormat:@"CorePasteboardFlavorType 0x%X", code];
}

- (NSString*)stringAsSafePathExtension {
	return [self stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"./*: \t\n\r"]];
}

- (NSString*)filenameExpectingAdditionalCharCount:(NSInteger)charCount {
	NSString *newfilename = self;
	if ([self length] + charCount > 255)
		newfilename = [self substringToIndex: 255 - charCount];

	return newfilename;
}

- (BOOL)isAMachineDirective {
	return [self hasPrefix:@"#!"] || [self hasPrefix:@"#import "] || [self hasPrefix:@"#include "] || 
	[self hasPrefix:@"<!DOCTYPE "] || [self hasPrefix:@"<?xml "] || [self hasPrefix:@"<html "] || 
	[self hasPrefix:@"@import "] || [self hasPrefix:@"<?php"] || [self hasPrefix:@"bplist0"]; 
	
}

- (NSString*)fourCharTypeString {
	if ([[self dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES] length] >= 4) {
		//only truncate; don't return a string containing null characters for the last few bytes
		OSType type = NVOSTypeFromString((__bridge CFStringRef)self);
		return CFBridgingRelease(NVStringFromOSType(type));
	}
	return self;
}

- (BOOL)superficiallyResemblesAnHTTPURL {
	//has the right protocol and contains no whitespace or line breaks
	
	return ([self rangeOfString:@"http" options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound ||
			[self rangeOfString:@"https" options:NSCaseInsensitiveSearch | NSAnchoredSearch].location != NSNotFound) &&
	[self rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] options:NSLiteralSearch].location == NSNotFound;
}

- (void)copyItemToPasteboard:(id)sender {
	
	NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard declareTypes:@[NSPasteboardTypeString] owner:nil];
	[pasteboard setString:[sender isKindOfClass:[NSMenuItem class]] ? [sender representedObject] : self
				  forType:NSPasteboardTypeString];
}


- (NSString*)syntheticTitleAndSeparatorWithContext:(NSString**)sepStr bodyLoc:(NSUInteger*)bodyLoc maxTitleLen:(NSUInteger)maxTitleLen {
	return [self syntheticTitleAndSeparatorWithContext:sepStr bodyLoc:bodyLoc oldTitle:nil maxTitleLen:maxTitleLen];
}

- (NSString*)syntheticTitleAndSeparatorWithContext:(NSString**)sepStr bodyLoc:(NSUInteger*)bodyLoc 
										  oldTitle:(NSString*)oldTitle maxTitleLen:(NSUInteger)maxTitleLen {
	
	//break string into pieces for turning into a note
	//find the first line, whitespace or no whitespace
	
	NSCharacterSet *titleDelimiters = [NSCharacterSet characterSetWithCharactersInString:
											  [NSString stringWithFormat:@"\n\r\t%C%C", (unichar)NSLineSeparatorCharacter, (unichar)NSParagraphSeparatorCharacter]];
	
	NSScanner *scanner = [NSScanner scannerWithString:self];
	[scanner setCharactersToBeSkipped:[[NSMutableCharacterSet alloc] init]];
	
	//skip any blank space before the title; this will not be preserved for round-tripped syncing
	BOOL didSkipInitialWS = [scanner scanCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:NULL];
	
	if ([oldTitle length] > maxTitleLen) {
		//break apart the string based on an existing title (if it still matches) that would have been longer than our default truncation limit
		
		NSString *contentStartStr = didSkipInitialWS && [scanner scanLocation] < [self length] ? [self substringFromIndex:[scanner scanLocation]] : self;
		if ([contentStartStr length] >= [oldTitle length] && [contentStartStr hasPrefix:oldTitle]) {
			
			[scanner setScanLocation:[oldTitle length] + (didSkipInitialWS ? [scanner scanLocation] : 0)];
			[scanner scanContextualSeparator:sepStr withPrecedingString:oldTitle];
			if (bodyLoc) *bodyLoc = [scanner scanLocation];
			return oldTitle;
		}
	}
	
	//grab the title
	NSString *firstLine = nil;
	[scanner scanUpToCharactersFromSet:titleDelimiters intoString:&firstLine];
	
	if ([firstLine length] > maxTitleLen) {
		//what if this title is too long? then we need to break it up and start the body after that
		NSRange lastSpaceInFirstLine = [firstLine rangeOfString:@" " options: NSBackwardsSearch | NSLiteralSearch
														  range:NSMakeRange(maxTitleLen - 10, 10)];
		if (lastSpaceInFirstLine.location == NSNotFound) {
			lastSpaceInFirstLine.location = maxTitleLen;
		}
		[scanner setScanLocation:[scanner scanLocation] - ([firstLine length] - lastSpaceInFirstLine.location)];
		firstLine = [firstLine substringToIndex:lastSpaceInFirstLine.location];
		
		[scanner scanContextualSeparator:sepStr withPrecedingString:firstLine];		
		if (bodyLoc) *bodyLoc = [scanner scanLocation];
		return firstLine;
	}
	
	//grab blank space between the title and the body; common case:
	[scanner scanContextualSeparator:sepStr withPrecedingString:firstLine];
	if (bodyLoc) *bodyLoc = [scanner scanLocation];
	
	return [firstLine length] ? firstLine : NSLocalizedString(@"Untitled Note", @"Title of a nameless note");
}

- (NSString*)syntheticTitleAndTrimmedBody:(NSString**)newBody {
	NSUInteger bodyLoc = 0;
	NSString *title = [self syntheticTitleAndSeparatorWithContext:NULL bodyLoc:&bodyLoc maxTitleLen:60];
	if (newBody) *newBody = [self substringFromIndex:bodyLoc];
	return title;
}

//the following three methods + function come courtesy of Mike Ferris' TextExtras
+ (NSString *)tabbifiedStringWithNumberOfSpaces:(NSUInteger)origNumSpaces tabWidth:(NSUInteger)tabWidth usesTabs:(BOOL)usesTabs {
	static NSMutableString *sharedString = nil;
	static NSUInteger numTabs = 0;
    static NSUInteger numSpaces = 0;
	
    NSInteger diffInTabs;
    NSInteger diffInSpaces;
	
    // TabWidth of 0 means don't use tabs!
    if (!usesTabs || (tabWidth == 0)) {
        diffInTabs = 0 - numTabs;
        diffInSpaces = origNumSpaces - numSpaces;
    } else {
        diffInTabs = (origNumSpaces / tabWidth) - numTabs;
        diffInSpaces = (origNumSpaces % tabWidth) - numSpaces;
    }
    
    if (!sharedString) {
        sharedString = [[NSMutableString alloc] init];
    }
    
    if (diffInTabs < 0) {
        [sharedString deleteCharactersInRange:NSMakeRange(0, -diffInTabs)];
    } else {
        NSUInteger numToInsert = diffInTabs;
        while (numToInsert > 0) {
            [sharedString replaceCharactersInRange:NSMakeRange(0, 0) withString:@"\t"];
            numToInsert--;
        }
    }
    numTabs += diffInTabs;
	
    if (diffInSpaces < 0) {
        [sharedString deleteCharactersInRange:NSMakeRange(numTabs, -diffInSpaces)];
    } else {
        NSUInteger numToInsert = diffInSpaces;
        while (numToInsert > 0) {
            [sharedString replaceCharactersInRange:NSMakeRange(numTabs, 0) withString:@" "];
            numToInsert--;
        }
    }
    numSpaces += diffInSpaces;
	
	
    return sharedString;
}

- (NSUInteger)numberOfLeadingSpacesFromRange:(NSRange*)range tabWidth:(NSUInteger)tabWidth {
    // Returns number of spaces, accounting for expanding tabs.
    NSRange searchRange = (range ? *range : NSMakeRange(0, [self length]));
    unichar buff[100];
    unsigned i = 0;
    NSUInteger spaceCount = 0;
    BOOL done = NO;
    NSUInteger tabW = tabWidth;
    NSUInteger endOfWhiteSpaceIndex = NSNotFound;
	
    if (!range || range->length == 0) {
        return 0;
    }
    
    while ((searchRange.length > 0) && !done) {
        [self getCharacters:buff range:NSMakeRange(searchRange.location, ((searchRange.length > 100) ? 100 : searchRange.length))];
        for (i=0; i < ((searchRange.length > 100) ? 100 : searchRange.length); i++) {
            if (buff[i] == (unichar)' ') {
                spaceCount++;
            } else if (buff[i] == (unichar)'\t') {
                // MF:!!! Perhaps this should account for the case of 2 spaces follwed by a tab really being visually equivalent to 8 spaces (for 8 space tabs) and not 10 spaces.
                spaceCount += tabW;
            } else {
                done = YES;
                endOfWhiteSpaceIndex = searchRange.location + i;
                break;
            }
        }
        searchRange.location += ((searchRange.length > 100) ? 100 : searchRange.length);
        searchRange.length -= ((searchRange.length > 100) ? 100 : searchRange.length);
    }
    if (range && (endOfWhiteSpaceIndex != NSNotFound)) {
        range->length = endOfWhiteSpaceIndex - range->location;
    }
    return spaceCount;
}

BOOL IsHardLineBreakUnichar(unichar uchar, NSString *str, unsigned charIndex) {
    // This function redundantly takes both the character and the string and index.  This is because often we only have to look at that one character and usually we already have it when this is called (usually from a source cheaper than characterAtIndex: too.)
    // Returns yes if the unichar given is a hard line break, that is it will always cause a new line fragment to begin.
    // MF:??? Is this test complete?
    if ((uchar == (unichar)'\n') || (uchar == NSParagraphSeparatorCharacter) || (uchar == NSLineSeparatorCharacter)) {
        return YES;
    } else if ((uchar == (unichar)'\r') && ((charIndex + 1 >= [str length]) || ([str characterAtIndex:charIndex + 1] != (unichar)'\n'))) {
        return YES;
    }
    return NO;
}

- (char*)copyLowercaseASCIIString {
	
	const char *cstringPtr = NULL;
	
	//here we are making assumptions (based on observations and CFString.c) about the implementation of CFStringGetCStringPtr:
	//with a non-western language preference, kCFStringEncodingASCII or another Latin variant must be used instead of kCFStringEncodingMacRoman
	if ((cstringPtr = CFStringGetCStringPtr((__bridge CFStringRef)self, kCFStringEncodingMacRoman)) ||
		(cstringPtr = CFStringGetCStringPtr((__bridge CFStringRef)self, kCFStringEncodingASCII))) {
		
		size_t length = [self length];
		char *cstringBuffer = (char*)malloc(length + 1);
		//modp will add the NULL terminator
		modp_tolower_copy(cstringBuffer, cstringPtr, length);
		
		return cstringBuffer;
	} else {
		//will be true on Snow Leopard for empty strings
	}
	
	return NULL;
}

- (const char*)lowercaseUTF8String {
	
	//the returned C string may point into this copy, so it lives until the autorelease pool drains
	CFMutableStringRef str2 = (CFMutableStringRef)CFAutorelease(CFStringCreateMutableCopy(NULL, 0, (__bridge CFStringRef)self));
	CFStringLowercase(str2, NULL);
	
	const char *utf8String = [(__bridge NSString*)str2 UTF8String];
	
	if (!utf8String) {
		
		CFStringEncoding encoding = CFStringGetFastestEncoding(str2);
		const char *cStrPtr = CFStringGetCStringPtr(str2, encoding);
		
		if (cStrPtr && (kCFStringEncodingUTF8 == encoding || (encoding & 0x0100) == 0)) {
			//-UTF8String failed, but the native cstringptr worked and was not a UTF16+ encoding
			//so return that instead, forfeiting upper-ascii searchability for now
			//(for whatever reason, native string encoding is almost never kCFStringEncodingUTF8, so CFStringGetFastestEncoding is called only if necessary)
			utf8String = cStrPtr;
			
		} else {
			//-UTF8String failed and CFStringGetCStringPtr was not a good fallback; try lossy MacOSRoman and pray
			NSMutableData *nullTerminatedData = [[(__bridge NSString*)str2 dataUsingEncoding:NSMacOSRomanStringEncoding allowLossyConversion:YES] mutableCopy];
			[nullTerminatedData appendBytes:"\0" length:1];
			utf8String = [nullTerminatedData bytes];
		}
	}
	return utf8String;
}

- (NSString *)stringByReplacingPercentEscapes {
    return CFBridgingRelease(CFURLCreateStringByReplacingPercentEscapes(NULL, (__bridge CFStringRef)self, CFSTR("")));
}

- (NSString*)stringWithPercentEscapes {
    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"=,!$&'()*+;@?\n\"<>#\t :/"];
    return [self stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

+ (NSString*)reasonStringFromCarbonFSError:(OSStatus)err {
	static NSDictionary *reasons = nil;
	if (!reasons) {
		NSURL *url = [[NSBundle mainBundle] URLForResource:@"CarbonErrorStrings" withExtension:@"plist"];
		if (url) reasons = [NSDictionary dictionaryWithContentsOfURL:url error:NULL];
	}
	
	NSString *reason = [reasons objectForKey:[@((int)err) stringValue]];
	if (!reason)
		return [NSString stringWithFormat:NSLocalizedString(@"an error of type %d occurred", @"string of last resort for errors not found in CarbonErrorStrings"), (int)err];
	return reason;
}

- (BOOL)UTIOfFileConformsToType:(NSString *)identifier {
    UTType *type = nil;
    [[NSURL fileURLWithPath:self] getResourceValue:&type forKey:NSURLContentTypeKey error:NULL];
    return [type conformsToType:[UTType typeWithIdentifier:identifier]];
}

- (CFUUIDBytes)uuidBytes {
	CFUUIDBytes bytes = {0};
	CFUUIDRef uuidRef = CFUUIDCreateFromString(NULL, (__bridge CFStringRef)self);
	if (uuidRef) {
		bytes = CFUUIDGetUUIDBytes(uuidRef);
		CFRelease(uuidRef);
	}

	return bytes;
}

+ (NSString*)uuidStringWithBytes:(CFUUIDBytes)bytes {
	CFUUIDRef uuidRef = CFUUIDCreateFromUUIDBytes(NULL, bytes);
	CFStringRef uuidString = NULL;
	
	if (uuidRef) {
		uuidString = CFUUIDCreateString(NULL, uuidRef);
		CFRelease(uuidRef);
	}
	
	return CFBridgingRelease(uuidString);
}


- (NSData *)decodeBase64 {
    return [self decodeBase64WithNewlines:YES];
}

- (NSData *)decodeBase64WithNewlines:(BOOL)encodedWithNewlines {
    NSDataBase64DecodingOptions options = encodedWithNewlines ? NSDataBase64DecodingIgnoreUnknownCharacters : 0;
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:self options:options];
    return decoded ? [NSMutableData dataWithData:decoded] : [NSMutableData data];
}

@end


@implementation NSMutableString (NV)

+ (NSMutableString*)newShortLivedStringFromFile:(NSString*)filename {
	NSStringEncoding anEncoding = NSMacOSRomanStringEncoding; //won't use this, doesn't matter
	
	return [self newShortLivedStringFromData:[NSMutableData dataWithContentsOfFile:filename options:NSDataReadingUncached error:NULL] 
						   ofGuessedEncoding:&anEncoding withPath:[filename fileSystemRepresentation] orWithFSRef:NULL];
}

+ (NSMutableString*)newShortLivedStringFromData:(NSMutableData*)data ofGuessedEncoding:(NSStringEncoding*)encoding withPath:(const char*)aPath orWithFSRef:(const NVFileReference*)fsRef{
	//this will fail if data lacks a BOM, but try it first as it's the fastest check
	NSMutableString* stringFromData = [data newStringUsingBOMReturningEncoding:encoding];
	if (stringFromData) {
		return stringFromData;
	}
	
	//TODO: there are some false positives for UTF-8 detection; e.g., the MacOSRoman-encoded copyright symbol
	
	//if it's just 7-bit ASCII, jump straight to the fastest encoding; don't even try UTF-8 (but report UTF-8, anyway)
	BOOL hasHighASCII = ContainsHighAscii([data bytes], [data length]);
	CFStringEncoding cfasciiEncoding = CFStringGetSystemEncoding() == kCFStringEncodingMacRoman ? kCFStringEncodingMacRoman : kCFStringEncodingASCII;
	NSStringEncoding firstEncodingToTry = hasHighASCII ? NSUTF8StringEncoding : CFStringConvertEncodingToNSStringEncoding(cfasciiEncoding);
	
#define AddIfUnique(enc) if (!ContainsUInteger(encodingsToTry, encodingIndex, (enc))) encodingsToTry[encodingIndex++] = (enc)
	
	NSStringEncoding encodingsToTry[5];
	NSUInteger encodingIndex = 0;
	
	AddIfUnique(firstEncodingToTry);
	
	if (hasHighASCII) {
		//check the file on disk for extended attributes only if absolutely necessary
		NSStringEncoding extendedAttrsEncoding = 0;
		if (!aPath && fsRef && !IsZeros(fsRef, sizeof(NVFileReference))) {
			NSMutableData *pathData = [NSMutableData dataWithLength:4 * 1024];
			if (NVReferenceMakePath(fsRef, [pathData mutableBytes], [pathData length]) == noErr)
				extendedAttrsEncoding = [[NSFileManager defaultManager] textEncodingAttributeOfFSPath:[pathData bytes]];
		} else if (aPath) {
			extendedAttrsEncoding = [[NSFileManager defaultManager] textEncodingAttributeOfFSPath:aPath];
		}
		if (extendedAttrsEncoding) AddIfUnique(extendedAttrsEncoding);
	}
	AddIfUnique(*encoding);
	NSStringEncoding systemEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringGetSystemEncoding());
	AddIfUnique(systemEncoding);
	AddIfUnique(NSMacOSRomanStringEncoding);
	
	NSUInteger encodingCount = encodingIndex;
	for (encodingIndex = 0; encodingIndex < encodingCount; encodingIndex++) {
		stringFromData = [[NSMutableString alloc] initWithBytesNoCopy:[data mutableBytes] length:[data length] 
															 encoding:encodingsToTry[encodingIndex] freeWhenDone:NO];
		if (stringFromData) break;
	}
		
	if (stringFromData) {
		NSAssert(encodingIndex < encodingCount, @"got valid string from data, but encodingIndex is too high!");
		//report ASCII files as UTF-8 data in case this encoding will be used for future writes of a note
		*encoding = hasHighASCII ? encodingsToTry[encodingIndex] : NSUTF8StringEncoding;
		return stringFromData;
	}
		
	return nil;
}

@end

@implementation NSScanner (NV)

//useful for -syntheticTitleAndSeparatorWithContext:bodyLoc:oldTitle:
- (void)scanContextualSeparator:(NSString**)sepStr withPrecedingString:(NSString*)firstLine {
	
	if (![firstLine length]) {
		//no initial preceding string, so context won't make sense
		if (sepStr) *sepStr = @"";
		return;
	}
	NSUInteger len = [[self string] length];
	if ([self scanCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:sepStr]) {
		if (sepStr && *sepStr) {
			if ([self scanLocation] >= len) goto noBody;
			//typical case
			*sepStr = [NSString stringWithFormat:@"%C%@%C", [firstLine characterAtIndex:[firstLine length] - 1], *sepStr, 
					   [[self string] characterAtIndex:[self scanLocation]]];
		}
	} else if (sepStr) {
		//is this the end of the string, or was the scanner's location previously somewhere in the middle?
		if ([self scanLocation] >= len) {
		noBody: //all one line
			*sepStr = @"";
		} else {
			//middle of the "title", probably because it is too long; grab the two surrounding characters
			*sepStr = [NSString stringWithFormat:@"%C%C", [firstLine characterAtIndex:[firstLine length] - 1], 
					   [[self string] characterAtIndex:[self scanLocation]]];
		}
	}
	
	//location of _following_ string (usually the body of a note) will now be [self scanLocation]
}


@end

@implementation NSCharacterSet (NV)

+ (NSCharacterSet*)labelSeparatorCharacterSet {
	static NSMutableCharacterSet *charSet = nil;
	if (!charSet) {
		charSet = [NSMutableCharacterSet whitespaceCharacterSet];
		[charSet formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@",;"]];
	}

	return charSet;
}

+ (NSCharacterSet*)listBulletsCharacterSet {
	static NSCharacterSet *charSet = nil;
	if (!charSet) {
		charSet = [NSCharacterSet characterSetWithCharactersInString:[NSString stringWithFormat:@"-+*!#%C%C%C%C%C%C%C", 
																	   0x2022, 0x2014, 0x2013, 0x2043, 0x2713, 0x25AA, 0x25C6]];
	}
	
	return charSet;
	
}

@end



@implementation NSEvent (NV)

- (unichar)firstCharacter {
	NSString *chars = [self characters];
	if ([chars length]) return [chars characterAtIndex:0];
	return USHRT_MAX;
}

- (unichar)firstCharacterIgnoringModifiers {
	NSString *chars = [self charactersIgnoringModifiers];
	if ([chars length]) return [chars characterAtIndex:0];
	return USHRT_MAX;
}

@end
