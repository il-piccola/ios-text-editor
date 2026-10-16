/* Original shared capacity arithmetic. No disk access, clock, random or automatic deletion. */
(function (root) {
    'use strict';
    var MiB = 1024 * 1024;
    var defaults = Object.freeze({budgetBytes:256 * MiB,maxIncomingBytes:64 * MiB,reserveBytes:128 * MiB});
    function count(value, label) {
        if (!Number.isSafeInteger(value) || value < 0) throw new TypeError(label);
        return value;
    }
    function sum(a,b) { return count(a+b,'Capacity arithmetic overflow'); }
    function utf8Bytes(text) {
        if (typeof text !== 'string') throw new TypeError('text');
        var total=0;
        for(var i=0;i<text.length;i++) {
            var point=text.charCodeAt(i);
            if(point<=0x7f) total++;
            else if(point<=0x7ff) total+=2;
            else if(point>=0xd800 && point<=0xdbff && i+1<text.length && text.charCodeAt(i+1)>=0xdc00 && text.charCodeAt(i+1)<=0xdfff) {total+=4;i++;}
            else total+=3;
        }
        return count(total,'UTF8 size');
    }
    function plan(input) {
        if(!input || typeof input!=='object' || Array.isArray(input)) throw new TypeError('Capacity input');
        var incoming=count(input.incomingBytes,'incomingBytes'),previous=count(input.previousBytes,'previousBytes'),existing=count(input.existingBytes,'existingBytes');
        if(previous>existing) throw new TypeError('Previous bytes exceed stored bytes');
        var budget=count(input.budgetBytes===undefined?defaults.budgetBytes:input.budgetBytes,'budgetBytes');
        var maximum=count(input.maxIncomingBytes===undefined?defaults.maxIncomingBytes:input.maxIncomingBytes,'maxIncomingBytes');
        var reserve=count(input.reserveBytes===undefined?defaults.reserveBytes:input.reserveBytes,'reserveBytes');
        var available=input.availableBytes===null?null:count(input.availableBytes,'availableBytes');
        var peak=sum(existing,incoming),finalBytes=sum(existing-previous,incoming),required=sum(incoming,reserve);
        var reason=incoming>maximum?'recordLimit':peak>budget?'budgetPeak':available===null?'availableUnknown':available<required?'diskReserve':null;
        return {allowed:reason===null,reason:reason,incomingBytes:incoming,previousBytes:previous,existingBytes:existing,budgetBytes:budget,maxIncomingBytes:maximum,
            reserveBytes:reserve,availableBytes:available,finalBytes:finalBytes,replacementPeakBytes:peak,requiredAdditionalBytes:required,
            remainingBudgetBytes:Math.max(0,budget-existing),automaticDeletion:false};
    }
    root.IyoCapacity=Object.freeze({defaults:defaults,utf8Bytes:utf8Bytes,plan:plan});
})(globalThis);
