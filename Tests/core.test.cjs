'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
require('../Core/SessionCore.js'); // The production JavaScript reducer, unchanged.
const core = globalThis.IyoCore;
const {MemoryProvider, DraftDisk, encode, baseline} = require('./support/fakes.cjs');

const ID = '10000000-0000-4000-8000-000000000001';
const SESSION = '20000000-0000-4000-8000-000000000001';
function start(extra = {}) { return core.create({id: ID, sessionID: SESSION, ...extra}); }
function edit(state, text, isComposing = false) { return core.reduce(state, {type: 'EDIT', sessionID: state.sessionID, text, isComposing}).state; }
function apply(state, event) { return core.reduce(state, event); }
function diskFor(t) { const disk = new DraftDisk(); t.after(() => disk.dispose()); return disk; }
function beginWrite(t, state, token = 'save-1', type = 'SAVE', name) {
    const disk = diskFor(t);
    const event = {type, token}; if (name !== undefined) event.name = name;
    const protectedResult = apply(state, event);
    assert.equal(protectedResult.effects[0].type, 'PERSIST');
    const writingResult = apply(protectedResult.state, disk.persist(protectedResult.effects[0]));
    assert.equal(writingResult.effects[0].type, 'WRITE');
    return {disk, state: writingResult.state, effect: writingResult.effects[0]};
}

test('production reducer is pure JSON with no hidden effects or input mutation', () => {
    const seed = {id: ID, sessionID: SESSION, text: '本文'};
    const original = JSON.stringify(seed); const state = core.create(seed);
    const event = {type: 'SAVE_AS', token: 's'};
    const before = JSON.stringify(state);
    const a = core.reduce(state, event), b = core.reduce(state, event);
    assert.deepEqual(a, b); assert.equal(JSON.stringify(state), before); assert.equal(JSON.stringify(seed), original);
    a.effects[0].envelope.text = 'effect mutation'; assert.equal(a.state.text, '本文');
    assert.equal(a.state.operation.snapshot.text, '本文');
});

test('save waits for successful draft and ignores rapid taps in protecting/writing phases', t => {
    const provider = new MemoryProvider(); const target = provider.add('file-a', '文章.txt', 'old');
    const disk = diskFor(t); const state = edit(start({target}), 'new');
    const first = apply(state, {type: 'SAVE', token: 'one'});
    assert.equal(first.effects.length, 1); assert.equal(provider.writeCount, 0);
    const twice = apply(first.state, {type: 'SAVE', token: 'two'}); assert.deepEqual(twice.effects, []);
    const writing = apply(twice.state, disk.persist(first.effects[0]));
    assert.equal(writing.effects.length, 1);
    assert.deepEqual(apply(writing.state, {type: 'SAVE', token: 'three'}).effects, []);
    assert.deepEqual(apply(writing.state, disk.persist(first.effects[0])).effects, []);
    const done = apply(writing.state, provider.write(writing.effects[0]));
    assert.equal(provider.writeCount, 1); assert.equal(done.effects[0].type, 'PERSIST');
    assert.equal(done.state.cloudStatus, 'unconfirmed');
    const metadataDone = apply(done.state, disk.persist(done.effects[0]));
    assert.deepEqual(metadataDone.effects, []); assert.equal(provider.writeCount, 1);
});

test('typing during save retains current text and accepted revision refers to captured snapshot', t => {
    const provider = new MemoryProvider(); const target = provider.add('file-a', '文章.txt', 'old');
    const begun = beginWrite(t, edit(start({target}), 'snapshot'));
    const newer = edit(begun.state, 'snapshot + 追記');
    const done = apply(newer, provider.write(begun.effect));
    assert.equal(done.state.text, 'snapshot + 追記'); assert.equal(done.state.revision, 2);
    assert.equal(done.state.acceptedRevision, 1); assert.equal(provider.files.get('file-a').bytes.toString(), 'snapshot');
    assert.equal(done.effects[0].envelope.text, 'snapshot + 追記');
    const protectedNew = apply(done.state, begun.disk.persist(done.effects[0]));
    assert.equal(protectedNew.state.protectedRevision, 2); assert.equal(protectedNew.state.acceptedRevision, 1);
});

test('typing before draft acknowledgement also keeps original WRITE snapshot', t => {
    const provider = new MemoryProvider(); const target = provider.add('file-a', 'a.txt', 'old');
    const disk = diskFor(t); const first = apply(edit(start({target}), 'one'), {type: 'SAVE', token: 's'});
    const newer = edit(first.state, 'two'); const ack = apply(newer, disk.persist(first.effects[0]));
    assert.equal(ack.effects[0].snapshot.text, 'one'); assert.equal(ack.state.text, 'two');
    assert.equal(ack.state.protectedRevision, 1); assert.equal(ack.state.revision, 2);
});

