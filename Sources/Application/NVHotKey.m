#import "NVHotKey.h"

static const OSType NVHotKeySignature = ('N' << 24) | ('V' << 16) | ('h' << 8) | 'k';

BOOL NVHotKeyIsFunctionKey(NSInteger keyCode) {
	switch (keyCode) {
		case kVK_F1: case kVK_F2: case kVK_F3: case kVK_F4: case kVK_F5:
		case kVK_F6: case kVK_F7: case kVK_F8: case kVK_F9: case kVK_F10:
		case kVK_F11: case kVK_F12: case kVK_F13: case kVK_F14: case kVK_F15:
		case kVK_F16: case kVK_F17: case kVK_F18: case kVK_F19: case kVK_F20:
			return YES;
	}
	return NO;
}

@implementation NVHotKey

static OSStatus NVHotKeyPressed(EventHandlerCallRef handler, EventRef event, void *context) {
	NVHotKey *hotKey = (NVHotKey *)context;
	EventHotKeyID hotKeyID;
	if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hotKeyID), NULL, &hotKeyID) != noErr ||
		hotKeyID.signature != NVHotKeySignature || hotKeyID.id != hotKey->identifier)
		return eventNotHandledErr;
	[hotKey->target performSelector:hotKey->action withObject:hotKey];
	return noErr;
}

- (id)initWithTarget:(id)aTarget action:(SEL)anAction {
	if ((self = [super init])) {
		static UInt32 nextIdentifier = 1;
		identifier = nextIdentifier++;
		target = aTarget;
		action = anAction;
		EventTypeSpec pressed = { kEventClassKeyboard, kEventHotKeyPressed };
		InstallEventHandler(GetEventDispatcherTarget(), NVHotKeyPressed, 1, &pressed, self, &handlerRef);
	}
	return self;
}

- (void)dealloc {
	[self unregister];
	if (handlerRef) RemoveEventHandler(handlerRef);
	[super dealloc];
}

- (BOOL)registerKeyCode:(NSInteger)keyCode carbonModifiers:(NSUInteger)modifiers {
	[self unregister];
	EventHotKeyID hotKeyID = { NVHotKeySignature, identifier };
	if (RegisterEventHotKey((UInt32)keyCode, (UInt32)modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef) == noErr)
		return YES;
	hotKeyRef = NULL;
	return NO;
}

- (void)unregister {
	if (hotKeyRef) {
		UnregisterEventHotKey(hotKeyRef);
		hotKeyRef = NULL;
	}
}

@end
