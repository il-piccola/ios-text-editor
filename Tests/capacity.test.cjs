'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
require('../Core/CapacityPolicy.js');require('../Core/SessionCore.js');
const capacity=globalThis.IyoCapacity,core=globalThis.IyoCore;
const {MemoryProvider,DraftDisk}=require('./support/fakes.cjs');
const ID='10000000-0000-4000-8000-000000000061',SESSION='20000000-0000-4000-8000-000000000061';
const clone=x=>JSON.parse(JSON.stringify(x));
function config(extra={}) {return {incomingBytes:10,previousBytes:20,existingBytes:40,budgetBytes:100,maxIncomingBytes:100,reserveBytes:5,availableBytes:100,...extra};}
function fixture() {
    const provider=new MemoryProvider(),target=provider.add('current-file','本文.txt','現在\r\nか\u3099');
    const old=provider.add('old-file','以前.txt','外部\r\n😀');
    const first={token:'history-a',text:old.baseText,localText:'端末\nが',baseText:'基準\rか\u3099',format:'utf8',target:old,observedRevision:0,snapshotRevision:0};
    const second={...clone(first),token:'history-b',localText:'別の端末本文👩‍💻'};
    const state=core.create({id:ID,sessionID:SESSION,text:target.baseText,target,name:target.name,acceptedRevision:0,protectedRevision:0,retainedEvidence:[first,second],remoteValidated:true,lineEnding:'preserve'});
    return {state,provider,first,second};
}
function send(state,event) {return core.reduce(state,{sessionID:state.sessionID,...event});}
function ack(effect) {return {type:'DRAFT_OK',sessionID:effect.sessionID,token:effect.token,revision:effect.envelope.revision,epoch:effect.envelope.epoch};}
function fail(effect) {return {type:'DRAFT_FAILED',sessionID:effect.sessionID,token:effect.token,message:'容量不足'};}
function deletion(state,extra={}) {return send(state,{type:'DELETE_EVIDENCE',token:'delete',confirmed:true,expectedEpoch:state.epoch,ids:[core.historyList(state)[0].id],...extra});}
function restoration(state,source='local',extra={}) {return send(state,{type:'RESTORE_EVIDENCE',token:'restore',confirmed:true,expectedEpoch:state.epoch,ids:[core.historyList(state)[0].id],source,...extra});}
function edit(state,text,isComposing=false) {return send(state,{type:'EDIT',text,isComposing}).state;}

// Node filesystem adapter uses production arithmetic before its atomic rename. Native DraftStore has separate XCTest coverage.
class CapacityDisk extends DraftDisk {
    constructor() {super();this.available=1e9;this.budget=1e9;this.maximum=1e9;this.reserve=0;this.failure=null;}
    persist(effect) {
        const data=Buffer.from(JSON.stringify(effect.envelope),'utf8'),file=this.file(effect.envelope.id);
        const used=fs.readdirSync(this.directory).reduce((n,name)=>n+fs.statSync(path.join(this.directory,name)).size,0);
        const previous=fs.existsSync(file)?fs.statSync(file).size:0;
        this.lastPlan=capacity.plan({incomingBytes:data.length,previousBytes:previous,existingBytes:used,budgetBytes:this.budget,maxIncomingBytes:this.maximum,reserveBytes:this.reserve,availableBytes:this.available});
        if(!this.lastPlan.allowed) return fail(effect);
        if(this.failure==='afterTemporaryWrite') {
            const tmp=file+'.tmp';fs.writeFileSync(tmp,data,{flag:'wx'});fs.unlinkSync(tmp);this.failure=null;return fail(effect);
        }
        if(this.failure==='beforeAtomicWrite'){this.failure=null;return fail(effect);}
        return super.persist(effect);
    }
}
function diskFixture(t) {const c=fixture(),disk=new CapacityDisk();t.after(()=>disk.dispose());const p=send(c.state,{type:'PROTECT',token:'initial'});const state=core.reduce(p.state,disk.persist(p.effects[0])).state;return {...c,state,disk};}

