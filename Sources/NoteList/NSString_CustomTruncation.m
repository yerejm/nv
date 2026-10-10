//
//  NSString_CustomTruncation.m
//  Notation
//
//  Created by Zachary Schneirov on 1/12/11.

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


#import "NSString_CustomTruncation.h"
#import "GlobalPrefs.h"

@implementation NSString (CustomTruncation)

static NSMutableParagraphStyle *LineBreakingStyle(void);
static NSDictionary *GrayTextAttributes(void);
static NSDictionary *LineTruncAttributes(void);
static NSUInteger PreviewCharacterLimitForWidth(CGFloat width);

- (NSString*)truncatedPreviewStringOfLength:(NSUInteger)characterCount {
	//an empty range would still return the first composed character
	if (!characterCount || ![self length]) return @"";
	NSRange range = [self rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, MIN(characterCount, [self length]))];
	NSMutableString *preview = [[self substringWithRange:range] mutableCopy];
	static NSCharacterSet *breaks = nil;
	if (!breaks) {
		const unichar breakCharacters[] = { '\t', '\n', '\r', '\f', 0x0003, 0x2028, 0x2029 };
		breaks = [NSCharacterSet characterSetWithCharactersInString:[NSString stringWithCharacters:breakCharacters length:sizeof(breakCharacters) / sizeof(*breakCharacters)]];
	}
	NSRange found = NSMakeRange(0, 0);
	while ((found = [preview rangeOfCharacterFromSet:breaks options:NSLiteralSearch range:NSMakeRange(NSMaxRange(found), [preview length] - NSMaxRange(found))]).location != NSNotFound)
		[preview replaceCharactersInRange:found withString:@" "];
	return preview;
}

static NSMutableDictionary<NSAttributedStringKey, id> *titleTruncAttrs = nil;

void ResetFontRelatedTableAttributes(void) {
	titleTruncAttrs = nil;
}

static NSMutableParagraphStyle *LineBreakingStyle(void) {
	static NSMutableParagraphStyle *lineBreaksStyle = nil;
	if (!lineBreaksStyle) {
		lineBreaksStyle = [[NSMutableParagraphStyle alloc] init];
		[lineBreaksStyle setLineBreakMode:NSLineBreakByTruncatingTail];
		[lineBreaksStyle setTighteningFactorForTruncation:0.0];
	}
	return lineBreaksStyle;
}

