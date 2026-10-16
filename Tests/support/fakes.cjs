'use strict';
// Original test adapters. Memory provider is deliberately NOT Google Drive/Files.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');

function clone(value) { return JSON.parse(JSON.stringify(value)); }
function encode(text, format, lineEnding = 'preserve') {
    if (!['crlf', 'preserve'].includes(lineEnding)) throw new Error('Unsupported line ending');
    if (lineEnding === 'crlf') text = text.replace(/\r\n|\r|\n/g, '\r\n');
    const bytes = Buffer.from(text, format === 'utf16LE' || format === 'utf16BE' ? 'utf16le' : 'utf8');
    if (format === 'utf8') return bytes;
    if (format === 'utf8BOM') return Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), bytes]);
    if (format === 'utf16LE') return Buffer.concat([Buffer.from([0xff, 0xfe]), bytes]);
    if (format === 'utf16BE') return Buffer.concat([Buffer.from([0xfe, 0xff]), bytes.swap16()]);
    throw new Error('Unsupported format');
}
function baseline(bytes) {
    return {sha256: crypto.createHash('sha256').update(bytes).digest('hex'), byteCount: bytes.length};
}
function matches(left, right) {
    return left.sha256 === right.sha256 && left.byteCount === right.byteCount;
}
class MemoryProvider {
    constructor() { this.files = new Map(); this.writeCount = 0; this.createCount = 0; this.failure = null; }
    add(identity, name, text, format = 'utf8', lineEnding = 'preserve') {
        const baseText = lineEnding === 'crlf' ? text.replace(/\r\n|\r|\n/g, '\r\n') : text;
        this.files.set(identity, {identity, name, location: '偽保存先 / フォルダ', bytes: encode(text, format, lineEnding), baseText, format, lineEnding, writable: true});
        return this.target(identity);
    }
    target(identity) {
        const file = this.files.get(identity);
        return {identity, name: file.name, location: file.location, baseline: baseline(file.bytes), baseText:file.baseText, format:file.format, lineEnding:file.lineEnding};
    }
    externalChange(identity, text, format = 'utf8') { const file = this.files.get(identity); file.bytes = encode(text, format); file.baseText = text; file.format = format; file.lineEnding = 'preserve'; }
    revoke(identity) { this.files.get(identity).writable = false; }
    write(effect) {
        this.writeCount += 1;
        const callback = {sessionID: effect.sessionID, token: effect.token};
        const failure = (code, message) => ({type: 'WRITE_FAILED', ...callback, code, message});
        if (this.failure) return failure(this.failure, '偽保存先のエラー');
        if (effect.kind === 'existing') {
            const expected = effect.snapshot.target;
            const file = this.files.get(expected.identity);
            if (!file) return failure('missingFile', '保存先がありません');
            if (!file.writable) return failure('permission', 'アクセス権限がありません');
            if (!matches(baseline(file.bytes), expected.baseline)) return failure('conflict', '外部で変更されています');
            file.bytes = encode(effect.snapshot.text, effect.snapshot.format, effect.snapshot.lineEnding);
            file.baseText = effect.snapshot.lineEnding === 'crlf' ? effect.snapshot.text.replace(/\r\n|\r|\n/g, '\r\n') : effect.snapshot.text;
            file.format = effect.snapshot.format; file.lineEnding = effect.snapshot.lineEnding;
            return {type: 'WRITE_OK', ...callback, revision: effect.snapshot.revision, target: this.target(file.identity)};
        }
        // saveAs refuses occupied names; it never silently overwrites or adds a suffix.
        if ([...this.files.values()].some(file => file.name === effect.name)) return failure('nameCollision', '同名ファイルがあります。別の名前を入力してください');
        this.createCount += 1;
        const identity = 'fake-new-' + this.createCount;
        this.add(identity, effect.name, effect.snapshot.text, effect.snapshot.format, effect.snapshot.lineEnding);
        return {type: 'WRITE_OK', ...callback, revision: effect.snapshot.revision, target: this.target(identity)};
    }
}
class DraftDisk {
    constructor(directory) {
        this.directory = directory || fs.mkdtempSync(path.join(os.tmpdir(), 'iyo-core-tests-'));
        this.ownedDirectory = !directory;
        fs.mkdirSync(this.directory, {recursive: true});
        this.failNext = false;
    }
    file(id) { return path.join(this.directory, encodeURIComponent(id) + '.json'); }
    load(id) {
        const file = this.file(id);
        return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : null;
    }
    persist(effect) {
        const env = clone(effect.envelope);
        const callback = {sessionID: effect.sessionID, token: effect.token};
        if (this.failNext) { this.failNext = false; return {type: 'DRAFT_FAILED', ...callback, message: '端末下書きを保存できません'}; }
        const old = this.load(env.id);
        if (old && (old.epoch > env.epoch || old.revision > env.revision)) {
            return {type: 'DRAFT_FAILED', ...callback, code: 'staleDraft', message: '古い下書きの書込みを拒否しました'};
        }
        if (old && old.epoch === env.epoch && JSON.stringify(old) !== JSON.stringify(env)) {
            return {type: 'DRAFT_FAILED', ...callback, message: '同じ epoch の異なる下書きを拒否しました'};
        }
        if (!old || old.epoch < env.epoch) {
            const file = this.file(env.id), auxiliary = file + '.tmp';
            fs.writeFileSync(auxiliary, JSON.stringify(env), {encoding: 'utf8'});
            fs.renameSync(auxiliary, file);
        }
        return {type: 'DRAFT_OK', ...callback, revision: env.revision, epoch: env.epoch};
    }
    dispose() {
        if (!this.ownedDirectory) return;
        // Delete only known flat test files in the exact directory created above.
        const resolved = path.resolve(this.directory);
        const allowed = path.resolve(os.tmpdir()) + path.sep;
        if (!resolved.startsWith(allowed) || !path.basename(resolved).startsWith('iyo-core-tests-')) throw new Error('Unsafe test cleanup');
        for (const entry of fs.readdirSync(resolved, {withFileTypes: true})) {
            if (!entry.isFile() || !/\.json(?:\.tmp)?$/.test(entry.name)) throw new Error('Unexpected test file');
            fs.unlinkSync(path.join(resolved, entry.name));
        }
        fs.rmdirSync(resolved);
    }
}
module.exports = {MemoryProvider, DraftDisk, encode, baseline};