test('UTF8 measurement preserves raw CRLF/NFD/emoji and counts actual serialized escapes',()=>{
    for(const text of ['','a\r\n','か\u3099','が','👨‍👩‍👧‍👦','\uD800','\uDC00','"\\\n']) assert.equal(capacity.utf8Bytes(text),Buffer.byteLength(text,'utf8'));
    const raw='"\\\nか\u3099',serialized=JSON.stringify({text:raw});
    assert.ok(capacity.utf8Bytes(serialized)>capacity.utf8Bytes(raw));assert.equal(raw,'"\\\nか\u3099');
});
test('atomic replacement counts old record plus incoming temporary bytes, not only final usage',()=>{
    const p=capacity.plan(config({incomingBytes:60,previousBytes:40,existingBytes:80,budgetBytes:100}));
    assert.equal(p.finalBytes,100);assert.equal(p.replacementPeakBytes,140);assert.equal(p.reason,'budgetPeak');assert.equal(p.automaticDeletion,false);
    assert.equal(capacity.plan(config({incomingBytes:60,previousBytes:40,existingBytes:80,budgetBytes:140})).allowed,true);
});
test('reserve, unknown availability and serialized record limits fail closed at exact boundaries',()=>{
    assert.equal(capacity.plan(config({availableBytes:15})).allowed,true);
    assert.equal(capacity.plan(config({availableBytes:14})).reason,'diskReserve');
    assert.equal(capacity.plan(config({availableBytes:null})).reason,'availableUnknown');
    assert.equal(capacity.plan(config({maxIncomingBytes:9})).reason,'recordLimit');
    assert.equal(capacity.plan(config({maxIncomingBytes:10})).allowed,true);
    assert.equal(capacity.defaults.budgetBytes,256*1024*1024);assert.equal(capacity.defaults.reserveBytes,128*1024*1024);
});
test('invalid capacities and integer overflow are rejected before allocation or deletion',()=>{
    for(const value of [-1,NaN,Infinity,1.5,'100',undefined]) assert.throws(()=>capacity.plan(config({incomingBytes:value})),TypeError);
    assert.throws(()=>capacity.plan(config({previousBytes:41})),TypeError);
    assert.throws(()=>capacity.plan(config({incomingBytes:Number.MAX_SAFE_INTEGER,existingBytes:1,previousBytes:0})),TypeError);
    assert.throws(()=>capacity.plan(config({availableBytes:undefined})),TypeError);
});
test('real test-disk capacity denial retains old JSON byte for byte and other records',t=>{
    const c=diskFixture(t),file=c.disk.file(ID),old=fs.readFileSync(file),other=c.disk.file('other-doc');fs.writeFileSync(other,'{"protected":"別文書"}');const otherBytes=fs.readFileSync(other);
    let current=edit(c.state,c.state.text+'\n追記');
    for(const mode of ['budget','available','unknown','maximum']) {
        c.disk.budget=mode==='budget'?old.length:1e9;c.disk.available=mode==='available'?0:mode==='unknown'?null:1e9;c.disk.maximum=mode==='maximum'?1:1e9;
        const p=send(current,{type:'PROTECT',token:'denied-'+mode}),receipt=c.disk.persist(p.effects[0]);current=core.reduce(p.state,receipt).state;
        assert.equal(receipt.type,'DRAFT_FAILED');assert.deepEqual(fs.readFileSync(file),old);assert.deepEqual(fs.readFileSync(other),otherBytes);assert.equal(current.text,c.state.text+'\n追記');
    }
});
test('injected disk failure before commit and after fresh temporary write preserves old originals',t=>{
    const c=diskFixture(t),old=fs.readFileSync(c.disk.file(ID));let state=edit(c.state,'追記\r\nか\u3099');
    for(const mode of ['beforeAtomicWrite','afterTemporaryWrite']) {
        c.disk.failure=mode;const p=send(state,{type:'PROTECT',token:mode});state=core.reduce(p.state,c.disk.persist(p.effects[0])).state;
        assert.deepEqual(fs.readFileSync(c.disk.file(ID)),old);assert.equal(state.text,'追記\r\nか\u3099');assert.equal(fs.readdirSync(c.disk.directory).length,1);
    }
});
test('history metadata IDs remain stable across restart and inspection returns only a detached selection',()=>{
    const {state,first}=fixture(),list=core.historyList(state);assert.equal(list.length,2);assert.equal(list[0].canDelete,true);
    assert.equal(list[0].totalBytes,Buffer.byteLength(first.baseText)+Buffer.byteLength(first.localText)+Buffer.byteLength(first.text));assert.equal('text' in list[0],false);
    const p=send(state,{type:'PROTECT',token:'roundtrip'}),restored=core.restore(p.effects[0].envelope);restored.sessionID='fresh';
    assert.equal(core.historyList(restored)[0].id,list[0].id);const selected=core.evidenceFor(restored,list[0].id);selected.text='mutated';assert.equal(restored.retainedEvidence[0].text,first.text);
    assert.equal(core.evidenceFor(restored,'missing'),null);
    assert.throws(()=>core.create({...state,retainedEvidence:[first,{...clone(first),localText:'different'}]}),/Duplicate history ID/);
});
test('history deletion is staged and only matching durability ACK commits selected entries',()=>{
    const {state,first,second}=fixture(),p=deletion(state);assert.deepEqual(p.state.retainedEvidence,[first,second]);assert.deepEqual(p.effects[0].envelope.retainedEvidence,[second]);
    assert.ok(p.state.pendingEvidenceDeletion);assert.equal(send(p.state,{...ack(p.effects[0]),token:'wrong'}).state.retainedEvidence.length,2);
    const done=core.reduce(p.state,ack(p.effects[0])).state;assert.deepEqual(done.retainedEvidence,[second]);assert.equal(done.pendingEvidenceDeletion,null);assert.equal(done.text,state.text);
});
test('failed history deletion retains memory, persisted old evidence and restart originals',t=>{
    const c=diskFixture(t),old=fs.readFileSync(c.disk.file(ID));c.disk.available=0;const p=deletion(c.state),done=core.reduce(p.state,c.disk.persist(p.effects[0])).state;
    assert.deepEqual(done.retainedEvidence,c.state.retainedEvidence);assert.equal(done.pendingEvidenceDeletion,null);assert.ok(done.draftError);assert.deepEqual(fs.readFileSync(c.disk.file(ID)),old);
    assert.deepEqual(core.restore(c.disk.load(ID)).retainedEvidence,c.state.retainedEvidence);
});
test('current comparison cannot be deleted even when historical records are selected',()=>{
    const {state,first}=fixture();state.remoteCandidate={...clone(first),target:state.target,text:state.text,localText:state.text,baseText:state.text};
    const p=deletion(state),done=core.reduce(p.state,ack(p.effects[0])).state;assert.deepEqual(done.remoteCandidate,state.remoteCandidate);
    assert.equal(core.evidenceFor(state,JSON.stringify(['not-an-archived-id'])),null);
    assert.throws(()=>deletion(state,{ids:['current-candidate']}),TypeError);
});
test('history delete rejects unsaved, conflict, composing, busy, uncertain and failed protection states',()=>{
    const {state}=fixture();const altered=[edit(state,'dirty'),{...clone(state),target:null,acceptedRevision:null},{...clone(state),conflict:true},edit(state,state.text,true),{...clone(state),protectedRevision:-1},{...clone(state),draftError:'failed'}];
    const save=send(edit(state,'new'),{type:'SAVE',token:'save'});altered.push(save.state);
    const writing=core.reduce(save.state,ack(save.effects[0]));altered.push(send(writing.state,{type:'WRITE_FAILED',token:'save',code:'unknownOutcome',message:'unknown'}).state);
    for(const s of altered) {assert.deepEqual(deletion(s).effects,[]);assert.equal(core.historyList(s)[0].canDelete,false);}
    for(const extra of [{confirmed:false},{expectedEpoch:9},{sessionID:'old'}])assert.deepEqual(deletion(state,extra).effects,[]);
    assert.throws(()=>deletion(state,{ids:[]}),TypeError);const id=core.historyList(state)[0].id;assert.throws(()=>deletion(state,{ids:[id,id]}),TypeError);
});
test('editing during deletion cannot reinsert history through later protection envelopes or ACK order',()=>{
    const {state,second}=fixture(),p=deletion(state),typed=edit(p.state,'保存中の追記\r\nか\u3099'),next=send(typed,{type:'PROTECT',token:'newer-protection'});
    assert.deepEqual(next.effects[0].envelope.retainedEvidence,[second]);assert.equal(next.effects[0].envelope.text,typed.text);
    let done=core.reduce(next.state,ack(next.effects[0])).state;assert.equal(done.pendingEvidenceDeletion,null);assert.deepEqual(done.retainedEvidence,[second]);
    done=core.reduce(done,fail(p.effects[0])).state;assert.equal(done.text,typed.text);assert.deepEqual(done.retainedEvidence,[second]);assert.equal(done.draftError,null);
});
test('first deletion proposal failure waits for a concurrent later proposal; all failures preserve history',()=>{
    const {state}=fixture(),p=deletion(state),next=send(edit(p.state,'typed'),{type:'PROTECT',token:'newer'});
    let done=core.reduce(next.state,fail(p.effects[0])).state;assert.ok(done.pendingEvidenceDeletion);assert.equal(done.retainedEvidence.length,2);
    const success=core.reduce(done,ack(next.effects[0])).state;assert.equal(success.retainedEvidence.length,1);assert.equal(success.text,'typed');
    done=core.reduce(done,fail(next.effects[0])).state;assert.equal(done.pendingEvidenceDeletion,null);assert.equal(done.retainedEvidence.length,2);assert.ok(done.draftError);
});
test('explicit deletion may survive restart after actual disk commit even before receipt delivery',t=>{
    const c=diskFixture(t),p=deletion(c.state);assert.equal(core.restore(c.disk.load(ID)).retainedEvidence.length,2);
    const receipt=c.disk.persist(p.effects[0]);assert.equal(receipt.type,'DRAFT_OK');assert.equal(p.state.retainedEvidence.length,2);
    const restarted=core.restore(c.disk.load(ID));assert.equal(restarted.retainedEvidence.length,1);assert.equal(restarted.pendingEvidenceDeletion,null);
});
test('history restore protects current draft first and yields immutable raw command without Core text replacement',()=>{
    const {state,first}=fixture();
    for(const source of ['base','local','remote']) {
        const p=restoration(state,source),ready=core.reduce(p.state,ack(p.effects[0]));assert.equal(p.effects[0].type,'PERSIST');assert.equal(p.effects[0].envelope.text,state.text);
        assert.equal(ready.state.text,state.text);assert.equal(ready.state.pendingEvidenceRestore,null);assert.equal(ready.effects[0].type,'RESTORE_READY');assert.equal(ready.effects[0].expectedText,state.text);
        assert.equal(ready.effects[0].text,source==='base'?first.baseText:source==='local'?first.localText:first.text);assert.equal(ready.effects[0].revision,state.revision);
    }
});
test('restore failure, typing, composition or old session receipts never emit an unsafe replacement',()=>{
    const {state}=fixture(),p=restoration(state);
    const failed=core.reduce(p.state,fail(p.effects[0]));assert.deepEqual(failed.effects,[]);assert.equal(failed.state.pendingEvidenceRestore,null);assert.equal(failed.state.text,state.text);
    for(const s of [edit(p.state,'typed'),edit(p.state,p.state.text,true)]) {const r=core.reduce(s,ack(p.effects[0]));assert.deepEqual(r.effects,[]);assert.equal(r.state.text,s.text);assert.equal(r.state.pendingEvidenceRestore,null);}
    const late=send(p.state,{...ack(p.effects[0]),sessionID:'another'});assert.deepEqual(late.effects,[]);assert.ok(late.state.pendingEvidenceRestore);
    assert.deepEqual(restoration(state,'local',{confirmed:false}).effects,[]);assert.deepEqual(restoration(state,'local',{expectedEpoch:99}).effects,[]);
});
test('restore permits recovery of protected unsaved/conflict text but blocks concurrent saves and acceptance',()=>{
    const {state}=fixture(),dirty=edit(state,'unsaved original'),p=restoration({...dirty,conflict:true});
    assert.notEqual(p.state.protectedRevision,p.state.revision);
    assert.equal(p.effects[0].envelope.text,'unsaved original');
    for(const event of [{type:'SAVE',token:'save'},{type:'SAVE_AS',token:'as',name:'other.txt'},{type:'RELOAD',token:'read'},{type:'USER_ACCEPT_TARGET',token:'accept',target:state.target}])assert.deepEqual(send(p.state,event).effects,[]);
    assert.deepEqual(send(p.state,{type:'CANCEL',token:'restore'}).state,p.state);
    const done=core.reduce(p.state,ack(p.effects[0]));assert.equal(done.state.text,'unsaved original');assert.equal(done.effects[0].text,state.retainedEvidence[0].localText);
});
test('missing base originals are not invented and restored envelopes never revive runtime commands',()=>{
    const {state}=fixture();state.retainedEvidence[0].baseText=null;assert.deepEqual(restoration(state,'base').effects,[]);
    const p=restoration(state),restarted=core.restore(p.effects[0].envelope);assert.equal(restarted.pendingEvidenceRestore,null);assert.equal(restarted.text,state.text);
});
test('presenter invalidation is identity/session scoped, safe during marked text and stops writes',()=>{
    const {state}=fixture(),marked=edit(state,'変換中',true);
    for(const event of [{sessionID:'old',identity:state.target.identity},{sessionID:SESSION,identity:'other-file'}])assert.deepEqual(send(marked,{type:'INVALIDATE_REMOTE',...event}).state,marked);
    const invalid=send(marked,{type:'INVALIDATE_REMOTE',identity:state.target.identity}).state;assert.equal(invalid.text,'変換中');assert.equal(invalid.isComposing,true);assert.equal(invalid.remoteValidated,false);assert.equal(invalid.conflict,true);
    const committed=edit(invalid,'変換確定');assert.deepEqual(send(committed,{type:'SAVE',token:'no-write'}).effects,[]);assert.deepEqual(send(committed,{type:'AUTO_SAVE',token:'no-auto'}).effects,[]);
    assert.equal(send(committed,{type:'RELOAD',token:'refresh'}).effects[0].type,'PERSIST');
});
test('second external change during merge confirmation durably retains A/C/B plus prior O/L/A originals',t=>{
    const provider=new MemoryProvider(),original='O\r\nか\u3099',local='L\nが',firstRemote='A\r\n😀',applied='C\n👩‍💻',secondRemote='B\rか\u3099';
    const target=provider.add('confirm-file','比較.txt',original),disk=new DraftDisk();t.after(()=>disk.dispose());
    let state=edit(core.create({id:ID,sessionID:SESSION,text:original,target,acceptedRevision:0,lineEnding:'preserve'}),local);
    provider.externalChange(target.identity,firstRemote);
    let seen=send(state,{type:'REMOTE_OBSERVED',target:provider.target(target.identity)});state=core.reduce(seen.state,disk.persist(seen.effects[0])).state;
    const first=clone(state.remoteCandidate);
    state=edit(state,applied);const protection=send(state,{type:'PROTECT',token:'applied-C'});state=core.reduce(protection.state,disk.persist(protection.effects[0])).state;
    provider.externalChange(target.identity,secondRemote);
    assert.throws(()=>send(state,{type:'REMOTE_OBSERVED',target:provider.target(target.identity),comparisonBase:null}),TypeError);
    seen=send(state,{type:'REMOTE_OBSERVED',target:provider.target(target.identity),comparisonBase:firstRemote});
    state=core.reduce(seen.state,disk.persist(seen.effects[0])).state;
    const reopened=core.restore(disk.load(ID));
    assert.equal(reopened.text,applied);assert.equal(reopened.remoteCandidate.baseText,firstRemote);assert.equal(reopened.remoteCandidate.localText,applied);assert.equal(reopened.remoteCandidate.text,secondRemote);
    assert.deepEqual(reopened.retainedEvidence,[first]);assert.equal(first.baseText,original);assert.equal(first.localText,local);assert.equal(first.text,firstRemote);
});
test('explicit comparison base protects A/C/O even if external content reverts to original baseline',t=>{
    const provider=new MemoryProvider(),original='O\r\nか\u3099',firstRemote='A\n😀',applied='C\r👩‍💻';
    const target=provider.add('reverted-file','再更新.txt',original),disk=new DraftDisk();t.after(()=>disk.dispose());
    let state=edit(core.create({id:ID,sessionID:SESSION,text:original,target,acceptedRevision:0,lineEnding:'preserve'}),'L\nが');
    provider.externalChange(target.identity,firstRemote);
    let result=send(state,{type:'REMOTE_OBSERVED',target:provider.target(target.identity)});state=core.reduce(result.state,disk.persist(result.effects[0])).state;
    const previous=clone(state.remoteCandidate);state=edit(state,applied);provider.externalChange(target.identity,original);
    const baselineOnly=send(state,{type:'REMOTE_OBSERVED',target:provider.target(target.identity)});assert.deepEqual(baselineOnly.effects,[]);
    result=send(state,{type:'REMOTE_OBSERVED',target:provider.target(target.identity),comparisonBase:firstRemote});assert.equal(result.effects[0].type,'PERSIST');
    state=core.reduce(result.state,disk.persist(result.effects[0])).state;assert.equal(state.conflict,true);
    const reopened=core.restore(disk.load(ID));assert.equal(reopened.remoteCandidate.baseText,firstRemote);assert.equal(reopened.remoteCandidate.localText,applied);assert.equal(reopened.remoteCandidate.text,original);assert.deepEqual(reopened.retainedEvidence,[previous]);
    assert.equal(reopened.conflict,true);reopened.sessionID='after-reverted-comparison';assert.deepEqual(send(reopened,{type:'SAVE',token:'no-silent-retry'}).effects,[]);
});