test('failed draft never authorizes provider WRITE and retry preserves text', t => {
    const disk = diskFor(t); const state = edit(start(), 'recover me');
    const first = apply(state, {type: 'SAVE_AS', token: 'failed'}); disk.failNext = true;
    const failed = apply(first.state, disk.persist(first.effects[0]));
    assert.deepEqual(failed.effects, []); assert.equal(failed.state.operation, null);
    assert.equal(failed.state.text, 'recover me'); assert.equal(failed.state.protectedRevision, -1); assert.ok(failed.state.draftError);
    const retried = apply(failed.state, {type: 'SAVE_AS', token: 'retry'});
    assert.equal(apply(retried.state, disk.persist(retried.effects[0])).effects[0].type, 'WRITE');
});

test('cancel before protection suppresses late ACK; cancel during WRITE ignores late acceptance', t => {
    const disk = diskFor(t); const provider = new MemoryProvider();
    const p = apply(edit(start(), 'draft'), {type: 'SAVE_AS', token: 'cancel-before'});
    const cancelled = apply(p.state, {type: 'CANCEL', sessionID: SESSION, token: 'cancel-before'});
    assert.deepEqual(apply(cancelled.state, disk.persist(p.effects[0])).effects, []);
    assert.equal(cancelled.state.text, 'draft');
    const writing = beginWrite(t, cancelled.state, 'cancel-write', 'SAVE_AS');
    const cancelWrite = apply(writing.state, {type: 'CANCEL', sessionID: SESSION, token: 'cancel-write'});
    const lateReceipt = provider.write(writing.effect);
    const late = apply(cancelWrite.state, lateReceipt);
    assert.equal(late.state.target, null); assert.equal(late.state.acceptedRevision, null); assert.deepEqual(late.effects, []);
    // A cancellation cannot roll back an external write already performed by the provider.
    assert.equal(provider.createCount, 1);
});

test('permission loss, disconnect and external changes retain draft and avoid overwrite', t => {
    for (const mode of ['permission', 'offline', 'conflict']) {
        const provider = new MemoryProvider(); const target = provider.add('file-a', 'a.txt', 'original');
        const begun = beginWrite(t, edit(start({target}), 'our change'), 'save-' + mode);
        if (mode === 'permission') provider.revoke('file-a');
        if (mode === 'offline') provider.failure = 'offline';
        if (mode === 'conflict') provider.externalChange('file-a', 'other device');
        const result = apply(begun.state, provider.write(begun.effect));
        assert.equal(result.state.text, 'our change'); assert.equal(result.state.protectedRevision, 1);
        assert.equal(begun.disk.load(ID).text, 'our change'); assert.equal(result.state.acceptedRevision, null);
        assert.equal(result.state.fileErrorCode, mode); assert.equal(result.state.conflict, mode === 'conflict');
        assert.equal(provider.files.get('file-a').bytes.toString(), mode === 'conflict' ? 'other device' : 'original');
        if (mode === 'conflict') assert.deepEqual(apply(result.state, {type: 'SAVE', token: 'blocked'}).effects, []);
    }
});

test('same text still checks baseline; same name does not identify the file; saveAs creates a distinctly named new identity', t => {
    const provider = new MemoryProvider(); const first = provider.add('id-first', '同名.txt', 'one');
    provider.add('id-second', '同名.txt', 'two');
    const begun = beginWrite(t, start({text: 'one', target: first, acceptedRevision: 0}));
    provider.externalChange('id-first', 'external');
    const result = apply(begun.state, provider.write(begun.effect)); assert.equal(result.state.conflict, true);
    const newFile = beginWrite(t, result.state, 'new-id', 'SAVE_AS', '新しい名前.txt');
    const done = apply(newFile.state, provider.write(newFile.effect));
    assert.equal(done.state.target.identity, 'fake-new-1');
    assert.equal(provider.files.get('id-first').bytes.toString(), 'external');
    assert.equal(provider.files.get('id-second').bytes.toString(), 'two');
});

test('old, wrong revision, wrong target and wrong session receipts cannot claim a save', t => {
    const provider = new MemoryProvider(); const target = provider.add('file-a', 'a.txt', 'old');
    const begun = beginWrite(t, edit(start({target}), 'new'));
    const receipt = provider.write(begun.effect);
    const altered = [
        {...receipt, token: 'old'}, {...receipt, revision: 999}, {...receipt, sessionID: 'other-session'},
        {...receipt, target: {...receipt.target, identity: 'different-file'}}
    ];
    for (const event of altered) {
        const result = apply(begun.state, event); assert.deepEqual(result.effects, []);
        assert.equal(result.state.acceptedRevision, null); assert.equal(result.state.operation.phase, 'writing');
    }
    const done = apply(begun.state, receipt); assert.equal(done.state.acceptedRevision, 1);
    assert.deepEqual(apply(done.state, receipt).effects, []);
    assert.deepEqual(apply(done.state, {type: 'SAVE', token: begun.effect.token}).effects, []);
});

