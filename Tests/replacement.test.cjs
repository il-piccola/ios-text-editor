'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const planner = require('../Editor/ReplacementPlan.js');
const segmenter = new Intl.Segmenter('ja', {granularity: 'grapheme'});
function boundaries(text) { return [...segmenter.segment(text)].map(item => item.index).concat(text.length); }
function preview(text, query, replacement, selection = {location: 0, length: 0}, scope = 'document') {
  const value = planner.plan({text, query, replacement, selection, scope, boundaries: boundaries(text)});
  value.selection = planner.finalizeSelection({text: value.candidate, selection: value.proposedSelection, boundaries: boundaries(value.candidate)});
  return value;
}
test('literal Japanese replacement counts matches and keeps trailing CRLF', () => {
  const result = preview('春の花\r\n花が咲く\r\n', '花', '桜');
  assert.equal(result.count, 2); assert.equal(result.candidate, '春の桜\r\n桜が咲く\r\n');
});
test('regex punctuation and dollar replacement remain literal', () => {
  assert.equal(preview('.*$ .*$', '.*$', '$1\\x').candidate, '$1\\x $1\\x');
});
test('nonoverlapping matches have standard literal semantics', () => {
  const result = preview('aaaaa', 'aa', 'b');
  assert.equal(result.count, 2); assert.equal(result.candidate, 'bba');
});
test('selection-only scope never changes identical text outside selection', () => {
  const result = preview('猫 猫 猫', '猫', '子猫', {location: 2, length: 1}, 'selection');
  assert.equal(result.candidate, '猫 子猫 猫'); assert.deepEqual(result.selection, {location: 2, length: 2});
});
test('source cluster boundary blocks splitting a combining kana', () => {
  assert.equal(preview('か\u3099 か', 'か', 'き').candidate, 'か\u3099 き');
});
test('complete combining cluster is replaceable', () => {
  assert.equal(preview('か\u3099', 'か\u3099', 'が').candidate, 'が');
});
test('emoji ZWJ family and flags cannot be partially replaced', () => {
  assert.equal(preview('👨‍👩‍👧‍👦 🇯🇵', '👩', 'X').count, 0);
  assert.equal(preview('🇯🇵', '🇯', 'X').count, 0);
  assert.equal(preview('😀', '\uD83D', 'X').count, 0);
});
test('whole emoji replacement maps UTF16 cursor', () => {
  const result = preview('A😀B', '😀', '🐱🐱', {location: 3, length: 0});
  assert.equal(result.candidate, 'A🐱🐱B'); assert.deepEqual(result.selection, {location: 5, length: 0});
});
test('deletion maps selected span to valid cursor', () => {
  const result = preview('前削除後', '削除', '', {location: 1, length: 2});
  assert.equal(result.candidate, '前後'); assert.deepEqual(result.selection, {location: 1, length: 0});
});
test('replacement can join a neighboring combining mark; final cursor is normalized', () => {
  const result = preview('xか', 'x', 'か\u3099', {location: 1, length: 0});
  assert.deepEqual(result.selection, {location: 2, length: 0});
  const cursor = planner.finalizeSelection({text:'か\u3099', boundaries:boundaries('か\u3099'), selection:{location:1,length:0}});
  assert.deepEqual(cursor, {location:2,length:0});
});
test('final range expands rather than splits a replacement grapheme', () => {
  assert.deepEqual(planner.finalizeSelection({text:'A👨‍👩‍👧‍👦B', boundaries:boundaries('A👨‍👩‍👧‍👦B'), selection:{location:2,length:1}}), {location:1,length:11});
});
test('empty query and empty selection scope are rejected', () => {
  assert.throws(() => preview('本文', '', 'X'), /検索/);
  assert.throws(() => preview('本文', '本', 'X', {location:0,length:0}, 'selection'), /選択/);
});
test('out-of-range or cluster-interior selection is rejected', () => {
  assert.throws(() => preview('😀', '😀', 'X', {location:1,length:0}), /文字の途中/);
  assert.throws(() => preview('a', 'a', 'x', {location:2,length:0}), /選択範囲/);
});
test('boundary arrays must be ordered and include both document ends', () => {
  const base = {text:'abc',query:'a',replacement:'x',selection:{location:0,length:0},scope:'document'};
  for (const invalid of [[0,1,1,3],[1,3],[0,2],[0,1.5,3]]) assert.throws(() => planner.plan({...base,boundaries:invalid}), /境界/);
});
test('unchanged replacement reports no-op without inventing edits', () => {
  const result = preview('猫猫', '猫', '猫'); assert.equal(result.count,2); assert.equal(result.isNoOp,true);
});
test('exact LF/CRLF matches preserve all other newlines', () => {
  const result = preview('a\r\nb\nc\r\n', '\r\n', '\r\n'); assert.equal(result.count,2); assert.equal(result.candidate,'a\r\nb\nc\r\n');
});
test('large text counts every nonoverlapping match without truncation', () => {
  const text = '文章です。\r\n'.repeat(20000);
  // ASCII/code-point boundaries suffice here except the CRLF cluster; use the same native-input contract.
  const points = []; for (let i=0;i<text.length;i++) if (!(text[i]==='\n' && text[i-1]==='\r')) points.push(i); points.push(text.length);
  const result = planner.plan({text,query:'文章',replacement:'記録',selection:{location:text.length,length:0},scope:'document',boundaries:points});
  assert.equal(result.count,20000); assert.equal(result.candidate,'記録です。\r\n'.repeat(20000));
});