static NSDictionary *GrayTextAttributes(void) {
	static NSDictionary *grayTextAttributes = nil;
	if (!grayTextAttributes) grayTextAttributes = @{NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
	return grayTextAttributes;
}

static NSDictionary *LineTruncAttributes(void) {
	static NSDictionary *lineTruncAttributes = nil;
	if (!lineTruncAttributes) lineTruncAttributes = @{NSParagraphStyleAttributeName: LineBreakingStyle()};
	return lineTruncAttributes;
}

NSDictionary<NSAttributedStringKey, id> *LineTruncAttributesForTitle(void) {
	if (!titleTruncAttrs) {
		GlobalPrefs *prefs = [GlobalPrefs defaultPrefs];
		unsigned int bitmap = [prefs tableColumnsBitmap];
		float fontSize = [prefs tableFontSize];
		BOOL usesBold = ColumnIsSet(NoteLabelsColumn, bitmap) || ColumnIsSet(NoteDateCreatedColumn, bitmap) ||
		ColumnIsSet(NoteDateModifiedColumn, bitmap) || [prefs tableColumnsShowPreview];
		
		titleTruncAttrs = [@{
			NSParagraphStyleAttributeName: [LineBreakingStyle() mutableCopy],
			NSFontAttributeName: (usesBold ? [NSFont boldSystemFontOfSize:fontSize] : [NSFont systemFontOfSize:fontSize])
		} mutableCopy];
		
		if (ColumnIsSet(NoteDateCreatedColumn, bitmap) || ColumnIsSet(NoteDateModifiedColumn, bitmap)) {
			//account for right-"aligned" date string, which will be relatively constant, so this can be cached
			[[titleTruncAttrs objectForKey:NSParagraphStyleAttributeName] setTailIndent: fontSize * -4.6]; //avg of -55 for ~11-12 font size
		}
	}
	return titleTruncAttrs;
}

//enough characters to fill the width even if every one is as narrow as a space; the cell truncates whatever overflows
static NSUInteger PreviewCharacterLimitForWidth(CGFloat width) {
	return (NSUInteger)ceil(MAX(width, 0) / ([[GlobalPrefs defaultPrefs] tableFontSize] * 0.2));
}

//LineTruncAttributesForTags would be variable, depending on the note; each preview string will have its own copy of the nsdictionary

- (NSAttributedString*)attributedMultiLinePreviewFromBodyText:(NSAttributedString*)bodyText upToWidth:(float)upToWidth intrusionWidth:(float)intWidth {
	//first line is title, truncated to a shorter width to account for date/time, using a negative -[NSMutableParagraphStyle setTailIndent:] value
	//next "two" lines are wrapped body text, with a character-count estimation of essentially double that of a single-line preview
	//also with an independent tailindent to account for a separately-drawn tags-string, if tags exist
	//upToWidth will be used to manually truncate note-bodies only, and should be the full column width available
	//intWidth will typically be the width of the tags string or other representation
	
	NSString *truncatedBodyString = [[bodyText string] truncatedPreviewStringOfLength:PreviewCharacterLimitForWidth(upToWidth) * 2];
	NSMutableString *unattributedPreview = [[NSMutableString alloc] initWithCapacity:[truncatedBodyString length] + [self length] + 1];
	
	[unattributedPreview appendString:self];
	[unattributedPreview appendString:@"\n"];
	[unattributedPreview appendString:truncatedBodyString];
	
	NSMutableAttributedString *attributedStringPreview = [[NSMutableAttributedString alloc] initWithString:unattributedPreview];
	
	//title is black (no added colors) and truncated with LineTruncAttributesForTitle()
	//body is gray and truncated with a variable tail indent, depending on intruding tags
	
	NSDictionary *bodyTruncDict = @{
		NSParagraphStyleAttributeName: [LineBreakingStyle() mutableCopy],
		NSForegroundColorAttributeName: [[GlobalPrefs defaultPrefs] interfaceSecondaryColor]
	};
	//set word-wrapping to let -[NSCell setTruncatesLastVisibleLine:] work
	[[bodyTruncDict objectForKey:NSParagraphStyleAttributeName] setLineBreakMode:NSLineBreakByWordWrapping];
	
	if (intWidth > 0.0) {
		//there are tags; add an appropriately-sized tail indent to the body
		[[bodyTruncDict objectForKey:NSParagraphStyleAttributeName] setTailIndent:-intWidth];
	}
	
	[attributedStringPreview addAttributes:LineTruncAttributesForTitle() range:NSMakeRange(0, [self length])];
	[attributedStringPreview addAttributes:bodyTruncDict range:NSMakeRange([self length] + 1, [unattributedPreview length] - ([self length] + 1))];
	
	return attributedStringPreview;
}

- (NSAttributedString*)attributedSingleLineTitle {
	//show only a single line, with a tail indent large enough for both the date and tags (if there are any)
	//because this method displays the title only, manual truncation isn't really necessary
	//the highlighted version of this string should be bolded
	
	NSMutableAttributedString *titleStr = [[NSMutableAttributedString alloc] initWithString:self attributes:LineTruncAttributesForTitle()];

	return titleStr;
}


- (NSAttributedString*)attributedSingleLinePreviewFromBodyText:(NSAttributedString*)bodyText upToWidth:(float)upToWidth {
	
	NSUInteger limit = PreviewCharacterLimitForWidth(upToWidth);
	NSString *truncatedBodyString = [[bodyText string] truncatedPreviewStringOfLength:limit > [self length] ? limit - [self length] : 0];
	
	NSMutableString *unattributedPreview = [self mutableCopy];
	NSString *delimiter = NSLocalizedString(@" option-shift-dash ", @"title/description delimiter");
	[unattributedPreview appendString:delimiter];
	[unattributedPreview appendString:truncatedBodyString];
	
	NSMutableAttributedString *attributedStringPreview = [[NSMutableAttributedString alloc] initWithString:unattributedPreview attributes:LineTruncAttributes()];
	[attributedStringPreview addAttributes:GrayTextAttributes() range:NSMakeRange([self length], [unattributedPreview length] - [self length])];
	
	return attributedStringPreview;
}


@end