test('disk epoch prevents reordered draft writes, including same-revision metadata', t => {
    const disk = diskFor(t); let state = edit(start(), 'first');
    const old = apply(state, {type: 'PROTECT', token: 'old'}); state = edit(old.state, 'second');
    const newer = apply(state, {type: 'PROTECT', token: 'new'});
    const newAck = disk.persist(newer.effects[0]), oldAck = disk.persist(old.effects[0]);
    assert.equal(oldAck.type, 'DRAFT_FAILED'); assert.equal(oldAck.code, 'staleDraft');
    assert.equal(disk.load(ID).text, 'second');
    const a = apply(newer.state, newAck); const b = apply(a.state, oldAck);
    assert.equal(b.state.protectedRevision, 2); assert.deepEqual(b.effects, []);
    assert.equal(b.state.draftError, null);
    const sameRev = apply(b.state, {type: 'PROTECT', token: 'metadata-like'});
    assert.equal(sameRev.effects[0].envelope.revision, 2); assert.equal(sameRev.effects[0].envelope.epoch, 3);
    disk.persist(sameRev.effects[0]); disk.persist(newer.effects[0]); assert.equal(disk.load(ID).epoch, 3);
    const collision = {...sameRev.effects[0], envelope: {...sameRev.effects[0].envelope, text: 'wrong'}};
    assert.equal(disk.persist(collision).type, 'DRAFT_FAILED'); assert.equal(disk.load(ID).text, 'second');
});

test('saveAs name collision fails without overwrite, suffix or identity allocation; retry requires another name', t => {
    const provider = new MemoryProvider(); provider.add('existing-id', '同名.txt', 'existing');
    const begun = beginWrite(t, edit(start(), 'our text'), 'collision', 'SAVE_AS', '同名.txt');
    const result = apply(begun.state, provider.write(begun.effect));
    assert.equal(result.state.fileErrorCode, 'nameCollision'); assert.equal(result.state.operation, null);
    assert.equal(result.state.target, null); assert.equal(result.state.text, 'our text');
    assert.equal(provider.createCount, 0); assert.equal(provider.files.size, 1);
    assert.equal(provider.files.get('existing-id').bytes.toString(), 'existing');
    assert.equal(begun.disk.load(ID).text, 'our text');
    const retry = beginWrite(t, result.state, 'new-name', 'SAVE_AS', '別名.txt');
    const done = apply(retry.state, provider.write(retry.effect));
    assert.equal(done.state.target.name, '別名.txt'); assert.equal(provider.createCount, 1);
});

test('saveAs rejects same-token same-revision receipts with an unrequested suffix or normalized name', t => {
    const provider = new MemoryProvider();
    const requestedName = 'か\u3099.txt';
    const begun = beginWrite(t, edit(start(), '大切な本文'), 'requested-name', 'SAVE_AS', requestedName);
    const receipt = provider.write(begun.effect);
    for (const wrongName of ['か\u3099 2.txt', 'が.txt']) {
        const wrong = {...receipt, target: {...receipt.target, name: wrongName}};
        const rejected = apply(begun.state, wrong);
        assert.deepEqual(rejected.effects, []); assert.equal(rejected.state.acceptedRevision, null);
        assert.equal(rejected.state.target, null); assert.equal(rejected.state.text, '大切な本文');
        assert.equal(rejected.state.operation.phase, 'writing');
        assert.equal(rejected.state.operation.name, requestedName);
    }
    const accepted = apply(begun.state, receipt);
    assert.equal(accepted.state.acceptedRevision, 1); assert.equal(accepted.state.target.name, requestedName);
});

test('incorrect or stale draft receipts do not release the save barrier or regress protection', t => {
    const disk = diskFor(t); const p = apply(edit(start(), '本文'), {type: 'SAVE_AS', token: 'current'});
    const valid = disk.persist(p.effects[0]);
    for (const event of [
        {...valid, epoch: valid.epoch + 1}, {...valid, revision: valid.revision + 1},
        {...valid, token: 'old-token'}, {...valid, sessionID: 'old-session'},
        {type: 'DRAFT_FAILED', sessionID: 'old-session', token: 'current', message: 'old failure'}
    ]) {
        const ignored = apply(p.state, event); assert.deepEqual(ignored.effects, []);
        assert.equal(ignored.state.operation.phase, 'protecting'); assert.equal(ignored.state.protectedRevision, -1);
    }
    const writing = apply(p.state, valid); assert.equal(writing.effects[0].type, 'WRITE');
    assert.deepEqual(apply(writing.state, valid).effects, []);
});

