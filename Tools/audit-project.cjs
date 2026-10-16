'use strict';
// Read-only packaging checks. Parses project structure; does not compile or sign it.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const {execFileSync} = require('node:child_process');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const pbx = read('IyoEditor.xcodeproj/project.pbxproj');
// Xcode rewrites generated one-line objects as commented, multiline OpenStep plists.
// Keep strings intact while tokenizing, including comment-like text inside paths.
function parseProject(source) {
    const tokens = [];
    const pattern = /\s+|\/\*[\s\S]*?\*\/|\/\/[^\r\n]*|"(?:\\[\s\S]|[^"\\])*"|[{}()=;,]|(?:[^\s{}()=;,"\/]|\/(?![/*]))+/gy;
    let offset = 0;
    while (offset < source.length) {
        pattern.lastIndex = offset;
        const match = pattern.exec(source);
        assert.ok(match, 'Unsupported project syntax');
        const token = match[0];
        offset = pattern.lastIndex;
        if (!/^\s|^\/\*|^\/\//.test(token)) tokens.push(token);
    }
    let index = 0;
    function expect(token) {
        assert.ok(tokens[index++] === token, 'Malformed project structure');
    }
    function scalar() {
        const token = tokens[index++];
        assert.ok(token !== undefined && !/^[{}()=;,]$/.test(token), 'Missing project value');
        if (!token.startsWith('"')) return token;
        return token.slice(1, -1).replace(/\\(U[0-9a-fA-F]{4}|[0-7]{3}|[\s\S])/g, (_, escape) => {
            if (escape.startsWith('U')) return String.fromCharCode(parseInt(escape.slice(1), 16));
            if (/^[0-7]{3}$/.test(escape)) return String.fromCharCode(parseInt(escape, 8));
            return ({ n: '\n', r: '\r', t: '\t' })[escape] ?? escape;
        });
    }
    function value() {
        if (tokens[index] === '{') {
            index++;
            const dictionary = Object.create(null);
            while (tokens[index] !== '}') {
                const key = scalar();
                expect('=');
                assert.ok(!Object.hasOwn(dictionary, key), 'Duplicate project key');
                dictionary[key] = value();
                expect(';');
            }
            index++;
            return dictionary;
        }
        if (tokens[index] === '(') {
            index++;
            const entries = [];
            while (tokens[index] !== ')') {
                entries.push(value());
                if (tokens[index] === ')') break;
                expect(',');
            }
            index++;
            return entries;
        }
        return scalar();
    }
    const project = value();
    assert.ok(index === tokens.length && project.objects, 'Incomplete project structure');
    return project;
}
const objects = new Map(Object.entries(parseProject(pbx).objects));
const scheme = read('IyoEditor.xcodeproj/xcshareddata/xcschemes/IyoEditor.xcscheme');
const schemeReferences = [...scheme.matchAll(/<BuildableReference\b[^>]*\/>/g)];
assert.equal(schemeReferences.length, 3, 'Expected build, test, and launch references');
for (const [reference] of schemeReferences) {
    assert.equal(reference.match(/ReferencedContainer="([^"]+)"/)?.[1],
        'container:IyoEditor.xcodeproj', 'Invalid scheme container path');
    const target = reference.match(/BlueprintIdentifier="([^"]+)"/)?.[1];
    assert.ok(objects.get(target)?.isa === 'PBXNativeTarget', 'Unresolved scheme target');
}
for (const m of pbx.matchAll(/\b[0-9A-F]{24}\b/g)) assert.ok(objects.has(m[0]), 'Unresolved project ID');
const refs = new Map();
const builds = new Map();
for (const [id, body] of objects) {
    if (body.isa === 'PBXFileReference') {
        if (body.path && body.sourceTree !== 'BUILT_PRODUCTS_DIR') {
            refs.set(id, body.path);
            assert.ok(fs.existsSync(path.join(root, body.path)), 'Missing project file reference');
        }
    }
    if (body.isa === 'PBXBuildFile') builds.set(id, body.fileRef);
}
function phaseFiles(kind) {
    return [...objects.values()].filter(body => body.isa === kind)
        .flatMap(body => body.files.map(id => refs.get(builds.get(id))));
}
const list = (directory, suffix) => fs.readdirSync(path.join(root, directory)).filter(p => p.endsWith(suffix)).map(p => directory + '/' + p);
const swift = ['App', 'Storage', 'Editor', 'UI', 'NativeTests'].flatMap(d => list(d, '.swift')).sort();
const resources = ['Core', 'Editor'].flatMap(d => list(d, '.js')).sort();
assert.deepEqual(phaseFiles('PBXSourcesBuildPhase').sort(), swift);
assert.deepEqual(phaseFiles('PBXResourcesBuildPhase').sort(), resources);
assert.ok(!pbx.includes('PBXShellScriptBuildPhase'), 'Unexpected automatic script');
const license = fs.readFileSync(path.join(root, 'ThirdParty/Edhita-LICENSE.txt'));
assert.equal(crypto.createHash('sha256').update(license).digest('hex').toUpperCase(),
    '11983290D3E5744C4D42C804DEEB698875E987BB631EA3C8F13B64DA8A874DAA');
const decoder = new TextDecoder('utf-8', {fatal: true});
// Xcode user state and private local signing settings are ignored workspace data,
// not packaged sources. Never read them as text or traverse build output.
const files = execFileSync('git', ['ls-files', '--cached', '--others', '--exclude-standard', '-z'],
    {cwd: root, encoding: 'utf8'}).split('\0').filter(Boolean).map(file => path.join(root, file));
for (const file of files) assert.ok(!fs.lstatSync(file).isSymbolicLink(), 'Unexpected symbolic link');
let links = 0;
for (const file of files) {
    const text = decoder.decode(fs.readFileSync(file));
    assert.ok(!text.includes('\uFFFD'), 'Invalid replacement character');
    if (!file.endsWith('.md')) continue;
    for (const match of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
        const target = match[1].replace(/^<|>$/g, '').split('#')[0];
        if (!target || /^[a-z][a-z\d+.-]*:/i.test(target)) continue;
        assert.ok(fs.existsSync(path.resolve(path.dirname(file), target)), 'Missing relative link');
        links++;
    }
}
console.log(JSON.stringify({kind: 'static-packaging',files: files.length,swiftSources: swift.length,
    jsResources: resources.length,localLinks: links,edhitaLicensePreserved: true,
    swiftCompiled: false,iosExecuted: false}));
