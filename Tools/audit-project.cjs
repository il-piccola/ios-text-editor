'use strict';
// Read-only packaging checks. This does not parse or compile an Xcode project.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const pbx = read('IyoEditor.xcodeproj/project.pbxproj');
const objects = new Map([...pbx.matchAll(/^([0-9A-F]{24}) = \{ (.+) \};$/gm)].map(m => [m[1], m[2]]));
for (const m of pbx.matchAll(/\b[0-9A-F]{24}\b/g)) assert.ok(objects.has(m[0]), 'Unresolved project ID');
const refs = new Map();
const builds = new Map();
for (const [id, body] of objects) {
    if (body.startsWith('isa = PBXFileReference;')) {
        const match = body.match(/path = "([^"]+)"/);
        if (match) {
            refs.set(id, match[1]);
            assert.ok(fs.existsSync(path.join(root, match[1])), 'Missing reference: ' + match[1]);
        }
    }
    if (body.startsWith('isa = PBXBuildFile;')) builds.set(id, body.match(/fileRef = ([0-9A-F]{24})/)[1]);
}
function phaseFiles(kind) {
    return [...objects.values()].filter(body => body.startsWith('isa = ' + kind + ';'))
        .flatMap(body => [...body.match(/files = \(([^)]*)\)/)[1].matchAll(/[0-9A-F]{24}/g)]
            .map(m => refs.get(builds.get(m[0]))));
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
function walk(directory) {
    return fs.readdirSync(directory, {withFileTypes: true}).filter(e => e.name !== '.git').flatMap(e => {
        const p = path.join(directory, e.name);
        assert.ok(!e.isSymbolicLink(), 'Unexpected symbolic link');
        return e.isDirectory() ? walk(p) : [p];
    });
}
const decoder = new TextDecoder('utf-8', {fatal: true});
const files = walk(root);
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
