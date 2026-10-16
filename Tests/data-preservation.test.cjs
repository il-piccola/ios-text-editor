'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
require('../Core/SessionCore.js');
const core = globalThis.IyoCore;
const {MemoryProvider,DraftDisk} = require('./support/fakes.cjs');
const ID='10000000-0000-4000-8000-000000000051';
const SESSION='20000000-0000-4000-8000-000000000051';
function edit(state,text) { return core.reduce(state,{type:'EDIT',sessionID:state.sessionID,text,isComposing:false}).state; }
function setup(t) {
    const provider=new MemoryProvider(), target=provider.add('file-original','original.txt','base\r\nか\u3099');
    const disk=new DraftDisk(); t.after(()=>disk.dispose());
    const state=edit(core.create({id:ID,sessionID:SESSION,target,lineEnding:'preserve',text:target.baseText,acceptedRevision:0}),'local\n👨‍👩‍👧‍👦');
    provider.externalChange(target.identity,'remote\r初回');
    const observed=core.reduce(state,{type:'REMOTE_OBSERVED',sessionID:SESSION,target:provider.target(target.identity)});
    const protectedState=core.reduce(observed.state,disk.persist(observed.effects[0])).state;
    return {provider,disk,state:protectedState,original:JSON.parse(JSON.stringify(protectedState.remoteCandidate))};
}
function protect(state,disk,token) {
    const result=core.reduce(state,{type:'PROTECT',token});
    return core.reduce(result.state,disk.persist(result.effects[0])).state;
}
function restart(disk,session) { const state=core.restore(disk.load(ID)); state.sessionID=session; return state; }
function reload(state,provider,disk,token,text) {
    provider.externalChange(state.target.identity,text);
    const begun=core.reduce(state,{type:'RELOAD',token});
    const reading=core.reduce(begun.state,disk.persist(begun.effects[0]));
    const done=core.reduce(reading.state,{type:'READ_OK',sessionID:state.sessionID,token,text,format:'utf8',target:provider.target(state.target.identity)});
    return core.reduce(done.state,disk.persist(done.effects[0])).state;
}

