import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'build/generated-tests'
OUTPUT.mkdir(parents=True, exist_ok=True)


def method(source, prefix):
    start = source.index(prefix)
    next_method = re.search(r'\n[+-] \(', source[start + len(prefix):])
    next_end = source.find('\n@end', start)
    end = min(next_end if next_end != -1 else len(source),
              start + len(prefix) + next_method.start() if next_method else len(source))
    return source[start:end].strip()


source = (ROOT / 'Sources/Application/GlobalPrefs.m').read_text()
assignment = re.search(r'runCallbacksIMP = .*?;', source).group()
callback = source[source.index('static void sendCallbacksForGlobalPrefs'):source.index('\n- (id)init')]
methods = [method(source, prefix) for prefix in [
    '- (void)registerWithTarget:', '- (void)registerForSettingChange:',
    '- (void)unregisterForNotificationsFromSelector:', '- (void)notifyCallbacksForSelector:',
    '- (void)setConfirmNoteDeletion:', '- (BOOL)confirmNoteDeletion']]
header = (ROOT / 'Sources/Application/GlobalPrefs.h').read_text()
declaration = header[:header.index('+ (GlobalPrefs *)defaultPrefs;')]
declaration += '\n'.join(item[:item.index('{')].strip() + ';' for item in methods) + '\n@end\n'
(OUTPUT / 'GlobalPrefsCallbacks.m').write_text(declaration + '''
#define SEND_CALLBACKS() sendCallbacksForGlobalPrefs(self, _cmd, sender)
static NSString *ConfirmNoteDeletionKey = @"ConfirmNoteDeletion";
@implementation GlobalPrefs
''' + callback + '''
- (id)init {
    if ((self = [super init])) {
        ''' + assignment + '''
        selectorObservers = [[NSMutableDictionary alloc] init];
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"net.notational.velocity.tests.callbacks"];
    }
    return self;
}
- (void)dealloc {
    [defaults removePersistentDomainForName:@"net.notational.velocity.tests.callbacks"];
    [defaults release];
    [selectorObservers release];
    [super dealloc];
}
''' + '\n'.join(methods) + '\n@end\n')

source = (ROOT / 'Sources/Support/NSString_NV.m').read_text()
methods = [method(source, prefix) for prefix in [
    '- (NSString *)stringByReplacingPercentEscapes', '- (NSString*)stringWithPercentEscapes',
    '- (CFUUIDBytes)uuidBytes', '+ (NSString*)uuidStringWithBytes:',
    '- (NSData *)decodeBase64 {', '- (NSData *)decodeBase64WithNewlines:']]
(OUTPUT / 'NSStringUtilities.m').write_text('#import "NSString_NV.h"\n#import "NSData_transformations.h"\n'
    '@implementation NSString (NVTestUnits)\n' + '\n'.join(methods) + '\n@end\n')

source = (ROOT / 'Sources/Editor/AttributedPlainText.m').read_text()
start = source.index('- (void)addLinkAttributesForRange:')
end = source.index('-(void)addAttributesForMarkdownHeadingLinesInRange:', start)
imports = '#import <AutoHyperlinks/AutoHyperlinks.h>\n' if '#import <AutoHyperlinks/' in source else ''
(OUTPUT / 'HyperlinkUnits.m').write_text('#import "AttributedPlainText.h"\n#import "NSString_NV.h"\n'
    + imports + 'static BOOL _StringWithRangeIsProbablyObjC(NSString *, NSRange);\n'
    '@implementation NSMutableAttributedString (NVLinkTestUnits)\n'
    + source[start:end] + '\n@end\n')

source = (ROOT / 'Sources/Notes/Storage/NotationFileManager.m').read_text()
start = source.index('static void uuid_create_md5_from_name(')
end = source.index('\n\nCFUUIDRef CopyHFSVolumeUUIDForMount', start)
imports = '#include "NVMD5.h"\n'
(OUTPUT / 'VolumeIdentity.m').write_text('#import <Foundation/Foundation.h>\n' + imports
    + source[start:end] + '''
NSData *NVVolumeUUIDForName(NSData *name) {
    unsigned char uuid[16];
    uuid_create_md5_from_name(uuid, [name bytes], (int)[name length]);
    return [NSData dataWithBytes:uuid length:sizeof(uuid)];
}
''')

source = (ROOT / 'Sources/Editor/LinkingEditor.m').read_text()
category_start = source.index('@interface NSCursor (WhiteIBeamCursor)')
category_end = source.index('@implementation LinkingEditor', category_start)
unit = '\n'.join(method(source, prefix) for prefix in [
    '- (void)_fixCursorForBackgroundUpdatingMouseInside:',
    '- (void)fixCursorForBackgroundUpdatingMouseInside:'])
for prefix in ['- (NSCursor *)editorCursor', '- (void)resetCursorRects']:
    if prefix in source:
        unit += '\n' + method(source, prefix)
header = (ROOT / 'Sources/Editor/LinkingEditor.h').read_text()
declaration = header[:header.index('- (NSColor*)_insertionPointColor')]
declaration += '\n'.join(line[:line.index('{')].strip() + ';'
                          for line in unit.splitlines() if line.startswith('- (')) + '\n@end\n'
(OUTPUT / 'EditorCursor.m').write_text(declaration + '#import <objc/runtime.h>\n'
    + source[category_start:category_end] + '@implementation LinkingEditor\n' + unit + '\n@end\n')