test('missing destination returns failure and preserves the protected draft', t => {
    const provider = new MemoryProvider(); const target = provider.add('file-a', 'a.txt', 'old');
    const begun = beginWrite(t, edit(start({target}), 'new'));
    provider.files.delete('file-a'); const result = apply(begun.state, provider.write(begun.effect));
    assert.equal(result.state.fileErrorCode, 'missingFile'); assert.equal(result.state.text, 'new');
    assert.equal(begun.disk.load(ID).text, 'new'); assert.equal(result.state.acceptedRevision, null);
});

test('restart restores disk draft and target, never revives WRITE, and uses a new session', t => {
    const provider = new MemoryProvider(); const target = provider.add('file-a', 'a.txt', 'old');
    const begun = beginWrite(t, edit(start({target}), 'new'));
    const lateReceipt = provider.write(begun.effect);
    const restored = core.restore(begun.disk.load(ID));
    assert.equal(restored.operation, null); assert.equal(restored.sessionID, null); assert.equal(restored.protectedRevision, 1);
    assert.throws(() => apply(restored, {type: 'SAVE', token: 'new-session-write'}), /sessionID/);
    restored.sessionID = 'new-runtime-session';
    assert.deepEqual(apply(restored, lateReceipt).effects, []); assert.equal(restored.acceptedRevision, null);
    assert.equal(restored.uncertain,true);
    assert.deepEqual(apply(restored,{type:'SAVE',token:'new-session-write'}).effects,[]);
    const conflict = apply(restored,{type:'REMOTE_OBSERVED',sessionID:restored.sessionID,target:provider.target('file-a')});
    assert.equal(conflict.state.conflict, true); assert.equal(conflict.state.text, 'new');
});

test('completed acceptance metadata persists and restore remembers accepted revision', t => {
    const provider = new MemoryProvider(); const target = provider.add('file-a', 'a.txt', 'old');
    const begun = beginWrite(t, edit(start({target}), 'new'));
    const done = apply(begun.state, provider.write(begun.effect));
    const result = apply(done.state, begun.disk.persist(done.effects[0]));
    assert.deepEqual(result.effects, []);
    const restored = core.restore(begun.disk.load(ID));
    assert.equal(restored.acceptedRevision, 1); assert.deepEqual(restored.target, done.state.target);
});

test('failed acceptance metadata leaves durable draft and restart conservatively checks old baseline', t => {
    const provider = new MemoryProvider(); const target = provider.add('file-a', 'a.txt', 'old');
    const begun = beginWrite(t, edit(start({target}), 'new'));
    const done = apply(begun.state, provider.write(begun.effect)); begun.disk.failNext = true;
    const failed = apply(done.state, begun.disk.persist(done.effects[0]));
    assert.ok(failed.state.draftError); assert.equal(failed.state.acceptedRevision, 1);
    assert.equal(core.restore(begun.disk.load(ID)).acceptedRevision, null);
    assert.equal(begun.disk.load(ID).text, 'new');
});

test('document IDs keep same-name drafts separate and old document callback cannot affect another', t => {
    const disk = diskFor(t); const first = apply(edit(start({name: '同名.txt'}), 'first'), {type: 'PROTECT', token: 'a'});
    const secondID = '10000000-0000-4000-8000-000000000002';
    const second = apply(edit(start({id: secondID, sessionID: 'other-runtime', name: '同名.txt'}), 'second'), {type: 'PROTECT', token: 'b'});
    const a = disk.persist(first.effects[0]); disk.persist(second.effects[0]);
    assert.equal(disk.load(ID).text, 'first'); assert.equal(disk.load(secondID).text, 'second');
    assert.equal(apply(second.state, a).state.text, 'second');
});

test('Unicode, mixed line endings, BOM formats and trailing newline remain byte-exact', t => {
    const text = 'か\u3099👨‍👩‍👧‍👦🇯🇵👍🏽\r\n二行\n三行\r四行\n';
    const disk = diskFor(t);
    for (const format of ['utf8', 'utf8BOM', 'utf16LE', 'utf16BE']) {
        const provider = new MemoryProvider(); const state = edit(start({id: ID + '-' + format, format, lineEnding:'preserve'}), text);
        const p = apply(state, {type: 'SAVE_AS', token: 'save-' + format, name: '日本語.txt'});
        const w = apply(p.state, disk.persist(p.effects[0])); const receipt = provider.write(w.effects[0]);
        const done = apply(w.state, receipt);
        assert.deepEqual(provider.files.get(receipt.target.identity).bytes, encode(text, format));
        assert.deepEqual(receipt.target.baseline, baseline(encode(text, format)));
        assert.equal(core.restore(disk.load(state.id)).text, text); assert.equal(done.state.text, text);
    }
});