function cappedPlan(text, query, replacement, limits, extra = {}) {
  return planner.plan({text,query,replacement,selection:{location:0,length:0},scope:'document',
    boundaries:boundaries(text),limits,...extra});
}
test('production defaults cap text, matches and estimated memory without silent expansion', () => {
  assert.equal(planner.defaultLimits.maxInputUTF16,4*1024*1024);
  assert.equal(planner.defaultLimits.maxOutputUTF16,4*1024*1024);
  assert.equal(planner.defaultLimits.maxMatches,100000);
  assert.equal(planner.defaultLimits.memoryBudgetBytes,128*1024*1024);
  assert.throws(()=>cappedPlan('a','a','b',{maxMatches:100001}),/拡張/);
  assert.throws(()=>cappedPlan('a','a','b',{maxMatches:-1}),/上限/);
});
test('input admission rejects before reading or allocating boundary data', () => {
  const input={text:'abc',query:'a',replacement:'b',limits:{maxInputUTF16:2},
    get boundaries(){ throw new Error('boundary data must not be read'); }};
  assert.throws(()=>planner.plan(input),/文字列が上限/);
});
test('query and replacement input lengths also have caps', () => {
  assert.throws(()=>cappedPlan('a','aaa','b',{maxInputUTF16:2}),/文字列が上限/);
  assert.throws(()=>cappedPlan('a','a','bbb',{maxInputUTF16:2}),/文字列が上限/);
});
test('expanding output is rejected in its entirety instead of truncated', () => {
  const input='aa';
  assert.throws(()=>cappedPlan(input,'a','bb',{maxOutputUTF16:3}),/置換後の文字数/);
  assert.equal(input,'aa');
});
test('shrinking output is admitted using final length rather than intermediate length', () => {
  const result=cappedPlan('aaaa','a','',{maxOutputUTF16:2});
  assert.equal(result.count,4);assert.equal(result.candidate,'');assert.equal(result.outputUTF16,0);
});
test('conservative UTF8 input and output upper bounds have separate guards', () => {
  assert.throws(()=>cappedPlan('猫猫','猫','',{maxInputUTF8UpperBound:5}),/入力の UTF-8/);
  assert.throws(()=>cappedPlan('a','a','猫猫',{maxOutputUTF8UpperBound:5}),/置換後の UTF-8/);
});
test('match cap rejects the entire plan without partial replacement', () => {
  assert.throws(()=>cappedPlan('aaa','a','b',{maxMatches:2}),/一致件数/);
  assert.equal(cappedPlan('aa','a','b',{maxMatches:2}).candidate,'bb');
});
test('preflight peak estimate rejects input before boundary construction', () => {
  const input={text:'a'.repeat(50000),query:'a',replacement:'b',limits:{memoryBudgetBytes:10*1024*1024},
    get boundaries(){ throw new Error('boundary data must not be read'); }};
  assert.throws(()=>planner.plan(input),/推定メモリ/);
});
test('combined output and undo estimate rejects expansion before candidate assembly', () => {
  const replacement='b'.repeat(100000), limits={memoryBudgetBytes:20*1024*1024};
  assert.doesNotThrow(()=>planner.preflight({text:'aaaaa',query:'a',replacement,limits}));
  assert.throws(()=>cappedPlan('aaaaa','a',replacement,limits),/候補と Undo/);
});
test('production result omits match arrays unless explicitly requested', () => {
  const minimal=cappedPlan('aa','a','b',{});
  assert.equal(Object.hasOwn(minimal,'matches'),false);
  const detailed=cappedPlan('aa','a','b',{}, {includeMatches:true});
  assert.deepEqual(detailed.matches,[{location:0,length:1},{location:1,length:1}]);
  assert.equal(detailed.outputUTF16,2);assert.equal(detailed.outputUTF8UpperBound,6);
  assert.ok(detailed.estimatedPeakBytes>minimal.estimatedPeakBytes);
});
test('candidate selection guards run before boundary data is read', () => {
  const input={text:'abcd',selection:{location:0,length:0},limits:{maxOutputUTF16:3},
    get boundaries(){ throw new Error('boundary data must not be read'); }};
  assert.throws(()=>planner.finalizeSelection(input),/候補の文字数/);
});
test('whole-text application admits ordinary input using the production guard',()=>{
  const result=planner.applicationPreflight({current:'端末の本文',candidate:'復元した本文'});
  assert.ok(result.estimatedPeakBytes>8*1024*1024);
});
test('whole-text application rejects the joint current candidate and undo peak',()=>{
  const current='a'.repeat(900000),candidate='b'.repeat(900000);
  assert.throws(()=>planner.applicationPreflight({current,candidate}),/現在の本文・候補・Undo/);
  assert.equal(current.length,900000);assert.equal(candidate.length,900000);
});
