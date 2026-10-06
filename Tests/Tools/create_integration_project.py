import pathlib
import plistlib
import json
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
original = json.loads(subprocess.check_output([
    '/usr/bin/plutil', '-convert', 'json', '-o', '-',
    str(ROOT / 'Notation.xcodeproj/project.pbxproj')]))
original_objects = original['objects']
paths = {}


def resolve(key, parent):
    obj = original_objects[key]
    path = parent / obj.get('path', '')
    paths[key] = path
    if obj['isa'] == 'PBXGroup':
        for child in obj.get('children', []):
            resolve(child, path)


resolve(original_objects[original['rootObject']]['mainGroup'], ROOT)
app = next(obj for obj in original_objects.values() if obj.get('productType') == 'com.apple.product-type.application')
phase = next(original_objects[key] for key in app['buildPhases']
             if original_objects[key]['isa'] == 'PBXSourcesBuildPhase')
sources = [paths[original_objects[key]['fileRef']] for key in phase['files']]
sources = [source for source in sources if source.name != 'main.m']
sources.extend(ROOT / 'Tests' / filename for filename in [
    'NativeStorageTests.m', 'NativeQuitTests.m', 'NativeResourceTests.m', 'NativeLinkRoutingTests.m', 'NativeActivationTests.m'])
objects = {}


def add(value):
    key = f'{len(objects) + 1:024X}'
    objects[key] = value
    return key


refs = [add(dict(isa='PBXFileReference', path='../' + str(source.relative_to(ROOT)),
                 sourceTree='SOURCE_ROOT', lastKnownFileType='sourcecode.c.objc'
                 if source.suffix == '.m' else 'sourcecode.c.c')) for source in sources]
product = add(dict(isa='PBXFileReference', path='NativeIntegrationTests.xctest',
                   sourceTree='BUILT_PRODUCTS_DIR', explicitFileType='wrapper.cfbundle'))
group = add(dict(isa='PBXGroup', children=refs + [product], sourceTree='<group>'))
builds = [add(dict(isa='PBXBuildFile', fileRef=ref)) for ref in refs]
sourcephase = add(dict(isa='PBXSourcesBuildPhase', buildActionMask=2147483647,
                       files=builds, runOnlyForDeploymentPostprocessing=0))
frameworkphase = add(dict(isa='PBXFrameworksBuildPhase', buildActionMask=2147483647,
                          files=[], runOnlyForDeploymentPostprocessing=0))
frameworks = ['XCTest', 'Cocoa', 'Carbon', 'CoreServices', 'SecurityInterface',
              'Security', 'WebKit', 'ApplicationServices', 'SystemConfiguration', 'IOKit', 'PDFKit']
settings = dict(
    ARCHS='arm64', SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='15.0',
    CLANG_ENABLE_OBJC_ARC='NO', GCC_PREFIX_HEADER='$(SRCROOT)/../Notation_Prefix.pch',
    HEADER_SEARCH_PATHS=['$(SRCROOT)/..', '$(SRCROOT)/../PTHotKeys', '$(SRCROOT)/../ODBEditor',
                         '$(SRCROOT)/../RBSplitView', '$(SRCROOT)/../hashcash'],
    GENERATE_INFOPLIST_FILE='YES', PRODUCT_BUNDLE_IDENTIFIER='net.notational.velocity.native-tests',
    PRODUCT_NAME='NativeIntegrationTests',
    FRAMEWORK_SEARCH_PATHS='$(PLATFORM_DIR)/Developer/Library/Frameworks',
    OTHER_LDFLAGS=[flag for framework in frameworks for flag in ['-framework', framework]] + ['-lz'],
    ALWAYS_SEARCH_USER_PATHS='NO', GCC_OPTIMIZATION_LEVEL='0')
configs = [add(dict(isa='XCBuildConfiguration', name=name, buildSettings=settings))
           for name in ['Debug', 'Release']]
configlist = add(dict(isa='XCConfigurationList', buildConfigurations=configs,
                      defaultConfigurationIsVisible=0, defaultConfigurationName='Debug'))
target = add(dict(isa='PBXNativeTarget', buildConfigurationList=configlist,
                  buildPhases=[sourcephase, frameworkphase], buildRules=[], dependencies=[],
                  name='NativeIntegrationTests', productName='NativeIntegrationTests',
                  productReference=product, productType='com.apple.product-type.bundle.unit-test'))
projectsettings = [add(dict(isa='XCBuildConfiguration', name=name, buildSettings={}))
                   for name in ['Debug', 'Release']]
projectconfigs = add(dict(isa='XCConfigurationList', buildConfigurations=projectsettings,
                          defaultConfigurationIsVisible=0, defaultConfigurationName='Debug'))
project = add(dict(isa='PBXProject', buildConfigurationList=projectconfigs,
                   compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en'],
                   mainGroup=group, projectDirPath='', projectRoot='', targets=[target]))
directory = ROOT / 'Tests/NativeIntegration.xcodeproj'
(directory / 'xcshareddata/xcschemes').mkdir(parents=True, exist_ok=True)
(directory / 'project.pbxproj').write_bytes(plistlib.dumps(
    dict(archiveVersion='1', classes={}, objectVersion='56', objects=objects, rootObject=project),
    sort_keys=False))
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NativeIntegrationTests.xctest" BlueprintName="NativeIntegrationTests" ReferencedContainer="container:NativeIntegration.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="NativeIntegrationTests.xctest" BlueprintName="NativeIntegrationTests" ReferencedContainer="container:NativeIntegration.xcodeproj"/></TestableReference></Testables><EnvironmentVariables><EnvironmentVariable key="NV_CAPTURE_FIXTURES" value="NO" isEnabled="YES"/></EnvironmentVariables></TestAction>
</Scheme>'''
(directory / 'xcshareddata/xcschemes/NativeIntegration.xcscheme').write_text(scheme)