test('composition flag gates SAVE while protecting can preserve text; identical text does not increment revision', () => {
    const state = edit(start(), '未確定', true); const changedFlag = edit(state, '未確定', false);
    assert.equal(changedFlag.revision, 1); assert.equal(changedFlag.isComposing, false);
    assert.deepEqual(apply(state, {type: 'SAVE_AS', token: 'blocked'}).effects, []);
    assert.equal(apply(state, {type: 'PROTECT', token: 'draft'}).effects[0].envelope.text, '未確定');
    // This reducer consumes a flag. It does not test any native keyboard/IME behavior.
});

test('invalid persisted seeds, targets, formats, names and JSON values are rejected', () => {
    for (const name of ['', ' ', '/', 'a:b', 'a\\b', '.', '..']) {
        const result = apply(start(), {type: 'SAVE_AS', token: 's', name});
        assert.deepEqual(result.effects, []); assert.equal(result.state.fileErrorCode, 'invalidName');
    }
    for (const extra of [{revision: -1}, {revision: 1.2}, {format: 'shiftJIS'}, {target: {identity: 'x'}}, {protectedRevision: 1}, {acceptedRevision: 0}]) {
        assert.throws(() => start(extra), TypeError);
    }
    assert.throws(() => core.create({id: ID, sessionID: SESSION, text: undefined}), /JSON/);
    assert.throws(() => core.restore({schemaVersion: 99}), /schema/);
    assert.throws(() => core.restore({schemaVersion: 1, ...start(), acceptedRevision: 10}), /acceptedRevision/);
    assert.throws(() => apply(start(), {type: 'UNKNOWN'}), /Unknown/);
});

