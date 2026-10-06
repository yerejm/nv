import json
import pathlib
import plistlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class BuildPolicyTests(unittest.TestCase):
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

    def test_bundle_minimum_and_architecture_match(self):
        with (ROOT / 'Configuration/Info.plist').open('rb') as source:
            info = plistlib.load(source)
        self.assertEqual(info['LSMinimumSystemVersion'], '15.0')
        self.assertEqual(info.get('LSArchitecturePriority'), ['arm64'])
        self.assertNotIn('LSMinimumSystemVersionByArchitecture', info)

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