test('merge application crash and new reload preserve old three originals plus new current candidate', t => {
    const c=setup(t);
    const merged=protect(edit(c.state,'user merged\n本文'),c.disk,'merged-protection');
    const reopened=restart(c.disk,'after-merge-crash');
    assert.equal(reopened.text,merged.text); assert.deepEqual(reopened.remoteCandidate,c.original);
    const reloaded=reload(reopened,c.provider,c.disk,'new-read','remote\r第二版');
    assert.deepEqual(reloaded.retainedEvidence,[c.original]);
    assert.equal(reloaded.remoteCandidate.text,'remote\r第二版');
    assert.equal(reloaded.remoteCandidate.localText,'user merged\n本文');
    const again=restart(c.disk,'after-new-read');
    assert.deepEqual(again.retainedEvidence,[c.original]);
    assert.equal(again.remoteCandidate.text,'remote\r第二版');
});
test('explicit acceptance archives original evidence, including before acceptance metadata becomes durable', t => {
    const c=setup(t), merged=protect(edit(c.state,'merged'),c.disk,'applied-merge');
    const accepted=core.reduce(merged,{type:'USER_ACCEPT_TARGET',sessionID:SESSION,token:'accepted',target:c.provider.target(c.state.target.identity)});
    assert.deepEqual(accepted.state.retainedEvidence,[c.original]); assert.equal(accepted.state.remoteCandidate,null);
    assert.deepEqual(accepted.effects[0].envelope.retainedEvidence,[c.original]);
    // Before metadata ACK the old envelope still contains the original candidate, never lost.
    assert.deepEqual(restart(c.disk,'before-accept-ack').remoteCandidate,c.original);
    core.reduce(accepted.state,c.disk.persist(accepted.effects[0]));
    const restarted=restart(c.disk,'after-accept-ack');
    assert.deepEqual(restarted.retainedEvidence,[c.original]); assert.equal(restarted.remoteCandidate,null);
});
test('saveAs to another identity retains earlier destination evidence across restart', t => {
    const c=setup(t);
    const begun=core.reduce(c.state,{type:'SAVE_AS',token:'copy',name:'copy.txt'});
    const writing=core.reduce(begun.state,c.disk.persist(begun.effects[0]));
    const accepted=core.reduce(writing.state,c.provider.write(writing.effects[0]));
    assert.notEqual(accepted.state.target.identity,c.original.target.identity);
    core.reduce(accepted.state,c.disk.persist(accepted.effects[0]));
    const restarted=restart(c.disk,'copy-runtime');
    assert.deepEqual(restarted.retainedEvidence,[c.original]);
    assert.notEqual(restarted.target.identity,restarted.retainedEvidence[0].target.identity);
});
test('duplicate evidence ignores callback token and revision while retaining raw Unicode distinctions', t => {
    const c=setup(t);
    const first=reload(c.state,c.provider,c.disk,'same-1',c.original.text);
    assert.equal(first.retainedEvidence.length,1);
    const second=reload(first,c.provider,c.disk,'same-2',c.original.text);
    assert.equal(second.retainedEvidence.length,1);
    const changed=edit(second,'local\n👨‍👩‍👧‍👦\nか\u3099');
    const third=reload(changed,c.provider,c.disk,'same-3',c.original.text);
    assert.equal(third.retainedEvidence.length,1); // archives identical old candidate once
    const fourth=reload(edit(third,'local\n👨‍👩‍👧‍👦\nが'),c.provider,c.disk,'same-4',c.original.text);
    assert.equal(fourth.retainedEvidence.length,2);
    assert.equal(fourth.retainedEvidence[1].localText,'local\n👨‍👩‍👧‍👦\nか\u3099');
});
test('older envelopes default to empty history and malformed archives fail closed', t => {
    const c=setup(t), envelope=c.disk.load(ID);
    delete envelope.retainedEvidence;
    assert.deepEqual(core.restore(envelope).retainedEvidence,[]);
    const malformed=[null,{},[null],[{...c.original,text:7}],[{...c.original,format:'unknown'}],[{...c.original,snapshotRevision:2,observedRevision:1}],[{...c.original,observedRevision:999}],[{...c.original,target:{...c.original.target,baseline:{sha256:'broken',byteCount:1}}}]];
    for(const retainedEvidence of malformed) assert.throws(()=>core.restore({...envelope,retainedEvidence}),TypeError);
    assert.throws(()=>core.create({id:ID,sessionID:SESSION,retainedEvidence:null}),TypeError);
});
test('history is immutable and never silently truncated as distinct observations accumulate', t => {
    const c=setup(t); let state=c.state;
    for(let i=0;i<36;i++) state=reload(state,c.provider,c.disk,'history-'+i,'remote '+i);
    assert.equal(state.retainedEvidence.length,36);
    assert.deepEqual(state.retainedEvidence[0],c.original);
    assert.equal(state.retainedEvidence[35].text,'remote 34');
    assert.equal(restart(c.disk,'history-runtime').retainedEvidence.length,36);
    const result=core.reduce(state,{type:'PROTECT',token:'immutable'});
    result.effects[0].envelope.retainedEvidence[0].localText='mutated effect';
    assert.deepEqual(state.retainedEvidence[0],c.original); assert.deepEqual(result.state.retainedEvidence[0],c.original);
});
test('clean same-text remote rename updates header and recents name without writeback', t => {
    const provider=new MemoryProvider(), target=provider.add('rename-file','old.txt','same\r\n');
    const disk=new DraftDisk(); t.after(()=>disk.dispose());
    const state=core.create({id:ID,sessionID:SESSION,name:'old.txt',text:target.baseText,target,acceptedRevision:0,lineEnding:'preserve'});
    provider.files.get(target.identity).name='new.txt';
    const selected=provider.target(target.identity);
    const accepted=core.reduce(state,{type:'USER_ACCEPT_TARGET',sessionID:SESSION,token:'rename',target:selected,remoteTextAccepted:true});
    assert.equal(accepted.state.name,'new.txt'); assert.equal(accepted.state.acceptedRevision,0);
    assert.deepEqual(core.reduce(accepted.state,{type:'AUTO_SAVE',token:'no-writeback'}).effects,[]);
    core.reduce(accepted.state,disk.persist(accepted.effects[0]));
    assert.equal(restart(disk,'rename-runtime').name,'new.txt');
    assert.equal(provider.writeCount,0);
});