test('new drafts use UTF8 CRLF bytes without changing the native editor text or Unicode', t => {
    const provider = new MemoryProvider(); const text = 'か\u3099\n二\r三\r\n四\n';
    const state = edit(start(),text); assert.equal(state.format,'utf8'); assert.equal(state.lineEnding,'crlf');
    const begun = beginWrite(t,state,'new-crlf','SAVE_AS','new.txt');
    const receipt = provider.write(begun.effect), done = apply(begun.state,receipt);
    assert.deepEqual(provider.files.get(receipt.target.identity).bytes,encode(text,'utf8','crlf'));
    assert.equal(done.state.text,text); assert.equal(done.state.target.baseText,'か\u3099\r\n二\r\n三\r\n四\r\n');
    assert.equal(done.effects[0].envelope.lineEnding,'crlf');
});
test('legacy restore defaults to preserve and never restores automatic write validation', () => {
    const provider = new MemoryProvider(), target = provider.add('existing','old.txt','a\rb\n');
    const legacy = {schemaVersion:1,id:ID,name:'old.txt',text:'a\rb\n',format:'utf8',revision:1,epoch:4,target,acceptedRevision:0};
    const restored = core.restore(legacy); restored.sessionID = 'reopened';
    assert.equal(restored.lineEnding,'preserve'); assert.equal(restored.remoteValidated,false);
    assert.deepEqual(apply(restored,{type:'AUTO_SAVE',token:'not-yet'}).effects,[]);
    assert.equal(restored.target.baseText,'a\rb\n');
});
test('AUTO_SAVE requires remote validation, dirty target and idle committed conflict-free state', t => {
    const provider = new MemoryProvider(), target = provider.add('file-auto','auto.txt','old');
    const state = edit(start({target,acceptedRevision:0}),'new');
    assert.deepEqual(apply(state,{type:'AUTO_SAVE',token:'before-check'}).effects,[]);
    const validated = apply(state,{type:'REMOTE_OBSERVED',sessionID:SESSION,target}).state;
    const begun = beginWrite(t,validated,'auto','AUTO_SAVE');
    assert.deepEqual(apply(begun.state,{type:'AUTO_SAVE',token:'busy'}).effects,[]);
    const done = apply(begun.state,provider.write(begun.effect));
    assert.deepEqual(apply(done.state,{type:'AUTO_SAVE',token:'clean'}).effects,[]);
    assert.deepEqual(apply(edit(done.state,'変換中',true),{type:'AUTO_SAVE',token:'ime'}).effects,[]);
    assert.deepEqual(apply(edit(start(),'no-target'),{type:'AUTO_SAVE',token:'no-target'}).effects,[]);
});
test('remote observation never changes text or baseline; user baseline acceptance follows editor EDIT', () => {
    const provider = new MemoryProvider(), target = provider.add('file-merge','merge.txt','old');
    const state = edit(start({target}),'local'); provider.externalChange('file-merge','remote');
    const observed = provider.target('file-merge');
    const conflict = apply(state,{type:'REMOTE_OBSERVED',sessionID:SESSION,target:observed}).state;
    assert.equal(conflict.conflict,true); assert.equal(conflict.text,'local'); assert.deepEqual(conflict.target,target);
    assert.deepEqual(apply(conflict,{type:'AUTO_SAVE',token:'blocked'}).effects,[]);
    const editorApplied = edit(conflict,'user-confirmed merged');
    const accepted = apply(editorApplied,{type:'USER_ACCEPT_TARGET',sessionID:SESSION,token:'accept',target:observed});
    assert.equal(accepted.state.text,'user-confirmed merged'); assert.equal(accepted.state.conflict,false);
    assert.equal(accepted.state.acceptedRevision,null); assert.deepEqual(accepted.state.target,observed);
    assert.equal(accepted.effects[0].type,'PERSIST');
    const wrong = apply(conflict,{type:'USER_ACCEPT_TARGET',sessionID:SESSION,token:'wrong',target:{...observed,identity:'other'}});
    assert.deepEqual(wrong.effects,[]); assert.deepEqual(wrong.state.target,target);
});
test('unknown write outcome is durable and blocks retries but permits a different-name saveAs', t => {
    const provider = new MemoryProvider(), target = provider.add('file-unknown','original.txt','old');
    const begun = beginWrite(t,edit(start({target}),'new'),'unknown-write');
    const unknown = apply(begun.state,{type:'WRITE_FAILED',sessionID:SESSION,token:'unknown-write',code:'unknownOutcome',message:'結果不明'});
    assert.equal(unknown.state.uncertain,true); assert.equal(unknown.state.unknownOperation.token,'unknown-write');
    assert.deepEqual(apply(unknown.state,{type:'SAVE',token:'retry'}).effects,[]);
    assert.deepEqual(apply(unknown.state,{type:'AUTO_SAVE',token:'auto-retry'}).effects,[]);
    assert.deepEqual(apply(unknown.state,{type:'SAVE_AS',token:'same-name',name:'original.txt'}).effects,[]);
    const durable = apply(unknown.state,begun.disk.persist(unknown.effects[0]));
    const restored = core.restore(begun.disk.load(ID)); restored.sessionID = 'fresh-runtime';
    assert.equal(restored.uncertain,true); assert.deepEqual(restored.unknownOperation,unknown.state.unknownOperation);
    assert.deepEqual(apply(restored,{type:'SAVE',token:'restart-retry'}).effects,[]);
    const savedElsewhere = beginWrite(t,durable.state,'different','SAVE_AS','different.txt');
    const done = apply(savedElsewhere.state,provider.write(savedElsewhere.effect));
    assert.equal(done.state.uncertain,false); assert.equal(done.state.target.name,'different.txt'); assert.equal(done.state.text,'new');
});
test('unknown outcome reconcile only accepts matching operation and revision without issuing WRITE', t => {
    const provider = new MemoryProvider(), target = provider.add('file-reconcile','reconcile.txt','old');
    const begun = beginWrite(t,edit(start({target}),'snapshot'),'unknown');
    const actualReceipt = provider.write(begun.effect);
    const unknown = apply(begun.state,{type:'WRITE_FAILED',sessionID:SESSION,token:'unknown',code:'unknownOutcome',message:'結果不明'}).state;
    const latest = edit(unknown,'snapshot plus typing');
    const event = {type:'RECONCILE_OK',sessionID:SESSION,token:'reconcile',unknownToken:'unknown',revision:1,target:actualReceipt.target,applied:true};
    for (const wrong of [{...event,unknownToken:'old'}, {...event,revision:2}, {...event,applied:false}, {...event,sessionID:'old-session'}, {...event,target:{...event.target,identity:'different'}}]) {
        const result = apply(latest,wrong); assert.deepEqual(result.effects,[]); assert.equal(result.state.uncertain,true);
    }
    const reconciled = apply(latest,event);
    assert.equal(reconciled.state.text,'snapshot plus typing'); assert.equal(reconciled.state.acceptedRevision,1);
    assert.equal(reconciled.state.uncertain,false); assert.equal(reconciled.effects[0].type,'PERSIST');
    assert.ok(reconciled.effects.every(effect=>effect.type!=='WRITE'));
});
test('confirmed not-applied retry is explicit and still requires new observation for automatic save', t => {
    const provider = new MemoryProvider(), target = provider.add('file-retry','retry.txt','old');
    const begun = beginWrite(t,edit(start({target}),'new'),'unknown');
    const unknown = apply(begun.state,{type:'WRITE_FAILED',sessionID:SESSION,token:'unknown',code:'unknownOutcome',message:'結果不明'}).state;
    const event = {type:'CONFIRM_RETRY',sessionID:SESSION,token:'confirm',unknownToken:'unknown',target};
    const wrong = apply(unknown,{...event,target:{...target,baseline:{...target.baseline,byteCount:999}}});
    assert.deepEqual(wrong.effects,[]); assert.equal(wrong.state.uncertain,true);
    const confirmed = apply(unknown,event);
    assert.equal(confirmed.state.uncertain,false); assert.equal(confirmed.state.remoteValidated,false);
    assert.deepEqual(apply(confirmed.state,{type:'AUTO_SAVE',token:'still-blocked'}).effects,[]);
    assert.equal(apply(confirmed.state,{type:'SAVE',token:'manual-retry'}).effects[0].type,'PERSIST');
});
test('invalid new policy and malformed durable uncertainty are rejected before execution', () => {
    for (const extra of [{lineEnding:'lf'}, {uncertain:true}, {uncertain:'true'}, {remoteValidated:1}, {unknownOperation:{}}, {target:{identity:'x',name:'x',location:'x',baseline:{sha256:'a'.repeat(64),byteCount:1},baseText:4}}]) assert.throws(()=>start(extra),TypeError);
});

