'use strict';
// Original, dependency-free project writer. No installation, build, or network access.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const projectDirectory = path.join(root, 'IyoEditor.xcodeproj');
const schemesDirectory = path.join(projectDirectory, 'xcshareddata', 'xcschemes');
const relative = p => path.relative(root, p).split(path.sep).join('/');
const filesIn = directory => fs.readdirSync(path.join(root, directory), {withFileTypes:true})
    .filter(entry => entry.isFile() && entry.name.endsWith('.swift'))
    .map(entry => directory + '/' + entry.name).sort();
const appSources = ['App', 'Storage', 'Editor', 'UI'].flatMap(filesIn);
const testSources = filesIn('NativeTests');
for (const required of ['Core/SessionCore.js', 'Resources/Info.plist']) {
    if (!fs.existsSync(path.join(root, required))) throw new Error('Missing ' + required);
}
let sequence = 1;
const id = () => (sequence++).toString(16).toUpperCase().padStart(24, '0');
const objects = [];
const obj = (objectId, body) => objects.push(`${objectId} = { ${body} };`);
const quoted = value => '"' + value.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
const list = values => '(' + values.join(', ') + (values.length ? ',' : '') + ')';
const projectId = id(), rootGroup = id(), productsGroup = id();
const appTarget = id(), testTarget = id(), appProduct = id(), testProduct = id();
const appSourcesPhase = id(), appResourcesPhase = id(), appFrameworksPhase = id();
const testSourcesPhase = id(), testResourcesPhase = id(), testFrameworksPhase = id();
const dependency = id(), proxy = id();
const rootChildren = [], appBuildFiles = [], testBuildFiles = [];
for (const source of appSources.concat(testSources)) {
    const ref = id(), build = id();
    obj(ref, `isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${quoted(source)}; sourceTree = "<group>";`);
    obj(build, `isa = PBXBuildFile; fileRef = ${ref};`);
    rootChildren.push(ref);
    (source.startsWith('NativeTests/') ? testBuildFiles : appBuildFiles).push(build);
}
const resourceBuildFiles = [];
const resources = ['Core', 'Editor'].flatMap(directory => fs.readdirSync(path.join(root, directory), {withFileTypes:true})
    .filter(entry => entry.isFile() && entry.name.endsWith('.js'))
    .map(entry => directory + '/' + entry.name).sort());
