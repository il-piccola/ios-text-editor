(function (root) {
  "use strict";
  var DEFAULT_LIMITS = Object.freeze({
    maxInputUTF16: 4 * 1024 * 1024, maxOutputUTF16: 4 * 1024 * 1024,
    maxInputUTF8UpperBound: 20 * 1024 * 1024, maxOutputUTF8UpperBound: 20 * 1024 * 1024,
    maxMatches: 100000, memoryBudgetBytes: 128 * 1024 * 1024
  });
  function fail(message) { throw new Error(message); }
  function integer(value) { return Number.isSafeInteger(value) && value >= 0; }
  function limits(input) {
    var result = {}, supplied = input.limits || {};
    Object.keys(DEFAULT_LIMITS).forEach(function (key) {
      var value = supplied[key] === undefined ? DEFAULT_LIMITS[key] : supplied[key];
      if (!integer(value) || value === 0 || value > DEFAULT_LIMITS[key])
        fail("置換の上限が不正です。上限の拡張はこの試作ではできません。");
      result[key] = value;
    });
    return result;
  }
  // Conservative admission estimate, not a measurement of actual process RSS.
  // Includes text crossings/copies, native + JS boundary storage and output/undo copies.
  function estimatedPeak(inputUnits, outputUnits, matches, includeMatches) {
    return 8 * 1024 * 1024 + inputUnits * 76 + outputUnits * 76 + matches * (includeMatches ? 192 : 128);
  }
  function preflight(input) {
    if (!input || typeof input.text !== "string" || typeof input.query !== "string" || typeof input.replacement !== "string")
      fail("置換する文字列を確認できません。");
    var cap = limits(input);
    if (input.text.length > cap.maxInputUTF16 || input.query.length > cap.maxInputUTF16 || input.replacement.length > cap.maxInputUTF16)
      fail("置換する文字列が上限を超えています。本文は変更していません。");
    var inputUnits = input.text.length + input.query.length + input.replacement.length;
    var utf8UpperBound = inputUnits * 3;
    if (utf8UpperBound > cap.maxInputUTF8UpperBound)
      fail("入力の UTF-8 上限を超えています。本文は変更していません。");
    if (estimatedPeak(inputUnits, 0, 0, false) > cap.memoryBudgetBytes)
      fail("置換に必要な推定メモリが上限を超えています。本文は変更していません。");
    return { limits: cap, inputUTF16: input.text.length, inputUTF8UpperBound: utf8UpperBound,
      estimatedInputPeakBytes: estimatedPeak(inputUnits, 0, 0, false) };
  }
  function checkedBoundaries(text, boundaries) {
    if (!Array.isArray(boundaries) || boundaries[0] !== 0 || boundaries[boundaries.length - 1] !== text.length)
      fail("文字の境界を確認できません。");
    for (var i = 0; i < boundaries.length; i++) {
      if (!integer(boundaries[i]) || (i && boundaries[i] <= boundaries[i - 1])) fail("文字の境界が不正です。");
    }
    return boundaries;
  }
  function applicationPreflight(input) {
    var cap = limits(input);
    if (typeof input.current !== "string" || typeof input.candidate !== "string") fail("適用する本文を確認できません。");
    if (input.current.length > cap.maxInputUTF16 || input.candidate.length > cap.maxOutputUTF16 ||
        input.current.length * 3 > cap.maxInputUTF8UpperBound || input.candidate.length * 3 > cap.maxOutputUTF8UpperBound)
      fail("本文または候補が適用上限を超えています。本文は変更していません。");
    var peak = estimatedPeak(input.current.length, input.candidate.length, 0, false);
    if (peak > cap.memoryBudgetBytes) fail("現在の本文・候補・Undo に必要な推定メモリが上限を超えています。本文は変更していません。");
    return { estimatedPeakBytes: peak };
  }
  function checkedRange(text, range) {
    if (!range || !integer(range.location) || !integer(range.length) || range.location + range.length > text.length)
      fail("選択範囲が不正です。もう一度選択してください。");
  }
  function boundaryIndex(boundaries, point) {
    var low = 0, high = boundaries.length - 1;
    while (low <= high) {
      var mid = Math.floor((low + high) / 2), value = boundaries[mid];
      if (value === point) return mid;
      if (value < point) low = mid + 1; else high = mid - 1;
    }
    return -1;
  }
  function visitMatches(input, valid, from, to, visitor) {
    var next = from;
    while (next <= to - input.query.length) {
      var found = input.text.indexOf(input.query, next);
      if (found < 0 || found + input.query.length > to) break;
      if (boundaryIndex(valid, found) >= 0 && boundaryIndex(valid, found + input.query.length) >= 0) {
        visitor(found, input.query.length);
        next = found + input.query.length;
      } else next = found + 1;
    }
  }
  function mappedPoint(point, from, length, delta, replacementLength, after) {
    if (point < from) return null;
    if (point < from + length) return from + delta + (after ? replacementLength : 0);
    return undefined;
  }
  function plan(input) {
    var admission = preflight(input), cap = admission.limits;
    if (!input.query.length) fail("検索する文字列を入力してください。");
    if (input.includeMatches !== undefined && typeof input.includeMatches !== "boolean") fail("置換結果の指定が不正です。");
    var text = input.text, valid = checkedBoundaries(text, input.boundaries);
    checkedRange(text, input.selection);
    if (boundaryIndex(valid, input.selection.location) < 0 || boundaryIndex(valid, input.selection.location + input.selection.length) < 0)
      fail("選択範囲が文字の途中です。もう一度選択してください。");
    if (input.scope !== "document" && input.scope !== "selection") fail("置換範囲が不正です。");
    var from = input.scope === "selection" ? input.selection.location : 0;
    var to = input.scope === "selection" ? from + input.selection.length : text.length;
    if (input.scope === "selection" && from === to) fail("置換する範囲を本文で選択してください。");
    var count = 0, outputUnits = text.length, outputUTF8UpperBound, peak;
    // First pass does not build output, pieces or match arrays.
    visitMatches(input, valid, from, to, function (_, length) {
      count += 1;
      if (count > cap.maxMatches) fail("一致件数が上限を超えています。途中までの置換は行いません。");
      outputUnits += input.replacement.length - length;
      if (!integer(outputUnits)) fail("置換後の文字数を確認できません。");
    });
    if (outputUnits > cap.maxOutputUTF16)
      fail("置換後の文字数が上限を超えています。本文は変更していません。");
    outputUTF8UpperBound = outputUnits * 3;
    if (outputUTF8UpperBound > cap.maxOutputUTF8UpperBound)
      fail("置換後の UTF-8 上限を超えています。本文は変更していません。");
    var includeMatches = input.includeMatches === true;
    peak = estimatedPeak(text.length + input.query.length + input.replacement.length, outputUnits, count, includeMatches);
    if (peak > cap.memoryBudgetBytes)
      fail("置換後の候補と Undo に必要な推定メモリが上限を超えています。本文は変更していません。");
    var pieces = [], copied = 0, delta = 0, matches = includeMatches ? [] : null;
    var start = input.selection.location, end = start + input.selection.length;
    var mappedStart, mappedEnd;
    visitMatches(input, valid, from, to, function (location, length) {
      if (mappedStart === undefined) {
        var first = mappedPoint(start, location, length, delta, input.replacement.length, input.selection.length === 0);
        if (first === null) mappedStart = start + delta; else if (first !== undefined) mappedStart = first;
      }
      if (mappedEnd === undefined) {
        var last = mappedPoint(end, location, length, delta, input.replacement.length, true);
        if (last === null) mappedEnd = end + delta; else if (last !== undefined) mappedEnd = last;
      }
      pieces.push(text.slice(copied, location), input.replacement);
      copied = location + length;
      delta += input.replacement.length - length;
      if (matches) matches.push({ location: location, length: length });
    });
    pieces.push(text.slice(copied));
    if (mappedStart === undefined) mappedStart = start + delta;
    if (mappedEnd === undefined) mappedEnd = end + delta;
    var candidate = pieces.join("");
    var result = { count: count, candidate: candidate,
      proposedSelection: { location: mappedStart, length: Math.max(0, mappedEnd - mappedStart) }, isNoOp: candidate === text,
      outputUTF16: outputUnits, outputUTF8UpperBound: outputUTF8UpperBound, estimatedPeakBytes: peak };
    if (matches) result.matches = matches;
    return result;
  }
  function floorBoundary(boundaries, point) {
    var low = 0, high = boundaries.length - 1;
    while (low < high) { var mid = Math.ceil((low + high) / 2); if (boundaries[mid] <= point) low = mid; else high = mid - 1; }
    return boundaries[low];
  }
  function ceilBoundary(boundaries, point) {
    var low = 0, high = boundaries.length - 1;
    while (low < high) { var mid = Math.floor((low + high) / 2); if (boundaries[mid] >= point) high = mid; else low = mid + 1; }
    return boundaries[low];
  }
  function finalizeSelection(input) {
    var cap = limits(input);
    if (typeof input.text !== "string" || input.text.length > cap.maxOutputUTF16 ||
        input.text.length * 3 > cap.maxOutputUTF8UpperBound ||
        estimatedPeak(0, input.text.length, 0, false) > cap.memoryBudgetBytes)
      fail("候補の文字数または推定メモリが上限を超えています。");
    checkedBoundaries(input.text, input.boundaries);
    checkedRange(input.text, input.selection);
    if (input.selection.length === 0) return { location: ceilBoundary(input.boundaries, input.selection.location), length: 0 };
    var start = floorBoundary(input.boundaries, input.selection.location);
    var end = ceilBoundary(input.boundaries, input.selection.location + input.selection.length);
    return { location: start, length: end - start };
  }
  var api = { plan: plan, preflight: preflight, applicationPreflight: applicationPreflight, finalizeSelection: finalizeSelection, defaultLimits: DEFAULT_LIMITS };
  root.IyoReplacement = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