test('known write failures clear durable intent after metadata protection; failed metadata stays conservative', t => {
    for (const code of ['permission','offline','conflict','nameCollision']) {
        const provider = new MemoryProvider(), target = provider.add('known-'+code,'known.txt','old');
        const begun = beginWrite(t,edit(start({target}),'new'),'known-'+code);
        const failed = apply(begun.state,{type:'WRITE_FAILED',sessionID:SESSION,token:begun.effect.token,code,message:'確定した失敗'});
        assert.equal(failed.state.operation,null); assert.equal(failed.state.uncertain,false);
        assert.equal(failed.effects[0].envelope.pendingWrite,null);
        assert.equal(core.restore(begun.disk.load(ID)).uncertain,true); // metadata not yet durable
        apply(failed.state,begun.disk.persist(failed.effects[0]));
        const restored = core.restore(begun.disk.load(ID));
        assert.equal(restored.uncertain,false); assert.equal(restored.text,'new');
    }
});
test('baseline acceptance cannot clear or mutate an uncertain write before reconciliation', t => {
    const provider = new MemoryProvider(), target = provider.add('uncertain-baseline','uncertain.txt','old');
    const begun=beginWrite(t,edit(start({target}),'new'),'unknown-baseline');
    const uncertain=apply(begun.state,{type:'WRITE_FAILED',sessionID:SESSION,token:begun.effect.token,code:'unknownOutcome',message:'不明'}).state;
    provider.externalChange(target.identity,'external');
    const result=apply(uncertain,{type:'USER_ACCEPT_TARGET',sessionID:SESSION,token:'unsafe-baseline',target:provider.target(target.identity)});
    assert.deepEqual(result.effects,[]); assert.deepEqual(result.state.target,target);
    assert.equal(result.state.uncertain,true); assert.equal(result.state.text,'new');
});

test('exact remote acceptance records current revision and original bytes policy without needless autosave', () => {
    const provider = new MemoryProvider(), target = provider.add('remote-clean','clean.txt','old');
    provider.externalChange(target.identity,'remote\r\nか\u3099','utf16LE');
    const selected=provider.target(target.identity), edited=edit(start({target}),selected.baseText);
    const result=apply(edited,{type:'USER_ACCEPT_TARGET',sessionID:SESSION,token:'clean-accept',target:selected,remoteTextAccepted:true});
    assert.equal(result.state.acceptedRevision,result.state.revision); assert.equal(result.state.lineEnding,'preserve');
    assert.equal(result.state.format,'utf16LE'); assert.equal(result.effects[0].envelope.acceptedRevision,result.state.revision);
    assert.deepEqual(apply(result.state,{type:'AUTO_SAVE',token:'unnecessary-writeback'}).effects,[]);
});
test('remote acceptance flag never marks differing raw Unicode or merged local content accepted', () => {
    const provider=new MemoryProvider(), target=provider.add('remote-not-exact','notexact.txt','が');
    for (const text of ['か\u3099','が plus local','が\n']) {
        const state=edit(start({target}),text);
        const result=apply(state,{type:'USER_ACCEPT_TARGET',sessionID:SESSION,token:'raw-accept',target,remoteTextAccepted:true});
        assert.equal(result.state.acceptedRevision,null); assert.equal(result.state.lineEnding,'crlf'); assert.equal(result.state.text,text);
    }
});