for (const resource of resources) {
    const ref = id(), build = id();
    obj(ref, `isa = PBXFileReference; lastKnownFileType = sourcecode.javascript; path = ${quoted(resource)}; sourceTree = "<group>";`);
    obj(build, `isa = PBXBuildFile; fileRef = ${ref};`);
    rootChildren.push(ref);
    resourceBuildFiles.push(build);
}
const plistRef = id();
obj(plistRef, 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "Resources/Info.plist"; sourceTree = "<group>";');
rootChildren.push(plistRef, productsGroup);
obj(appProduct, 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = IyoEditor.app; sourceTree = BUILT_PRODUCTS_DIR;');
obj(testProduct, 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = IyoEditorTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;');
obj(rootGroup, `isa = PBXGroup; children = ${list(rootChildren)}; sourceTree = "<group>";`);
obj(productsGroup, `isa = PBXGroup; children = ${list([appProduct, testProduct])}; name = Products; sourceTree = "<group>";`);
for (const [phase, kind, files] of [
    [appSourcesPhase, 'PBXSourcesBuildPhase', appBuildFiles],
    [appResourcesPhase, 'PBXResourcesBuildPhase', resourceBuildFiles],
    [appFrameworksPhase, 'PBXFrameworksBuildPhase', []],
    [testSourcesPhase, 'PBXSourcesBuildPhase', testBuildFiles],
    [testResourcesPhase, 'PBXResourcesBuildPhase', []],
    [testFrameworksPhase, 'PBXFrameworksBuildPhase', []]
]) obj(phase, `isa = ${kind}; buildActionMask = 2147483647; files = ${list(files)}; runOnlyForDeploymentPostprocessing = 0;`);
obj(proxy, `isa = PBXContainerItemProxy; containerPortal = ${projectId}; proxyType = 1; remoteGlobalIDString = ${appTarget}; remoteInfo = IyoEditor;`);
obj(dependency, `isa = PBXTargetDependency; target = ${appTarget}; targetProxy = ${proxy};`);
const projectConfigs = id(), appConfigs = id(), testConfigs = id();
function configurations(configList, settings) {
    const configurations = [];
    for (const name of ['Debug','Release']) {
        const configId = id(); configurations.push(configId);
        const common = name === 'Debug'
            ? 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;'
            : 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";';
        obj(configId, `isa = XCBuildConfiguration; buildSettings = { ${common} ${settings} }; name = ${name};`);
    }
    obj(configList, `isa = XCConfigurationList; buildConfigurations = ${list(configurations)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;`);
}
configurations(projectConfigs, 'IPHONEOS_DEPLOYMENT_TARGET = 17.0; SDKROOT = iphoneos; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0;');
configurations(appConfigs, 'PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_MODULE_NAME = IyoEditor; PRODUCT_BUNDLE_IDENTIFIER = local.iyo.editor.prototype; INFOPLIST_FILE = Resources/Info.plist; GENERATE_INFOPLIST_FILE = NO; TARGETED_DEVICE_FAMILY = 1; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SUPPORTS_MACCATALYST = NO; CODE_SIGNING_ALLOWED = NO; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";');
configurations(testConfigs, 'PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = local.iyo.editor.prototype.tests; GENERATE_INFOPLIST_FILE = YES; TARGETED_DEVICE_FAMILY = 1; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; CODE_SIGNING_ALLOWED = NO; BUNDLE_LOADER = "$(TEST_HOST)"; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/IyoEditor.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/IyoEditor"; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks";');
obj(appTarget, `isa = PBXNativeTarget; buildConfigurationList = ${appConfigs}; buildPhases = ${list([appSourcesPhase, appFrameworksPhase, appResourcesPhase])}; buildRules = (); dependencies = (); name = IyoEditor; productName = IyoEditor; productReference = ${appProduct}; productType = "com.apple.product-type.application";`);
obj(testTarget, `isa = PBXNativeTarget; buildConfigurationList = ${testConfigs}; buildPhases = ${list([testSourcesPhase, testFrameworksPhase, testResourcesPhase])}; buildRules = (); dependencies = ${list([dependency])}; name = IyoEditorTests; productName = IyoEditorTests; productReference = ${testProduct}; productType = "com.apple.product-type.bundle.unit-test";`);
obj(projectId, `isa = PBXProject; attributes = { LastUpgradeCheck = 2600; TargetAttributes = { ${testTarget} = { TestTargetID = ${appTarget}; }; }; }; buildConfigurationList = ${projectConfigs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = ja; hasScannedForEncodings = 0; knownRegions = (ja, en, Base); mainGroup = ${rootGroup}; productRefGroup = ${productsGroup}; projectDirPath = ""; projectRoot = ""; targets = ${list([appTarget, testTarget])};`);
const pbx = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + objects.join('\n') + `\n}; rootObject = ${projectId}; }\n`;
const scheme = `<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${appTarget}" BuildableName="IyoEditor.app" BlueprintName="IyoEditor" ReferencedContainer="container: IyoEditor.xcodeproj"/></BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${testTarget}" BuildableName="IyoEditorTests.xctest" BlueprintName="IyoEditorTests" ReferencedContainer="container: IyoEditor.xcodeproj"/></TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${appTarget}" BuildableName="IyoEditor.app" BlueprintName="IyoEditor" ReferencedContainer="container: IyoEditor.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugServiceExtension="internal"/>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
`;
for (const output of [projectDirectory, schemesDirectory]) {
    const rel = path.relative(root, output);
    if (rel.startsWith('..') || path.isAbsolute(rel)) throw new Error('Output outside workspace');
    fs.mkdirSync(output, {recursive:true});
}
fs.writeFileSync(path.join(projectDirectory, 'project.pbxproj'), pbx, 'utf8');
fs.writeFileSync(path.join(schemesDirectory, 'IyoEditor.xcscheme'), scheme, 'utf8');
console.log(`Generated ${relative(projectDirectory)} (${appSources.length} app sources, ${testSources.length} native test sources, ${resources.length} JS resources). Not built.`);
