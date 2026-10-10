import json
import pathlib
import plistlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class BuildPolicyTests(unittest.TestCase):
    def test_layouts_are_base_localized(self):
        resources = ROOT / 'Resources'
        self.assertFalse(sorted(resources.glob('*.lproj/*.nib')))
        self.assertFalse([path for path in resources.glob('*.lproj/*.xib') if path.parent.name != 'Base.lproj'])

    def test_code_strings_are_translated_and_translations_are_used(self):
        literals, localized = set(), set()
        for path in (ROOT / 'Sources').rglob('*.[mhc]'):
            text = path.read_text(errors='replace')
            literals.update(re.findall(r'@"((?:[^"\\]|\\.)*)"', text))
            localized.update(re.findall(r'NSLocalizedString\(\s*@"((?:[^"\\]|\\.)*)"', text))
        for language in ('en', 'de', 'fr', 'it', 'pt', 'zh_CN'):
            data = (ROOT / 'Resources' / f'{language}.lproj' / 'Localizable.strings').read_bytes()
            text = data.decode('utf-16') if data[:2] in (b'\xfe\xff', b'\xff\xfe') else data.decode('utf-8')
            keys = set(re.findall(r'^"((?:[^"\\]|\\.)*)" = ', text, re.M))
            with self.subTest(language=language):
                self.assertEqual(keys - literals, set())
                if language != 'en':
                    self.assertEqual(localized - keys, set())

    def test_localized_strings_name_objects_in_their_base_layouts(self):
        for xib in sorted((ROOT / 'Resources/Base.lproj').glob('*.xib')):
            ids = set(re.findall(r'\bid="([^"]+)"', xib.read_text()))
            for language in ('de', 'fr', 'it', 'pt', 'zh_CN'):
                strings = ROOT / 'Resources' / f'{language}.lproj' / f'{xib.stem}.strings'
                with self.subTest(xib=xib.name, language=language):
                    keys = re.findall(r'^"([^".]+)\.[A-Za-z.]+" = ', strings.read_text(), re.M)
                    self.assertTrue(keys)
                    self.assertEqual(set(keys) - ids, set())

    def test_all_application_configurations_are_arm64_macos_15(self):
        project = json.loads(subprocess.check_output([
            '/usr/bin/plutil', '-convert', 'json', '-o', '-',
            str(ROOT / 'Notation.xcodeproj/project.pbxproj')]))
        configurations = [item for item in project['objects'].values()
                          if item.get('isa') == 'XCBuildConfiguration']
        self.assertEqual(len(configurations), 6)
        for configuration in configurations:
            with self.subTest(configuration=configuration['name']):
                settings = configuration['buildSettings']
                self.assertEqual(settings.get('MACOSX_DEPLOYMENT_TARGET'), '15.0')
                self.assertEqual(settings.get('ARCHS'), 'arm64')
                self.assertEqual(settings.get('SDKROOT'), 'macosx')
                self.assertFalse(any('[arch=' in key for key in settings))
                self.assertNotEqual(settings.get('GENERATE_PROFILING_CODE'), 'YES')
                self.assertNotIn('-pg', str(settings))
                self.assertNotIn('-whatsloaded', str(settings))

    def test_project_uses_current_format_without_obsolete_settings(self):
        project = json.loads(subprocess.check_output([
            '/usr/bin/plutil', '-convert', 'json', '-o', '-',
            str(ROOT / 'Notation.xcodeproj/project.pbxproj')]))
        self.assertEqual(project['objectVersion'], '77')
        root = project['objects'][project['rootObject']]
        self.assertNotIn('compatibilityVersion', root)
        self.assertEqual(root['preferredProjectObjectVersion'], '77')
        obsolete = {'GCC_VERSION', 'GCC_VERSION[sdk=macosx*]', 'GCC_DEBUGGING_SYMBOLS', 'ZERO_LINK',
                    'GCC_PFE_FILE_C_DIALECTS', 'FRAMEWORK_SEARCH_PATHS_QUOTED_1', 'LIBRARY_SEARCH_PATHS'}
        for configuration in project['objects'].values():
            if configuration.get('isa') != 'XCBuildConfiguration':
                continue
            with self.subTest(configuration=configuration['name']):
                settings = configuration['buildSettings']
                self.assertEqual(set(settings) & obsolete, set())
                self.assertNotEqual(settings.get('ENABLE_STRICT_OBJC_MSGSEND'), 'NO')

    def test_sources_use_automatic_reference_counting(self):
        def project(path):
            return json.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'json', '-o', '-', str(ROOT / path)]))
        application = project('Notation.xcodeproj/project.pbxproj')
        objects = application['objects']
        root = objects[application['rootObject']]
        for key in objects[root['buildConfigurationList']]['buildConfigurations']:
            with self.subTest(configuration=objects[key]['name']):
                self.assertEqual(objects[key]['buildSettings'].get('CLANG_ENABLE_OBJC_ARC'), 'YES')
                self.assertEqual(objects[key]['buildSettings'].get('CLANG_ENABLE_OBJC_WEAK'), 'YES')
        for item in objects.values():
            if item.get('isa') == 'XCBuildConfiguration':
                self.assertNotEqual(item['buildSettings'].get('CLANG_ENABLE_OBJC_ARC'), 'NO')
            if item.get('isa') == 'PBXBuildFile':
                self.assertNotIn('objc-arc', str(item.get('settings', {})))
        for path in ['Tests/Compatibility.xcodeproj/project.pbxproj', 'Tests/NativeIntegration.xcodeproj/project.pbxproj']:
            for item in project(path)['objects'].values():
                if item.get('isa') == 'XCBuildConfiguration' and 'PRODUCT_NAME' in item['buildSettings']:
                    with self.subTest(project=path, configuration=item['name']):
                        self.assertEqual(item['buildSettings'].get('CLANG_ENABLE_OBJC_ARC'), 'YES')
                        self.assertEqual(item['buildSettings'].get('CLANG_ENABLE_OBJC_WEAK'), 'YES')
        manual = re.compile(r'\s(retain|release|autorelease)\]|\[super dealloc\]|NSAutoreleasePool|retainCount')
        for directory in ['Sources', 'Vendor', 'Tests']:
            for source in (ROOT / directory).rglob('*.[mh]'):
                with self.subTest(source=str(source.relative_to(ROOT))):
                    self.assertIsNone(manual.search(source.read_text(errors='replace')))
        for script in ['script/build_and_run.sh', 'script/test_external_editor.sh']:
            for line in (ROOT / script).read_text().splitlines():
                if 'xcrun clang' in line:
                    with self.subTest(script=script):
                        self.assertIn('-fobjc-arc', line)

    def test_application_uses_hardened_runtime_with_apple_events_only(self):
        project = json.loads(subprocess.check_output([
            '/usr/bin/plutil', '-convert', 'json', '-o', '-',
            str(ROOT / 'Notation.xcodeproj/project.pbxproj')]))
        targets = [item['buildSettings'] for item in project['objects'].values()
                   if item.get('isa') == 'XCBuildConfiguration'
                   and item['buildSettings'].get('INFOPLIST_FILE') == 'Configuration/Info.plist']
        self.assertEqual(len(targets), 3)
        for settings in targets:
            self.assertEqual(settings.get('ENABLE_HARDENED_RUNTIME'), 'YES')
            self.assertEqual(settings.get('CODE_SIGN_ENTITLEMENTS'), 'Configuration/Notation.entitlements')
        with (ROOT / 'Configuration/Notation.entitlements').open('rb') as source:
            self.assertEqual(plistlib.load(source), {'com.apple.security.automation.apple-events': True})
        with (ROOT / 'Configuration/Info.plist').open('rb') as source:
            self.assertTrue(plistlib.load(source).get('NSAppleEventsUsageDescription'))
        for strings in (ROOT / 'Resources').glob('*.lproj/InfoPlist.strings'):
            with self.subTest(strings=strings.parent.name):
                self.assertIn('NSAppleEventsUsageDescription = "', strings.read_bytes().decode('utf-16'))

    def test_bundle_minimum_and_architecture_match(self):
        with (ROOT / 'Configuration/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        self.assertEqual(info['LSMinimumSystemVersion'], '15.0')
        self.assertEqual(info['CFBundleDevelopmentRegion'], 'en')
        for key in ['LSArchitecturePriority', 'LSMinimumSystemVersionByArchitecture', 'CFBundleGetInfoString',
                    'CFBundleSignature', 'SmartCrashReports_CompanyName', 'SmartCrashReports_EmailTicket']:
            self.assertNotIn(key, info)

    def test_document_types_are_declared_by_uti_with_localized_names(self):
        with (ROOT / 'Configuration/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        imported = {item['UTTypeIdentifier']: item for item in info['UTImportedTypeDeclarations']}
        extensions = {ext for item in imported.values() for ext in item['UTTypeTagSpecification']['public.filename-extension']}
        self.assertEqual(extensions, {'blor', 'rtx', 'utf8', 'utxt'})
        names = set()
        for document in info['CFBundleDocumentTypes']:
            with self.subTest(document=document['CFBundleTypeName']):
                self.assertEqual(set(document), {'CFBundleTypeName', 'CFBundleTypeRole', 'LSItemContentTypes'})
                self.assertNotIn('PboardType', document['CFBundleTypeName'])
                names.add(document['CFBundleTypeName'])
                for uti in document['LSItemContentTypes']:
                    if uti.startswith('net.notational.velocity.'):
                        self.assertIn(uti, imported)
        word = next(d for d in info['CFBundleDocumentTypes'] if 'com.microsoft.word.doc' in d['LSItemContentTypes'])
        self.assertIn('org.openxmlformats.wordprocessingml.document', word['LSItemContentTypes'])
        names |= {item['UTTypeDescription'] for item in imported.values()}
        for strings in (ROOT / 'Resources').glob('*.lproj/InfoPlist.strings'):
            if strings.parent.name == 'en.lproj':
                continue
            with self.subTest(strings=strings.parent.name):
                localized = plistlib.loads(subprocess.check_output(['/usr/bin/plutil', '-convert', 'xml1', '-o', '-', str(strings)]))
                self.assertLessEqual(names, set(localized))

    def test_services_send_uniform_types(self):
        with (ROOT / 'Configuration/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        for service in info['NSServices']:
            for send_type in service['NSSendTypes']:
                with self.subTest(send_type=send_type):
                    self.assertRegex(send_type, r'^[a-z]+(\.[a-z0-9-]+)+$')
        prefix = (ROOT / 'Configuration/Notation_Prefix.pch').read_text()
        self.assertNotIn('PasteboardType', prefix)

    def test_no_openssl_build_dependency(self):
        project = (ROOT / 'Notation.xcodeproj/project.pbxproj').read_text()
        self.assertNotIn('/opt/openssl/', project)
        self.assertNotIn('libcrypto.dylib', project)
        for filename in ['Sources/Notes/Storage/Crypto/NSData_transformations.h',
                         'Sources/Notes/Storage/Crypto/NSData_transformations.m',
                         'Sources/Support/NSString_NV.m',
                         'Sources/Notes/Storage/NotationFileManager.m']:
            with self.subTest(filename=filename):
                self.assertNotIn('openssl/', (ROOT / filename).read_text())

    def test_no_autohyperlinks_binary_or_build_reference(self):
        self.assertFalse((ROOT / 'AutoHyperlinks.framework').exists())
        self.assertNotIn('AutoHyperlinks.framework',
                         (ROOT / 'Notation.xcodeproj/project.pbxproj').read_text())

    def test_no_private_spaces_api(self):
        for source in (ROOT / 'Sources').rglob('*'):
            if source.suffix in ('.m', '.h', '.c'):
                self.assertNotIn('CGSGetWorkspace', source.read_text())
                self.assertNotIn('_CGSDefaultConnection', source.read_text())
                self.assertNotIn('CurrentContextForWindowNumber', source.read_text())

    def test_no_updater_or_remote_sync_implementation(self):
        self.assertFalse((ROOT / 'Sparkle.framework').exists())
        self.assertFalse((ROOT / 'dsa_pub.pem').exists())
        with (ROOT / 'Configuration/Info.plist').open('rb') as source:
            self.assertFalse(any(key.startswith('SU') for key in plistlib.load(source)))
        project = (ROOT / 'Notation.xcodeproj/project.pbxproj').read_text()
        for name in ['Sparkle.framework', 'SimplenoteSession', 'SimplenoteEntryCollector',
                     'SyncSessionController', 'SyncResponseFetcher', 'NotationSyncServiceManager']:
            self.assertNotIn(name, project)
            self.assertFalse(list((ROOT / 'Sources').rglob(name + '.m')))
        for source in (ROOT / 'Sources').rglob('*.m'):
            self.assertNotIn('simple-note.appspot.com', source.read_text())
            self.assertNotIn('SUUpdater', source.read_text())


if __name__ == '__main__':
    unittest.main()
