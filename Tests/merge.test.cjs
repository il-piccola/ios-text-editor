'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
require('../Core/MergeCore.js');
const merge = globalThis.IyoMerge;

test('same production comparison combines independent line changes without mutating raw input', () => {
    const input = {base:'一\n二\n三\n四\n',local:'一変更\n二\n三\n四\n',remote:'一\n二\n三\n四変更\n'};
    const before = JSON.stringify(input), result = merge.compare(input);
    assert.equal(result.status, 'merged'); assert.equal(result.candidate, '一変更\n二\n三\n四変更\n');
    assert.deepEqual(result.raw, input); assert.equal(JSON.stringify(input), before);
    assert.equal(merge.resolve(result, []), result.candidate);
});
test('independent insertions and deletions keep both changes', () => {
    const result = merge.compare({base:'a\nb\nc\nd',local:'a\n追加\nb\nc\nd',remote:'a\nb\nc'});
    assert.equal(result.candidate, 'a\n追加\nb\nc'); assert.equal(result.status, 'merged');
});
test('same position different additions conflict while identical additions deduplicate', () => {
    const input = {base:'a\nb',local:'a\nlocal\nb',remote:'a\nremote\nb'};
    const result = merge.compare(input);
    assert.equal(result.candidate, null); assert.equal(result.conflictBlocks.length, 1);
    assert.equal(result.conflictBlocks[0].base, '');
    assert.equal(merge.resolve(result, ['local']), input.local);
    assert.equal(merge.resolve(result, ['remote']), input.remote);
    assert.equal(merge.resolve(result, ['base']), input.base);
    const same = merge.compare({...input,remote:input.local});
    assert.equal(same.candidate, input.local); assert.deepEqual(same.conflictBlocks, []);
});
test('overlapping replacement or delete preserves base and both variants as conflict', () => {
    const result = merge.compare({base:'a\nb\nc',local:'a\nc',remote:'a\nB\nc'});
    assert.equal(result.candidate, null); assert.equal(result.conflictBlocks[0].base, 'b');
    assert.deepEqual(result.conflictBlocks[0].localLines, []);
    assert.equal(merge.resolve(result, ['local']), 'a\nc');
    assert.equal(merge.resolve(result, ['remote']), 'a\nB\nc');
});
test('per conflict choices keep independent safe edits and allow different choices for each block', () => {
    const result = merge.compare({base:'a\nb\nc\nd\ne\nf\ng',local:'A\nBL\nc\nDL\ne\nf\ng',remote:'a\nBR\nc\nDR\ne\nf\nG'});
    assert.equal(result.conflictBlocks.length, 2); assert.equal(result.candidate, null);
    assert.equal(merge.resolve(result, ['local','remote']), 'A\nBL\nc\nDR\ne\nf\nG');
    assert.equal(merge.resolve(result, ['base','base']), 'A\nb\nc\nd\ne\nf\nG');
});
test('manual conflict text preserves Unicode and safe segments, normalizing only candidate line endings', () => {
    const result = merge.compare({base:'a\nb\nc\nd',local:'A\nlocal\nc\nd',remote:'a\nremote\nc\nD'});
    assert.equal(merge.resolve(result, [{kind:'manual',text:'か\u3099👨‍👩‍👧‍👦\r\n二\r三'}]), 'A\nか\u3099👨‍👩‍👧‍👦\n二\n三\nc\nD');
    assert.equal(merge.resolve(result, [{kind:'manual',text:''}]), 'A\nc\nD');
    assert.throws(() => merge.resolve(result, []), TypeError);
    for (const choice of ['both',null,{kind:'manual'},{kind:'manual',text:1},{kind:'manual',text:'x',extra:true}]) assert.throws(() => merge.resolve(result,[choice]), TypeError);
});
test('comparison ignores CR/LF differences only and retains all three original strings exactly', () => {
    const input = {base:'a\r\nb\r\n',local:'a\nb\n',remote:'a\rb\r'};
    const result = merge.compare(input);
    assert.equal(result.candidate,'a\nb\n'); assert.deepEqual(result.raw,input);
    const unicode = merge.compare({base:'x\ny',local:'が\ny',remote:'か\u3099\ny'});
    assert.equal(unicode.candidate,null); assert.equal(unicode.conflictBlocks[0].local,'が');
    assert.equal(unicode.conflictBlocks[0].remote,'か\u3099');
});
test('unmodified side uses other side, retaining empty document and trailing newline semantics', () => {
    for (const text of ['', '\n', '追加\n', '\uFFFD文字']) {
        const result = merge.compare({base:'原文',local:'原文',remote:text});
        assert.equal(result.candidate,text); assert.equal(result.raw.remote,text);
    }
});
test('ambiguous insertion on a replaced boundary is conservatively a conflict', () => {
    const result = merge.compare({base:'a\nb',local:'a\ninsert\nb',remote:'a\nB'});
    assert.equal(result.status,'conflict'); assert.equal(result.candidate,null);
});
test('LCS allocation budget stops broad comparisons and exposes whole originals', () => {
    const base = Array.from({length:1100},(_,i)=>'base'+i).join('\n');
    const local = Array.from({length:1100},(_,i)=>'local'+i).join('\n');
    const remote = 'remote\n'+base;
    const result = merge.compare({base,local,remote});
    assert.equal(result.limited,true); assert.equal(result.candidate,null);
    assert.equal(merge.resolve(result,['local']),local); assert.deepEqual(result.raw,{base,local,remote});
});
test('huge one-sided insert and delete cannot bypass allocation or row caps with zero dimensions', () => {
    const huge = Array.from({length:20001},(_,i)=>'row'+i).join('\n');
    const insert = merge.compare({base:'a\nb',local:'a\n'+huge+'\nb',remote:'A\nb'});
    const deletion = merge.compare({base:'a\n'+huge+'\nb',local:'a\nb',remote:'A\n'+huge+'\nb'});
    for (const result of [insert,deletion]) { assert.equal(result.limited,true); assert.equal(result.candidate,null); assert.equal(result.conflictBlocks.length,1); }
});
test('invalid comparison and resolution payloads fail closed', () => {
    for (const input of [null,{}, {base:1,local:'',remote:''}, {base:'',local:'',remote:null}]) assert.throws(()=>merge.compare(input),TypeError);
    assert.throws(()=>merge.resolve({schemaVersion:1},[]),TypeError);
    const result = merge.compare({base:'a',local:'b',remote:'c'});
    assert.throws(()=>merge.resolve({...result,segments:[{type:'unexpected'}]},['local']),TypeError);
});

test('repeated-line deletion has ambiguous anchors and requires explicit whole-document choice', () => {
    const result = merge.compare({base:'a\na\nb',local:'a\nb',remote:'A\na\nb'});
    assert.equal(result.ambiguous,true); assert.equal(result.limited,false);
    assert.equal(result.candidate,null); assert.equal(result.conflictBlocks.length,1);
    assert.equal(merge.resolve(result,['local']),'a\nb');
    assert.deepEqual(result.raw,{base:'a\na\nb',local:'a\nb',remote:'A\na\nb'});
});
