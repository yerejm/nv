import json
import pathlib
import plistlib
import subprocess

from project_layout import automatic_reference_counting, file_groups, header_search_paths

ROOT = pathlib.Path(__file__).resolve().parents[2]
objects = {}


def add(value):
    key = f'{len(objects) + 1:024X}'
    objects[key] = value
    return key


sources = [
    'Tests/Notes/Model/DeletedNoteObjectTests.m',
    'Tests/Notes/Storage/Crypto/CryptoCompatibilityTests.m',
    'Tests/Preferences/PreferencesIsolationTests.m', 'Tests/Application/CallbackTests.m',
    'Tests/Notes/Storage/Crypto/CryptoTests.m', 'Tests/Editor/HyperlinkTests.m',
    'Tests/Editor/CursorTests.m', 'build/generated-tests/EditorCursor.m',
    'build/generated-tests/VolumeIdentity.m', 'build/generated-tests/HyperlinkUnits.m',
    'Sources/Notes/Storage/Crypto/NSData_transformations.m',
    'build/generated-tests/NSStringUtilities.m', 'build/generated-tests/GlobalPrefsCallbacks.m',
    'Sources/Notes/Model/DeletedNoteObject.m', 'Sources/Notes/Storage/NVFileReference.c',
    'Sources/Notes/Storage/Crypto/Legacy/NVMD5.c', 'Sources/Notes/Storage/Crypto/Legacy/sha1.c',
    'Sources/Notes/Storage/Crypto/Legacy/broken_md5.c',
]
group, children, refs = file_groups(add, sources + ['Tests/Support/TestPaths.h'])
refs = refs[:len(sources)]
product = add(dict(isa='PBXFileReference', path='CompatibilityTests.xctest',
                   sourceTree='BUILT_PRODUCTS_DIR', explicitFileType='wrapper.cfbundle'))
children.append(product)
builds = [add(dict(isa='PBXBuildFile', fileRef=ref)) for ref in refs]
sourcephase = add(dict(isa='PBXSourcesBuildPhase', buildActionMask=2147483647,
                       files=builds, runOnlyForDeploymentPostprocessing=0))
frameworkphase = add(dict(isa='PBXFrameworksBuildPhase', buildActionMask=2147483647,
                          files=[], runOnlyForDeploymentPostprocessing=0))
settings = dict(
    ARCHS='arm64', SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='15.0',
    **automatic_reference_counting(), GCC_PREFIX_HEADER='$(SRCROOT)/../Configuration/Notation_Prefix.pch',
    HEADER_SEARCH_PATHS=header_search_paths(), GENERATE_INFOPLIST_FILE='YES',
    PRODUCT_BUNDLE_IDENTIFIER='net.notational.velocity.tests', PRODUCT_NAME='CompatibilityTests',
    FRAMEWORK_SEARCH_PATHS=['$(PLATFORM_DIR)/Developer/Library/Frameworks', '$(SRCROOT)/..'],
    OTHER_LDFLAGS=['-framework', 'XCTest', '-framework', 'Cocoa', '-framework', 'UniformTypeIdentifiers', '-framework', 'Carbon', '-framework', 'WebKit', '-lz'],
    ALWAYS_SEARCH_USER_PATHS='NO')
configs = [add(dict(isa='XCBuildConfiguration', name=name, buildSettings=settings))
           for name in ['Debug', 'Release']]
configlist = add(dict(isa='XCConfigurationList', buildConfigurations=configs,
                      defaultConfigurationIsVisible=0, defaultConfigurationName='Debug'))
target = add(dict(isa='PBXNativeTarget', buildConfigurationList=configlist,
                  buildPhases=[sourcephase, frameworkphase], buildRules=[], dependencies=[],
                  name='CompatibilityTests', productName='CompatibilityTests',
                  productReference=product, productType='com.apple.product-type.bundle.unit-test'))
projectsettings = [add(dict(isa='XCBuildConfiguration', name=name, buildSettings=dict(
    ARCHS='arm64', SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='15.0')))
    for name in ['Debug', 'Release']]
projectconfigs = add(dict(isa='XCConfigurationList', buildConfigurations=projectsettings,
                          defaultConfigurationIsVisible=0, defaultConfigurationName='Debug'))
project = add(dict(isa='PBXProject', buildConfigurationList=projectconfigs,
                   compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en'],
                   mainGroup=group, projectDirPath='', projectRoot='', targets=[target]))
(ROOT / 'Tests/Compatibility.xcodeproj/project.pbxproj').write_bytes(plistlib.dumps(
    dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=project),
    sort_keys=False))
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="CompatibilityTests.xctest" BlueprintName="CompatibilityTests" ReferencedContainer="container:Compatibility.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="CompatibilityTests.xctest" BlueprintName="CompatibilityTests" ReferencedContainer="container:Compatibility.xcodeproj"/></TestableReference></Testables></TestAction>
</Scheme>'''
(ROOT / 'Tests/Compatibility.xcodeproj/xcshareddata/xcschemes/Compatibility.xcscheme').write_text(scheme)
key = bytes(range(32))
iv = bytes(range(16))
vectors = []
for plaintext in [b'', b'legacy database content\n', bytes(range(64)), 'café 日本語 😀'.encode()]:
    cipher = subprocess.check_output(['/usr/bin/openssl', 'enc', '-aes-256-cbc',
                                      '-K', key.hex(), '-iv', iv.hex()], input=plaintext)
    vectors.append(dict(plaintext=plaintext.hex(), ciphertext=cipher.hex(), key=key.hex(), iv=iv.hex()))
(ROOT / 'Tests/Fixtures/crypto-vectors.json').write_text(json.dumps(dict(
    provenance='AES-256-CBC PKCS7 generated by macOS /usr/bin/openssl LibreSSL 3.3.6; fixed key and IV; original app uses the same EVP cipher and padding',
    aes=vectors), indent=2) + '\n')
