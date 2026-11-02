#!/usr/bin/env python3
"""Generate the dependency-free Xcode project deterministically (Python stdlib)."""
import hashlib
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'ios' / 'LCRepeater.xcodeproj'


def ident(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def generate():
    sources = sorted(p.relative_to(ROOT / 'ios' / 'LCRepeater').as_posix()
                     for p in (ROOT / 'ios' / 'LCRepeater').rglob('*.swift'))
    objects = []

    def obj(key, body):
        objects.append('\t\t%s = { %s };' % (ident(key), body))

    def refs(keys):
        return '(' + ', '.join(ident(k) for k in keys) + ',)'

    for path in sources:
        obj('file:' + path, 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = "<group>";' % quote(path))
        obj('build:' + path, 'isa = PBXBuildFile; fileRef = %s;' % ident('file:' + path))
    obj('file:Info.plist', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
    obj('file:assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
    obj('build:assets', 'isa = PBXBuildFile; fileRef = %s;' % ident('file:assets'))
    obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = LCRepeater.app; sourceTree = BUILT_PRODUCTS_DIR;')
    obj('uitest:file', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = LCRepeaterUITests/AudioFilePickerTests.swift; sourceTree = "<group>";')
    obj('uitest:build', 'isa = PBXBuildFile; fileRef = %s;' % ident('uitest:file'))
    obj('uitest:product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = LCRepeaterUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    obj('uitest:sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = %s; runOnlyForDeploymentPostprocessing = 0;' % refs(['uitest:build']))
    obj('uitest:frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    obj('uitest:proxy', 'isa = PBXContainerItemProxy; containerPortal = %s; proxyType = 1; remoteGlobalIDString = %s; remoteInfo = LCRepeater;' % (ident('project'), ident('target')))
    obj('uitest:dependency', 'isa = PBXTargetDependency; target = %s; targetProxy = %s;' % (ident('target'), ident('uitest:proxy')))
    obj('sources', 'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = %s; runOnlyForDeploymentPostprocessing = 0;' % refs(['build:' + p for p in sources]))
    obj('resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = %s; runOnlyForDeploymentPostprocessing = 0;' % refs(['build:assets']))
    obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    obj('group:source', 'isa = PBXGroup; children = %s; path = LCRepeater; sourceTree = "<group>";' % refs(['file:' + p for p in sources] + ['file:Info.plist', 'file:assets']))
    obj('group:products', 'isa = PBXGroup; children = %s; name = Products; sourceTree = "<group>";' % refs(['product', 'uitest:product']))
    obj('group:main', 'isa = PBXGroup; children = %s; sourceTree = "<group>";' % refs(['group:source', 'uitest:file', 'group:products']))
    for level in ('project', 'target', 'uitest'):
        for configuration in ('Debug', 'Release'):
            settings = {'SDKROOT': 'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET': '17.0', 'SWIFT_VERSION': '5.0'}
            if level == 'project':
                settings.update({'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
                                 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES', 'SWIFT_STRICT_CONCURRENCY': 'targeted'})
            elif level == 'target':
                settings.update({'PRODUCT_BUNDLE_IDENTIFIER': 'com.firstghrn.lcrepeater.ios',
                                 'PRODUCT_NAME': 'LCRepeater', 'INFOPLIST_FILE': 'LCRepeater/Info.plist',
                                 'GENERATE_INFOPLIST_FILE': 'NO', 'CODE_SIGN_STYLE': 'Automatic',
                                 'ASSETCATALOG_COMPILER_APPICON_NAME': 'AppIcon', 'TARGETED_DEVICE_FAMILY': '1,2',
                                 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
                                 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if configuration == 'Debug' else '-O',
                                 'DEBUG_INFORMATION_FORMAT': 'dwarf' if configuration == 'Debug' else 'dwarf-with-dsym',
                                 'ENABLE_PREVIEWS': 'YES'})
                if configuration == 'Debug':
                    settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
            else:
                settings.update({'PRODUCT_BUNDLE_IDENTIFIER': 'com.firstghrn.lcrepeater.ios.uitests',
                                 'PRODUCT_NAME': 'LCRepeaterUITests', 'GENERATE_INFOPLIST_FILE': 'YES',
                                 'CODE_SIGN_STYLE': 'Automatic', 'TEST_TARGET_NAME': 'LCRepeater',
                                 'TARGETED_DEVICE_FAMILY': '1,2',
                                 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator',
                                 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if configuration == 'Debug' else '-O'})
            body = ' '.join('%s = %s;' % (k, quote(v)) for k, v in settings.items())
            obj(level + ':' + configuration, 'isa = XCBuildConfiguration; buildSettings = { %s }; name = %s;' % (body, configuration))
        obj(level + ':config', 'isa = XCConfigurationList; buildConfigurations = %s; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;' % refs([level + ':Debug', level + ':Release']))
    obj('target', 'isa = PBXNativeTarget; buildConfigurationList = %s; buildPhases = %s; buildRules = (); dependencies = (); name = LCRepeater; productName = LCRepeater; productReference = %s; productType = "com.apple.product-type.application";' %
        (ident('target:config'), refs(['sources', 'frameworks', 'resources']), ident('product')))
    obj('uitest:target', 'isa = PBXNativeTarget; buildConfigurationList = %s; buildPhases = %s; buildRules = (); dependencies = %s; name = LCRepeaterUITests; productName = LCRepeaterUITests; productReference = %s; productType = "com.apple.product-type.bundle.ui-testing";' %
        (ident('uitest:config'), refs(['uitest:sources', 'uitest:frameworks']), refs(['uitest:dependency']), ident('uitest:product')))
    obj('project', 'isa = PBXProject; attributes = { LastUpgradeCheck = 1600; TargetAttributes = { %s = { CreatedOnToolsVersion = 16.0; }; }; }; buildConfigurationList = %s; compatibilityVersion = "Xcode 14.0"; developmentRegion = ko; hasScannedForEncodings = 0; knownRegions = (en, ko, Base,); mainGroup = %s; productRefGroup = %s; projectDirPath = ""; projectRoot = ""; targets = %s;' %
        (ident('target'), ident('project:config'), ident('group:main'), ident('group:products'), refs(['target', 'uitest:target'])))
    text = '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + '\n\t};\n\trootObject = ' + ident('project') + ';\n}\n'
    scheme = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%s" BuildableName="LCRepeater.app" BlueprintName="LCRepeater" ReferencedContainer="container:LCRepeater.xcodeproj"/>
    </BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%s" BuildableName="LCRepeaterUITests.xctest" BlueprintName="LCRepeaterUITests" ReferencedContainer="container:LCRepeater.xcodeproj"/></TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%s" BuildableName="LCRepeater.app" BlueprintName="LCRepeater" ReferencedContainer="container:LCRepeater.xcodeproj"/></BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''' % (ident('target'), ident('uitest:target'), ident('target'))
    return {PROJECT / 'project.pbxproj': text,
            PROJECT / 'xcshareddata/xcschemes/LCRepeater.xcscheme': scheme}


if __name__ == '__main__':
    check = '--check' in sys.argv
    for path, content in generate().items():
        if check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit('Xcode project is stale. Run python3 scripts/generate_ios_project.py')
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
