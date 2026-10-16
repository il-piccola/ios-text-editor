/* Original bounded line-based three-way comparison. Never writes or edits a document. */
(function (root) {
    'use strict';
    var WORK_LIMIT = 1000000;
    function normalized(text) { return text.replace(/\r\n|\r/g, '\n'); }
    function lines(text) { return normalized(text).split('\n'); }
    function equal(a, b) { return a.length === b.length && a.every(function (v, i) { return v === b[i]; }); }
    function markAmbiguous(changes, base) {
        var counts = Object.create(null);
        base.forEach(function (line) { counts[line] = (counts[line] || 0) + 1; });
        changes.ambiguous = changes.some(function (change) {
            return change.end - change.start !== change.replacement.length && base.slice(change.start, change.end).some(function (line) { return counts[line] > 1; });
        });
        return changes;
    }
    function edits(base, changed) {
        var prefix = 0, suffix = 0;
        while (prefix < base.length && prefix < changed.length && base[prefix] === changed[prefix]) prefix++;
        while (suffix < base.length - prefix && suffix < changed.length - prefix && base[base.length - 1 - suffix] === changed[changed.length - 1 - suffix]) suffix++;
        var a = base.slice(prefix, base.length - suffix), b = changed.slice(prefix, changed.length - suffix);
        if (a.length > 20000 || b.length > 20000 || (a.length + 1) * (b.length + 1) > WORK_LIMIT) return null;
        if (!a.length) return b.length ? [{start: prefix, end: prefix, replacement: b}] : [];
        if (!b.length) return markAmbiguous([{start: prefix, end: prefix + a.length, replacement: []}],base);
        var table = new Array(a.length + 1), i, j;
        for (i = 0; i <= a.length; i++) table[i] = new Uint32Array(b.length + 1);
        for (i = a.length - 1; i >= 0; i--) for (j = b.length - 1; j >= 0; j--) {
            table[i][j] = a[i] === b[j] ? table[i + 1][j + 1] + 1 : Math.max(table[i + 1][j], table[i][j + 1]);
        }
        var result = [], active = null; i = 0; j = 0;
        function flush() { if (active) { result.push(active); active = null; } }
        while (i < a.length || j < b.length) {
            if (i < a.length && j < b.length && a[i] === b[j]) { flush(); i++; j++; continue; }
            if (!active) active = {start: prefix + i, end: prefix + i, replacement: []};
            if (j < b.length && (i === a.length || table[i][j + 1] >= table[i + 1][j])) active.replacement.push(b[j++]);
            else { i++; active.end = prefix + i; }
        }
        flush();
        // Equal-length replacements can be compared by their original line positions.
        // Keep unequal-length edits as blocks: insertion/deletion alignment is ambiguous.
        var granular = [];
        result.forEach(function (change) {
            if (change.end - change.start === change.replacement.length && change.replacement.length > 1) {
                change.replacement.forEach(function (line, offset) { granular.push({start:change.start + offset, end:change.start + offset + 1, replacement:[line]}); });
            } else granular.push(change);
        });
        // Repeated deleted lines have several plausible anchors. Require a user choice.
        return markAmbiguous(granular,base);
    }
    function overlaps(a, b) {
        if (a.start === a.end) return a.start >= b.start && a.start <= b.end;
        if (b.start === b.end) return b.start >= a.start && b.start <= a.end;
        return a.start < b.end && b.start < a.end;
    }
    function render(base, start, end, changes) {
        var output = [], cursor = start;
        changes.sort(function (a, b) { return a.start - b.start || a.end - b.end; });
        changes.forEach(function (change) {
            output = output.concat(base.slice(cursor, change.start), change.replacement); cursor = change.end;
        });
        return output.concat(base.slice(cursor, end));
    }
    function compare(input) {
        if (!input || typeof input.base !== 'string' || typeof input.local !== 'string' || typeof input.remote !== 'string') throw new TypeError('base/local/remote must be strings');
        var raw = {base: input.base, local: input.local, remote: input.remote};
        var base = lines(input.base), local = lines(input.local), remote = lines(input.remote);
        var result = {schemaVersion: 1, raw: raw, comparisonLineEnding: 'lf', candidate: null, status: 'merged', conflictBlocks: [], limited: false, ambiguous: false, segments: []};
        if (equal(local, remote)) { result.candidate = local.join('\n'); return result; }
        if (equal(base, local)) { result.candidate = remote.join('\n'); return result; }
        if (equal(base, remote)) { result.candidate = local.join('\n'); return result; }
        var left = edits(base, local), right = edits(base, remote);
        if (left === null || right === null || left.ambiguous || right.ambiguous) {
            result.status = 'conflict'; result.limited = left === null || right === null; result.ambiguous = !result.limited;
            result.conflictBlocks.push({baseStart: 0, baseEnd: base.length, base: base.join('\n'), local: local.join('\n'), remote: remote.join('\n'), baseLines: base, localLines: local, remoteLines: remote});
            result.segments.push({type: 'conflict', index: 0});
            return result;
        }
        var changes = [];
        left.forEach(function (change) { change.side = 'local'; changes.push(change); });
        right.forEach(function (change) {
            var same = changes.find(function (x) { return x.start === change.start && x.end === change.end && equal(x.replacement, change.replacement); });
            if (same) same.side = 'both'; else { change.side = 'remote'; changes.push(change); }
        });
        changes.sort(function (a, b) { return a.start - b.start || a.end - b.end; });
        var groups = [];
        changes.forEach(function (change) {
            var group = groups[groups.length - 1];
            if (group && group.some(function (x) { return overlaps(x, change); })) group.push(change);
            else groups.push([change]);
        });
        var output = [], cursor = 0;
        groups.forEach(function (group) {
            var start = Math.min.apply(null, group.map(function (x) { return x.start; }));
            var end = Math.max.apply(null, group.map(function (x) { return x.end; }));
            output = output.concat(base.slice(cursor, start));
            result.segments.push({type: 'lines', lines: base.slice(cursor, start)});
            if (group.length === 1) { output = output.concat(group[0].replacement); result.segments.push({type: 'lines', lines: group[0].replacement}); }
            else {
                var localPart = render(base, start, end, group.filter(function (x) { return x.side !== 'remote'; }));
                var remotePart = render(base, start, end, group.filter(function (x) { return x.side !== 'local'; }));
                if (equal(localPart, remotePart)) { output = output.concat(localPart); result.segments.push({type: 'lines', lines: localPart}); }
                else {
                    result.segments.push({type: 'conflict', index: result.conflictBlocks.length});
                    result.conflictBlocks.push({baseStart: start, baseEnd: end, base: base.slice(start, end).join('\n'), local: localPart.join('\n'), remote: remotePart.join('\n'), baseLines: base.slice(start, end), localLines: localPart, remoteLines: remotePart});
                }
            }
            cursor = end;
        });
        output = output.concat(base.slice(cursor));
        result.segments.push({type: 'lines', lines: base.slice(cursor)});
        if (result.conflictBlocks.length) result.status = 'conflict'; else result.candidate = output.join('\n');
        return result;
    }
    function resolve(result, choices) {
        if (!result || result.schemaVersion !== 1 || !Array.isArray(result.conflictBlocks) || !Array.isArray(result.segments) || !Array.isArray(choices) || choices.length !== result.conflictBlocks.length) throw new TypeError('A choice is required for every conflict');
        if (result.status === 'merged' && typeof result.candidate === 'string' && !choices.length) return result.candidate;
        if (result.status !== 'conflict') throw new TypeError('Invalid comparison result');
        choices.forEach(function (choice) {
            if (['local', 'remote', 'base'].indexOf(choice) >= 0) return;
            if (!choice || Object.getPrototypeOf(choice) !== Object.prototype || choice.kind !== 'manual' || typeof choice.text !== 'string' || Object.keys(choice).some(function (key) { return key !== 'kind' && key !== 'text'; })) throw new TypeError('Invalid conflict choice');
        });
        var output = [];
        result.segments.forEach(function (segment) {
            if (segment.type === 'lines' && Array.isArray(segment.lines) && segment.lines.every(function (line) { return typeof line === 'string'; })) output = output.concat(segment.lines);
            else if (segment.type === 'conflict' && Number.isSafeInteger(segment.index) && segment.index >= 0 && segment.index < choices.length) {
                var choice = choices[segment.index];
                var selected = typeof choice === 'string' ? result.conflictBlocks[segment.index][choice + 'Lines'] : (choice.text === '' ? [] : lines(choice.text));
                if (!Array.isArray(selected) || !selected.every(function (line) { return typeof line === 'string'; })) throw new TypeError('Invalid conflict lines');
                output = output.concat(selected);
            } else throw new TypeError('Invalid result segment');
        });
        return output.join('\n');
    }
    root.IyoMerge = Object.freeze({compare: compare, resolve: resolve});
})(globalThis);
