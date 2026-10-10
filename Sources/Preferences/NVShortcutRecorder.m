#import "NVShortcutRecorder.h"
#import "NVHotKey.h"

static NSUInteger NVCarbonModifiers(NSEventModifierFlags flags) {
	NSUInteger modifiers = 0;
	if (flags & NSEventModifierFlagControl) modifiers |= controlKey;
	if (flags & NSEventModifierFlagOption) modifiers |= optionKey;
	if (flags & NSEventModifierFlagShift) modifiers |= shiftKey;
	if (flags & NSEventModifierFlagCommand) modifiers |= cmdKey;
	return modifiers;
}

static NSString *NVModifierSymbols(NSUInteger modifiers) {
	NSMutableString *symbols = [NSMutableString string];
	if (modifiers & controlKey) [symbols appendString:@"⌃"];
	if (modifiers & optionKey) [symbols appendString:@"⌥"];
	if (modifiers & shiftKey) [symbols appendString:@"⇧"];
	if (modifiers & cmdKey) [symbols appendString:@"⌘"];
	return symbols;
}

static NSString *NVSpecialKeyName(NSInteger keyCode) {
	static const NSInteger functionKeys[] = { kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
		kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20 };
	for (NSUInteger index = 0; index < sizeof(functionKeys) / sizeof(*functionKeys); index++) {
		if (functionKeys[index] == keyCode) return [NSString stringWithFormat:@"F%lu", (unsigned long)index + 1];
	}
	switch (keyCode) {
		case kVK_Space: return NSLocalizedString(@"Space", @"the space bar in a keyboard shortcut");
		case kVK_Return: return @"↩";
		case kVK_ANSI_KeypadEnter: return @"⌤";
		case kVK_Tab: return @"⇥";
		case kVK_Delete: return @"⌫";
		case kVK_ForwardDelete: return @"⌦";
		case kVK_Escape: return @"⎋";
		case kVK_ANSI_KeypadClear: return @"⌧";
		case kVK_Home: return @"↖";
		case kVK_End: return @"↘";
		case kVK_PageUp: return @"⇞";
		case kVK_PageDown: return @"⇟";
		case kVK_LeftArrow: return @"←";
		case kVK_RightArrow: return @"→";
		case kVK_UpArrow: return @"↑";
		case kVK_DownArrow: return @"↓";
	}
	return nil;
}

static NSString *NVLayoutKeyName(NSInteger keyCode, TISInputSourceRef layout) {
	CFDataRef layoutData = layout ? TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) : NULL;
	if (!layoutData) return nil;
	UInt32 deadKeyState = 0;
	UniChar characters[4];
	UniCharCount length = 0;
	if (UCKeyTranslate((const UCKeyboardLayout *)CFDataGetBytePtr(layoutData), (UInt16)keyCode, kUCKeyActionDisplay, 0, LMGetKbdType(),
					   kUCKeyTranslateNoDeadKeysMask, &deadKeyState, sizeof(characters) / sizeof(*characters), &length, characters) != noErr ||
		!length || characters[0] < 0x20)
		return nil;
	NSString *name = [NSString stringWithCharacters:characters length:length];
	//uppercasing must not turn one key into two letters, as with ß
	NSString *uppercaseName = [name uppercaseString];
	return [uppercaseName length] == [name length] ? uppercaseName : name;
}

NSString *NVShortcutDescription(NSInteger keyCode, NSUInteger carbonModifiers, TISInputSourceRef keyboardLayout) {
	NSString *name = NVSpecialKeyName(keyCode);
	if (!name && keyboardLayout) {
		name = NVLayoutKeyName(keyCode, keyboardLayout);
	} else if (!name) {
		//input methods such as Japanese Kana have no key layout of their own
		TISInputSourceRef (*copiers[])(void) = { TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource };
		for (NSUInteger index = 0; !name && index < 2; index++) {
			TISInputSourceRef layout = copiers[index]();
			name = NVLayoutKeyName(keyCode, layout);
			if (layout) CFRelease(layout);
		}
	}
	if (!name) name = [NSString stringWithFormat:@"#%ld", (long)keyCode];
	return [NVModifierSymbols(carbonModifiers) stringByAppendingString:name];
}

