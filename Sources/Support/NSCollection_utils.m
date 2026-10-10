//
//  NSCollection_utils.m
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


#import "NSCollection_utils.h"
#import "AttributedPlainText.h"
#import "NSString_NV.h"
#import "NSFileManager_NV.h"
#import "NoteObject.h"
#import "BufferUtils.h"

@implementation NSDictionary (FontTraits)

- (BOOL)attributesHaveFontTrait:(NSFontTraitMask)desiredTrait orAttribute:(NSString*)attrName {
	if ([self objectForKey:attrName])
		return YES;
	NSFont *font = [self objectForKey:NSFontAttributeName];
	if (font) {
		NSFontTraitMask traits = [[NSFontManager sharedFontManager] traitsOfFont:font];
		return traits & desiredTrait;
	}
	
	return NO;
	
}

@end

@implementation NSMutableDictionary (FontTraits)

- (void)addDesiredAttributesFromDictionary:(NSDictionary*)dict {
	id strikethroughStyle = [dict objectForKey:NSStrikethroughStyleAttributeName];
	id hiddenDoneTagStyle = [dict objectForKey:NVHiddenDoneTagAttributeName];
	id strokeWidthStyle = [dict objectForKey:NSStrokeWidthAttributeName];
	id obliquenessStyle = [dict objectForKey:NSObliquenessAttributeName];
	id linkStyle = [dict objectForKey:NSLinkAttributeName];
	
	if (linkStyle)
		[self setObject:linkStyle forKey:NSLinkAttributeName];
	if (strikethroughStyle)
		[self setObject:@(NSUnderlineStyleSingle) forKey:NSStrikethroughStyleAttributeName];
	if (strokeWidthStyle)
		[self setObject:strokeWidthStyle forKey:NSStrokeWidthAttributeName];
	if (obliquenessStyle)
		[self setObject:obliquenessStyle forKey:NSObliquenessAttributeName];
	if (hiddenDoneTagStyle)
		[self setObject:hiddenDoneTagStyle forKey:NVHiddenDoneTagAttributeName];
}

- (void)applyStyleInverted:(BOOL)opposite trait:(NSFontTraitMask)trait forFont:(NSFont*)font 
	alternateAttributeName:(NSString*)attrName alternateAttributeValue:(id)value {
	
	NSFontManager *fontMan = [NSFontManager sharedFontManager];
	
	if (opposite) {
		font = [fontMan convertFont:font toNotHaveTrait:trait];	
		[self removeObjectForKey:attrName];
	} else {
		font = [fontMan convertFont:font toHaveTrait:trait];
		NSFontTraitMask newTraits = [fontMan traitsOfFont:font];
		
		if (!(newTraits & trait)) {
			[self setObject:value forKey:attrName];
		} else {
			[self removeObjectForKey:attrName];
		}
	}
	[self setObject:font forKey:NSFontAttributeName];
}

@end

@implementation NSDictionary (HTTP)

+ (NSDictionary*)optionsDictionaryWithTimeout:(float)timeout {
	return @{NSTimeoutDocumentOption: @(timeout)};
}

- (NSString*)URLEncodedString {
	
	NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:[self count]];
	
	NSEnumerator *enumerator = [self keyEnumerator];
	NSString *aKey = nil;
	while ((aKey = [enumerator nextObject])) {
		[pairs addObject:[NSString stringWithFormat: @"%@=%@", 
						  [aKey stringWithPercentEscapes], [[self objectForKey:aKey] stringWithPercentEscapes]]];
		
	}
	return [pairs componentsJoinedByString:@"&"];
}


@end



@implementation NSSet (Utilities)

- (NSMutableSet*)setIntersectedWithSet:(NSSet*)set {
    NSMutableSet *existingItems = [NSMutableSet setWithSet:self];
    [existingItems intersectSet:set];
   
    return existingItems;
}

@end

