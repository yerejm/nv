#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

@class NVShortcutRecorder;

@protocol NVShortcutRecorderDelegate <NSObject>
//keyCode is -1 when the shortcut is removed; returning NO keeps the previous shortcut
- (BOOL)shortcutRecorder:(NVShortcutRecorder *)recorder shouldChangeToKeyCode:(NSInteger)keyCode carbonModifiers:(NSUInteger)modifiers;
@optional
- (void)shortcutRecorderDidBeginRecording:(NVShortcutRecorder *)recorder;
- (void)shortcutRecorderDidEndRecording:(NVShortcutRecorder *)recorder;
@end

//names keys as the given keyboard layout labels them, or the current layout when NULL
NSString *NVShortcutDescription(NSInteger keyCode, NSUInteger carbonModifiers, TISInputSourceRef keyboardLayout);

//records a shortcut while focused: Escape or a click elsewhere cancels, Delete removes the shortcut
@interface NVShortcutRecorder : NSView {
	id<NVShortcutRecorderDelegate> delegate;
	NSInteger keyCode;
	NSUInteger modifiers, heldModifiers;
	BOOL recording;
	NSTextFieldCell *bezelCell;
	NSButton *clearButton;
	id clickMonitor;
}

@property (nonatomic, assign) IBOutlet id<NVShortcutRecorderDelegate> delegate;
@property (nonatomic, readonly) NSInteger keyCode;
@property (nonatomic, readonly) NSUInteger modifiers;
@property (nonatomic, readonly, getter=isRecording) BOOL recording;

- (void)setKeyCode:(NSInteger)aKeyCode carbonModifiers:(NSUInteger)carbonModifiers;

@end
