'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
require('../Core/SessionCore.js');
const core = globalThis.IyoCore;
const {MemoryProvider, DraftDisk} = require('./support/fakes.cjs');
const ID = '10000000-0000-4000-8000-000000000010';
const SESSION = '20000000-0000-4000-8000-000000000010';
function setup(t) {
    const provider = new MemoryProvider();
    const target = {...provider.add('file-r', '本文.txt', '基準版\r\n'), baseText:'基準版\r\n', format:'utf8'};
    const state = core.create({id:ID, sessionID:SESSION, name:'本文.txt', text:target.baseText,
        format:'utf8', lineEnding:'preserve', target, acceptedRevision:0});
    const disk = new DraftDisk(); t.after(() => disk.dispose());
    return {provider, state, disk};
}
function reduce(state, event) { return core.reduce(state, event); }
function edit(state, text, isComposing=false) {
    return reduce(state, {type:'EDIT', sessionID:state.sessionID, text, isComposing}).state;
}
function request(t, token='reload-1') {
    const context = setup(t);
    const first = reduce(context.state, {type:'RELOAD', token});
    assert.equal(first.effects.length, 1); assert.equal(first.effects[0].type, 'PERSIST');
    const reading = reduce(first.state, context.disk.persist(first.effects[0]));
    assert.equal(reading.effects.length, 1); assert.equal(reading.effects[0].type, 'READ');
    return {...context, state:reading.state, effect:reading.effects[0]};
}
function readReceipt(context, text) {
    context.provider.externalChange('file-r', text);
    return {type:'READ_OK', sessionID:context.effect.sessionID, token:context.effect.token,
        text, format:'utf8', target:{...context.provider.target('file-r'), baseText:text, format:'utf8'}};
}

test('manual reload protects draft first, suppresses repeated taps and conflicts with save/autosave', t => {
    const context = setup(t);
    const first = reduce(context.state, {type:'RELOAD', token:'r'});
    assert.equal(context.disk.load(ID), null);
    assert.deepEqual(reduce(first.state, {type:'RELOAD', token:'r2'}).effects, []);
    assert.deepEqual(reduce(first.state, {type:'SAVE', token:'save'}).effects, []);
    assert.deepEqual(reduce(first.state, {type:'AUTO_SAVE', token:'auto'}).effects, []);
    const reading = reduce(first.state, context.disk.persist(first.effects[0]));
    assert.equal(context.disk.load(ID).text, '基準版\r\n');
    assert.equal(reading.effects[0].type, 'READ');
    assert.deepEqual(reduce(reading.state, {type:'RELOAD', token:'r3'}).effects, []);
    assert.deepEqual(reduce(reading.state, {type:'AUTO_SAVE', token:'auto2'}).effects, []);
});

test('local draft failure prevents any external reload', t => {
    const context = setup(t); context.disk.failNext = true;
    const first = reduce(edit(context.state, '手元の編集'), {type:'RELOAD', token:'r'});
    const failed = reduce(first.state, context.disk.persist(first.effects[0]));
    assert.deepEqual(failed.effects, []); assert.equal(failed.state.operation, null);
    assert.equal(failed.state.text, '手元の編集'); assert.ok(failed.state.draftError);
});

test('typing during reload keeps latest local text and exposes a three-way candidate without replacing text', t => {
    const context = request(t);
    const edited = edit(context.state, '読込中の追記\r\n');
    const completed = reduce(edited, readReceipt(context, '外部最新版\r\n'));
    assert.equal(completed.state.text, '読込中の追記\r\n');
    assert.equal(completed.state.revision, 1); assert.equal(completed.state.acceptedRevision, 0);
    assert.equal(completed.state.remoteCandidate.baseText, '基準版\r\n');
    assert.equal(completed.state.remoteCandidate.localText, '読込中の追記\r\n');
    assert.equal(completed.state.remoteCandidate.text, '外部最新版\r\n');
    assert.equal(completed.state.remoteCandidate.observedRevision, 1);
    assert.equal(completed.state.remoteCandidate.snapshotRevision, 0);
    assert.deepEqual(completed.state.target, context.state.target);
});

test('unedited reload also leaves application to the sole editor owner and retains raw external text', t => {
    const context = request(t);
    const result = reduce(context.state, readReceipt(context, '外部の新しい本文\r\n'));
    assert.equal(result.state.text, '基準版\r\n');
    assert.equal(result.state.remoteCandidate.text, '外部の新しい本文\r\n');
    assert.equal(result.state.operation, null);
});

test('late, old-session, cancelled and wrong-identity read responses cannot replace the candidate', t => {
    const context = request(t);
    const receipt = readReceipt(context, 'remote');
    for (const event of [
        {...receipt, token:'old-token'}, {...receipt, sessionID:'different-document-runtime'},
        {...receipt, target:{...receipt.target, identity:'wrong-file'}}
    ]) {
        const result = reduce(context.state, event);
        assert.equal(result.state.text, '基準版\r\n');
        assert.equal(result.state.remoteCandidate, null);
        assert.equal(result.state.operation.phase, 'reading');
    }
    const cancelled = reduce(context.state, {type:'CANCEL', sessionID:SESSION, token:context.effect.token});
    const late = reduce(cancelled.state, receipt);
    assert.equal(late.state.remoteCandidate, null); assert.equal(late.state.text, '基準版\r\n');
    const otherDocument = core.create({id:'other-doc',sessionID:'other-session',text:'別文書'});
    assert.equal(reduce(otherDocument, receipt).state.text, '別文書');
});

test('offline, permission loss and deleted destination preserve current draft and baseline', t => {
    for (const code of ['offline','permission','missingFile']) {
        const context = request(t, 'reload-' + code);
        const changed = edit(context.state, '保持する手元の本文');
        const protectedDraft = reduce(changed, {type:'PROTECT',token:'draft-' + code});
        const acknowledged = reduce(protectedDraft.state, context.disk.persist(protectedDraft.effects[0]));
        const failed = reduce(acknowledged.state, {type:'READ_FAILED',sessionID:SESSION,
            token:context.effect.token,code,message:'検証用読込失敗'});
        assert.equal(failed.state.text, '保持する手元の本文');
        assert.equal(context.disk.load(ID).text, '保持する手元の本文');
        assert.deepEqual(failed.state.target, context.state.target);
        assert.equal(failed.state.fileErrorCode, code); assert.equal(failed.state.operation, null);
    }
});

test('reload is blocked during composition and unknown write outcome still allows safe read', t => {
    const context = setup(t);
    const composing = edit(context.state, '変換中', true);
    assert.deepEqual(reduce(composing, {type:'RELOAD',token:'blocked'}).effects, []);
    const saving = reduce(edit(context.state, '保存する本文'), {type:'SAVE',token:'write'});
    const writing = reduce(saving.state, context.disk.persist(saving.effects[0]));
    const unknown = reduce(writing.state, {type:'WRITE_FAILED',sessionID:SESSION,token:'write',
        code:'unknownOutcome',message:'書込後の応答がありません'});
    assert.deepEqual(reduce(unknown.state, {type:'AUTO_SAVE',token:'unsafe-retry'}).effects, []);
    const reload = reduce(unknown.state, {type:'RELOAD',token:'safe-read'});
    assert.equal(reload.effects[0].type, 'PERSIST');
    assert.equal(reduce(reload.state, context.disk.persist(reload.effects[0])).effects[0].type, 'READ');
});
