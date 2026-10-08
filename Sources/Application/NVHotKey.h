#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

BOOL NVHotKeyIsFunctionKey(NSInteger keyCode);

//a system-wide shortcut; Carbon hot keys are the only kind that need no Accessibility permission
@interface NVHotKey : NSObject {
	id target;
	SEL action;
	UInt32 identifier;
	EventHotKeyRef hotKeyRef;
	EventHandlerRef handlerRef;
}

- (id)initWithTarget:(id)aTarget action:(SEL)anAction;
//replaces any earlier registration; NO when another app already owns the combination
- (BOOL)registerKeyCode:(NSInteger)keyCode carbonModifiers:(NSUInteger)modifiers;
- (void)unregister;

@end