test('durable write intent closes crash before receipt or unknown-outcome metadata', t => {
    const provider = new MemoryProvider(), target = provider.add('crash-file','crash.txt','old');
    const begun = beginWrite(t,edit(start({target}),'written snapshot'),'crash-write');
    const diskEnvelope = begun.disk.load(ID);
    assert.equal(diskEnvelope.uncertain,false); assert.equal(diskEnvelope.pendingWrite.phase,'writing');
    provider.write(begun.effect); // crash now: no WRITE_OK/WRITE_FAILED reducer callback
    const restored = core.restore(diskEnvelope); restored.sessionID='post-crash';
    assert.equal(restored.uncertain,true); assert.equal(restored.unknownOperation.token,'crash-write');
    assert.deepEqual(apply(restored,{type:'SAVE',token:'unsafe'}).effects,[]);
    assert.deepEqual(apply(restored,{type:'AUTO_SAVE',token:'unsafe-auto'}).effects,[]);
    const result = apply(restored,{type:'RECONCILE_OK',sessionID:'post-crash',token:'verified',unknownToken:'crash-write',revision:1,target:provider.target('crash-file'),applied:true});
    assert.equal(result.state.uncertain,false); assert.equal(result.effects[0].envelope.pendingWrite,null);
});
test('writing cancellation keeps uncertainty durable, and protecting cancellation clears durable intent', t => {
    const begun = beginWrite(t,edit(start(),'snapshot'),'write-cancel','SAVE_AS','cancel.txt');
    const cancelled = apply(begun.state,{type:'CANCEL',sessionID:SESSION,token:'write-cancel'});
    assert.equal(cancelled.state.uncertain,true); assert.equal(cancelled.effects[0].envelope.pendingWrite,null);
    const saved = apply(cancelled.state,begun.disk.persist(cancelled.effects[0]));
    assert.equal(core.restore(begun.disk.load(ID)).uncertain,true);
    assert.deepEqual(apply(saved.state,{type:'SAVE_AS',token:'same',name:'cancel.txt'}).effects,[]);
    const p = apply(edit(start(),'protected'),{type:'SAVE_AS',token:'protect-cancel'});
    const c = apply(p.state,{type:'CANCEL',sessionID:SESSION,token:'protect-cancel'});
    assert.equal(c.state.uncertain,false); assert.equal(c.effects[0].envelope.pendingWrite,null);
});
test('accepted external encoding changes policy without replacing text or CRLF choice', () => {
    const provider = new MemoryProvider(), target = provider.add('encoding-file','encoding.txt','old');
    const state = edit(start({target}),'retained local');
    const selected = {...target,format:'utf16LE'};
    const accepted = apply(state,{type:'USER_ACCEPT_TARGET',sessionID:SESSION,token:'encoding',target:selected});
    assert.equal(accepted.state.format,'utf16LE'); assert.equal(accepted.state.lineEnding,'crlf');
    assert.equal(accepted.state.text,'retained local'); assert.equal(accepted.effects[0].envelope.format,'utf16LE');
});

test('observed conflict protects three raw strings across restart without restoring apply permission', t => {
    const provider = new MemoryProvider(), target = provider.add('conflict-evidence','evidence.txt','base\r\n');
    const state = edit(start({target,lineEnding:'preserve'}),'local\nか\u3099');
    provider.externalChange('conflict-evidence','remote\r👨‍👩‍👧‍👦');
    const conflict = apply(state,{type:'REMOTE_OBSERVED',sessionID:SESSION,target:provider.target('conflict-evidence')});
    assert.equal(conflict.effects[0].type,'PERSIST');
    const disk = diskFor(t); const acknowledged = apply(conflict.state,disk.persist(conflict.effects[0]));
    const restored = core.restore(disk.load(ID)); restored.sessionID='restored-evidence';
    assert.deepEqual(restored.remoteCandidate,acknowledged.state.remoteCandidate);
    assert.equal(restored.remoteCandidate.baseText,'base\r\n'); assert.equal(restored.remoteCandidate.localText,'local\nか\u3099');
    assert.equal(restored.remoteCandidate.text,'remote\r👨‍👩‍👧‍👦');
    assert.equal(restored.conflict,true); assert.equal(restored.remoteValidated,false); assert.equal(restored.operation,null);
    assert.deepEqual(apply(restored,{type:'SAVE',token:'not-approved'}).effects,[]);
    assert.deepEqual(apply(restored,{type:'AUTO_SAVE',token:'not-approved-auto'}).effects,[]);
});
test('READ_OK protects candidate before consumption; failed evidence persistence keeps current text and all variants', t => {
    const provider = new MemoryProvider(), target = provider.add('read-evidence','read.txt','base');
    const disk = diskFor(t);
    const begun = apply(edit(start({target}),'local'),{type:'RELOAD',token:'read'});
    const reading = apply(begun.state,disk.persist(begun.effects[0]));
    provider.externalChange('read-evidence','remote');
    const completed = apply(reading.state,{type:'READ_OK',sessionID:SESSION,token:'read',text:'remote',format:'utf8',target:provider.target('read-evidence')});
    assert.equal(completed.effects[0].type,'PERSIST'); assert.equal(completed.effects[0].envelope.remoteCandidate.localText,'local');
    disk.failNext=true; const failed=apply(completed.state,disk.persist(completed.effects[0]));
    assert.ok(failed.state.draftError); assert.equal(failed.state.text,'local'); assert.equal(failed.state.remoteCandidate.text,'remote');
    const retry = apply(failed.state,{type:'PROTECT',token:'evidence-protection-retry'});
    apply(retry.state,disk.persist(retry.effects[0]));
    assert.equal(core.restore(disk.load(ID)).remoteCandidate.text,'remote');
});