test('new external observation archives prior raw evidence before replacing current candidate', t => {
    const c=setup(t);
    c.provider.externalChange(c.state.target.identity,'remote\rnew observation');
    const result=core.reduce(c.state,{type:'REMOTE_OBSERVED',sessionID:SESSION,target:c.provider.target(c.state.target.identity)});
    assert.deepEqual(result.state.retainedEvidence,[c.original]);
    core.reduce(result.state,c.disk.persist(result.effects[0]));
    const restored=restart(c.disk,'observation-runtime');
    assert.deepEqual(restored.retainedEvidence,[c.original]);
    assert.equal(restored.remoteCandidate.text,'remote\rnew observation');
});
test('saveAs unknown outcome reconciliation archives prior-identity evidence without reissuing write', t => {
    const c=setup(t);
    const begun=core.reduce(c.state,{type:'SAVE_AS',token:'unknown-copy',name:'uncertain-copy.txt'});
    const writing=core.reduce(begun.state,c.disk.persist(begun.effects[0]));
    const receipt=c.provider.write(writing.effects[0]);
    const unknown=core.reduce(writing.state,{type:'WRITE_FAILED',sessionID:SESSION,token:'unknown-copy',code:'unknownOutcome',message:'receipt missing'});
    const reconciled=core.reduce(unknown.state,{type:'RECONCILE_OK',sessionID:SESSION,token:'checked',unknownToken:'unknown-copy',revision:c.state.revision,target:receipt.target,applied:true});
    assert.deepEqual(reconciled.state.retainedEvidence,[c.original]); assert.equal(reconciled.state.remoteCandidate,null);
    assert.ok(reconciled.effects.every(effect=>effect.type==='PERSIST'));
    core.reduce(reconciled.state,c.disk.persist(reconciled.effects[0]));
    assert.deepEqual(restart(c.disk,'reconciled-runtime').retainedEvidence,[c.original]);
});

test('composition started during a remote read blocks adoption and preserves IME cancellation text', t => {
    const c=setup(t), committed=c.state.text, originalTarget=c.state.target;
    const begun=core.reduce(c.state,{type:'RELOAD',token:'read-before-ime'});
    const reading=core.reduce(begun.state,c.disk.persist(begun.effects[0]));
    const composing=core.reduce(reading.state,{type:'EDIT',sessionID:SESSION,text:committed+'\nきょうは',isComposing:true}).state;
    c.provider.externalChange(originalTarget.identity,'external change\r\n');
    const remote=core.reduce(composing,{type:'READ_OK',sessionID:SESSION,token:'read-before-ime',
        text:'external change\r\n',format:'utf8',target:c.provider.target(originalTarget.identity)});
    assert.equal(remote.state.text,committed+'\nきょうは'); assert.equal(remote.state.isComposing,true);
    assert.ok(remote.effects.every(effect=>effect.type==='PERSIST'));
    const adopt=core.reduce(remote.state,{type:'USER_ACCEPT_TARGET',sessionID:SESSION,token:'no-adopt-during-ime',
        target:c.provider.target(originalTarget.identity),remoteTextAccepted:true});
    assert.deepEqual(adopt.effects,[]); assert.deepEqual(adopt.state.target,originalTarget);
    assert.equal(adopt.state.text,composing.text);
    const cancelled=core.reduce(adopt.state,{type:'EDIT',sessionID:SESSION,text:committed,isComposing:false}).state;
    const protectedState=protect(cancelled,c.disk,'ime-cancellation-protection');
    assert.equal(protectedState.text,committed); assert.equal(restart(c.disk,'ime-restart').text,committed);
    assert.equal(protectedState.remoteCandidate.text,'external change\r\n');
    assert.deepEqual(protectedState.retainedEvidence,[c.original]);
});