@implementation NSArray (NoteUtilities)

- (NSUInteger)indexOfNoteWithUUIDBytes:(CFUUIDBytes*)bytes {
	NSUInteger i;
    for (i=0; i<[self count]; i++) {
		NoteObject *note = [self objectAtIndex:i];
		CFUUIDBytes *noteBytes = [note uniqueNoteIDBytes];
		if (!memcmp(noteBytes, bytes, sizeof(CFUUIDBytes)))
			return i;
    }
    
    return NSNotFound;
}


- (void)addMenuItemsForURLsInNotes:(NSMenu*)urlsMenu {
	//iterate over notes in array
	//accumulate links as NSMenuItems, with separators between them and disabled items being names of notes
	unsigned int i;
	
	
	NSDictionary *blackAttrs = @{NSFontAttributeName: [NSFont menuFontOfSize:13.0f]};
	NSDictionary *grayAttrs = @{
		NSForegroundColorAttributeName: [NSColor grayColor],
		NSFontAttributeName: [NSFont menuFontOfSize:13.0f]
	};

	BOOL didAddInitialSeparator = NO;
	
	for (i = 0; i<[self count]; i++) {
		NoteObject *aNote = [self objectAtIndex:i];
		NSArray *urls = [[aNote contentString] allLinks];
		if ([urls count] > 0) {
			if (!didAddInitialSeparator) {
				[urlsMenu addItem:[NSMenuItem separatorItem]];
				didAddInitialSeparator = YES;
			}
			
			unsigned int j;
			for (j=0; j<[urls count]; j++) {
				NSURL *url = [urls objectAtIndex:j];
				NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:NSLocalizedString(@"Copy URL",@"contextual menu item title to copy urls")
															  action:@selector(copyItemToPasteboard:) keyEquivalent:@""];
				//_other_ people would use "_web_userVisibleString" here, but resourceSpecifier looks like it's good enough
				NSString *urlString = [[url scheme] isEqualToString:@"mailto"] ? [url resourceSpecifier] : [url absoluteString];
				NSString *truncatedURLString = [urlString length] > 60 ? [[urlString substringToIndex: 60] stringByAppendingString:NSLocalizedString(@"...", @"ellipsis character")] : urlString;
				NSMutableAttributedString *titleString = [[NSMutableAttributedString alloc] initWithString:[NSLocalizedString(@"Copy ",@"menu item prefix to copy a URL") stringByAppendingString:truncatedURLString] attributes:blackAttrs];
				
				NSAttributedString *titleDesc = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" (%@)", titleOfNote(aNote)] attributes:grayAttrs];
				[titleString appendAttributedString:titleDesc];
				[item setAttributedTitle:titleString];
				[item setRepresentedObject:urlString];
				[item setTarget:[item representedObject]];
				[urlsMenu addItem:item];
			}
		}
	}
	
}

@end

@implementation NSMutableArray (Sorting)

- (void)sortUnstableUsingFunction:(NSInteger (*)(id *, id *))compare {
	[self sortUsingFunction:(NSInteger (*)(id, id, void *))genericSortContextLast context:compare];
}

- (void)sortStableUsingFunction:(NSInteger (*)(id *, id *))compare usingBuffer:(__unsafe_unretained id **)buffer ofSize:(unsigned int*)bufSize {
	CFIndex count = CFArrayGetCount((__bridge CFArrayRef)self);
	
	_ResizeBuffer((void ***)(void *)buffer, count, bufSize, sizeof(id));
	
	CFArrayGetValues((__bridge CFArrayRef)self, CFRangeMake(0, [self count]), (const void **)(void *)*buffer);
	
	mergesort((void *)*buffer, (size_t)count, sizeof(id), (int (*)(const void *, const void *))compare);
	
	CFArrayReplaceValues((__bridge CFMutableArrayRef)self, CFRangeMake(0, count), (const void **)(void *)*buffer, count);
}

@end