@implementation NVShortcutRecorder

@synthesize delegate, keyCode, modifiers, recording;

- (void)_setUpRecorder {
	keyCode = -1;

	bezelCell = [[NSTextFieldCell alloc] initTextCell:@""];
	[bezelCell setBezeled:YES];
	[bezelCell setBezelStyle:NSTextFieldRoundedBezel];
	[bezelCell setAlignment:NSTextAlignmentCenter];
	[bezelCell setLineBreakMode:NSLineBreakByTruncatingTail];
	[bezelCell setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
	[bezelCell setControlView:self];

	NSString *removeTitle = NSLocalizedString(@"Remove Shortcut", @"tooltip of the button that clears a keyboard shortcut");
	CGFloat side = 16, inset = (NSHeight([self bounds]) - side) / 2;
	clearButton = [[NSButton alloc] initWithFrame:NSMakeRect(NSMaxX([self bounds]) - side - inset, inset, side, side)];
	[clearButton setAutoresizingMask:NSViewMinXMargin];
	[clearButton setBordered:NO];
	[clearButton setImagePosition:NSImageOnly];
	[clearButton setImage:[NSImage imageWithSystemSymbolName:@"xmark.circle.fill" accessibilityDescription:removeTitle]];
	[clearButton setContentTintColor:[NSColor tertiaryLabelColor]];
	[clearButton setToolTip:removeTitle];
	[clearButton setRefusesFirstResponder:YES];
	[clearButton setTarget:self];
	[clearButton setAction:@selector(_removeShortcut:)];
	[self addSubview:clearButton];

	[[NSDistributedNotificationCenter defaultCenter] addObserver:self selector:@selector(_keyboardLayoutChanged:)
															name:(NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil
											  suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
	[self _update];
}

- (id)initWithFrame:(NSRect)frame {
	if ((self = [super initWithFrame:frame])) [self _setUpRecorder];
	return self;
}

- (id)initWithCoder:(NSCoder *)coder {
	if ((self = [super initWithCoder:coder])) [self _setUpRecorder];
	return self;
}

- (void)dealloc {
	if (clickMonitor) [NSEvent removeMonitor:clickMonitor];
	[[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setKeyCode:(NSInteger)aKeyCode carbonModifiers:(NSUInteger)carbonModifiers {
	keyCode = aKeyCode < 0 ? -1 : aKeyCode;
	modifiers = keyCode < 0 ? 0 : carbonModifiers;
	[self _update];
}

- (NSString *)_shownString {
	if (recording) return NVModifierSymbols(heldModifiers);
	return keyCode < 0 ? @"" : NVShortcutDescription(keyCode, modifiers, NULL);
}

- (NSString *)_placeholder {
	return recording ? NSLocalizedString(@"Press Shortcut", @"prompt while recording a keyboard shortcut") :
		NSLocalizedString(@"Record Shortcut", @"prompt in an empty keyboard shortcut field");
}

- (void)_update {
	[clearButton setHidden:recording || keyCode < 0];
	[self setNeedsDisplay:YES];
}

- (void)_keyboardLayoutChanged:(NSNotification *)notification {
	[self setNeedsDisplay:YES];
}

- (void)_changeToKeyCode:(NSInteger)aKeyCode carbonModifiers:(NSUInteger)carbonModifiers {
	if (aKeyCode == keyCode && (aKeyCode < 0 || carbonModifiers == modifiers)) return;
	if ([delegate shortcutRecorder:self shouldChangeToKeyCode:aKeyCode carbonModifiers:carbonModifiers])
		[self setKeyCode:aKeyCode carbonModifiers:carbonModifiers];
	else
		NSBeep();
}

- (void)_removeShortcut:(id)sender {
	[self _changeToKeyCode:-1 carbonModifiers:0];
}

- (void)_endRecording {
	if (recording) [[self window] makeFirstResponder:nil];
}

- (void)_recordKeyEvent:(NSEvent *)event {
	NSUInteger eventModifiers = NVCarbonModifiers([event modifierFlags]);
	unsigned short eventKeyCode = [event keyCode];
	if (!eventModifiers && eventKeyCode == kVK_Escape) {
		[self _endRecording];
	} else if (!eventModifiers && (eventKeyCode == kVK_Delete || eventKeyCode == kVK_ForwardDelete)) {
		[self _endRecording];
		[self _removeShortcut:nil];
	} else if (eventKeyCode == kVK_Tab && !(eventModifiers & ~shiftKey)) {
		if (eventModifiers) [[self window] selectPreviousKeyView:self];
		else [[self window] selectNextKeyView:self];
	} else if (!(eventModifiers & (cmdKey | optionKey | controlKey)) && !NVHotKeyIsFunctionKey(eventKeyCode)) {
		//anything else would take over ordinary typing in every app
		NSBeep();
	} else {
		//ending first lets the previous shortcut be restored if the new one is taken
		[self _endRecording];
		[self _changeToKeyCode:eventKeyCode carbonModifiers:eventModifiers];
	}
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
	if (newWindow != [self window]) [self _endRecording];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
	if (newWindow)
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_windowDidResignKey:) name:NSWindowDidResignKeyNotification object:newWindow];
	[super viewWillMoveToWindow:newWindow];
}

- (void)_windowDidResignKey:(NSNotification *)notification {
	[self _endRecording];
}

#pragma mark - responder

- (BOOL)acceptsFirstResponder {
	return YES;
}

//otherwise opening Settings could start recording before anything is clicked
- (BOOL)canBecomeKeyView {
	return [NSApp isFullKeyboardAccessEnabled] && [super canBecomeKeyView];
}

- (BOOL)becomeFirstResponder {
	if (![super becomeFirstResponder]) return NO;
	recording = YES;
	heldModifiers = 0;
	__weak NVShortcutRecorder *recorder = self;
	clickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^NSEvent *(NSEvent *event) {
		if ([event window] != [recorder window] || ![recorder mouse:[recorder convertPoint:[event locationInWindow] fromView:nil] inRect:[recorder bounds]])
			[recorder _endRecording];
		return event;
	}];
	if ([delegate respondsToSelector:@selector(shortcutRecorderDidBeginRecording:)])
		[delegate shortcutRecorderDidBeginRecording:self];
	[self _update];
	return YES;
}

- (BOOL)resignFirstResponder {
	if (![super resignFirstResponder]) return NO;
	recording = NO;
	[NSEvent removeMonitor:clickMonitor];
	clickMonitor = nil;
	if ([delegate respondsToSelector:@selector(shortcutRecorderDidEndRecording:)])
		[delegate shortcutRecorderDidEndRecording:self];
	[self _update];
	return YES;
}

//the window has already made the recorder first responder by the time the click arrives
- (void)mouseDown:(NSEvent *)event {
	[[self window] makeFirstResponder:self];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
	if (!recording || [[self window] firstResponder] != self) return [super performKeyEquivalent:event];
	[self _recordKeyEvent:event];
	return YES;
}

- (void)keyDown:(NSEvent *)event {
	if (recording) [self _recordKeyEvent:event];
	else [super keyDown:event];
}

- (void)flagsChanged:(NSEvent *)event {
	if (recording) {
		heldModifiers = NVCarbonModifiers([event modifierFlags]);
		[self setNeedsDisplay:YES];
	}
	[super flagsChanged:event];
}

#pragma mark - drawing

- (void)drawRect:(NSRect)dirtyRect {
	[bezelCell setStringValue:[self _shownString]];
	[bezelCell setPlaceholderString:[self _placeholder]];
	[bezelCell drawWithFrame:[self bounds] inView:self];
}

- (NSRect)focusRingMaskBounds {
	return [self bounds];
}

- (void)drawFocusRingMask {
	[bezelCell drawFocusRingMaskWithFrame:[self bounds] inView:self];
}

#pragma mark - accessibility

- (BOOL)isAccessibilityElement {
	return YES;
}

- (NSAccessibilityRole)accessibilityRole {
	return NSAccessibilityButtonRole;
}

- (NSString *)accessibilityLabel {
	NSString *shown = [self _shownString];
	return [shown length] ? shown : [self _placeholder];
}

- (BOOL)accessibilityPerformPress {
	if (recording) [self _endRecording];
	else [[self window] makeFirstResponder:self];
	return YES;
}

@end
