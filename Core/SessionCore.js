/* Iyo prototype: original dependency-free JSON reducer. No editor/IME implementation. */
(function (root) {
    "use strict";
    var FORMATS = ["utf8", "utf8BOM", "utf16LE", "utf16BE"];
    var LINE_ENDINGS = ["crlf", "preserve"];
    function fail(message) { throw new TypeError(message); }
    function json(value) {
        if (value === null || typeof value === "string" || typeof value === "boolean") return;
        if (typeof value === "number" && Number.isFinite(value)) return;
        if (Array.isArray(value)) { value.forEach(json); return; }
        if (typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype) {
            Object.keys(value).forEach(function (key) { json(value[key]); }); return;
        }
        fail("Only JSON values are supported");
    }
    function copy(value) { return JSON.parse(JSON.stringify(value)); }
    function str(value, label) {
        if (typeof value !== "string" || !value.length || /[\u0000-\u001f]/.test(value)) fail(label);
        return value;
    }
    function integer(value, minimum, label) {
        if (!Number.isSafeInteger(value) || value < minimum) fail(label);
        return value;
    }
    function validName(value) {
        return typeof value === "string" && value.trim().length > 0 && !/[\u0000-\u001f\/:\\]/.test(value) && value !== "." && value !== "..";
    }
    function name(value) { if (!validName(value)) fail("Invalid name"); return value; }
    function target(value) {
        if (value === null) return null;
        if (!value || typeof value !== "object") fail("Invalid target");
        str(value.identity, "target.identity"); name(value.name); str(value.location, "target.location");
        if (!value.baseline || !/^[a-fA-F0-9]{64}$/.test(value.baseline.sha256)) fail("target.baseline.sha256");
        integer(value.baseline.byteCount, 0, "target.baseline.byteCount");
        if (value.baseText !== undefined && typeof value.baseText !== "string") fail("target.baseText");
        if (value.format !== undefined && FORMATS.indexOf(value.format) < 0) fail("target.format");
        if (value.lineEnding !== undefined && LINE_ENDINGS.indexOf(value.lineEnding) < 0) fail("target.lineEnding");
        return copy(value);
    }
    function record(value) {
        str(value.id, "id"); name(value.name);
        if (typeof value.text !== "string") fail("text");
        if (FORMATS.indexOf(value.format) < 0) fail("format");
        if (LINE_ENDINGS.indexOf(value.lineEnding) < 0) fail("lineEnding");
        integer(value.revision, 0, "revision"); integer(value.epoch, 0, "epoch"); target(value.target);
        if (value.acceptedRevision !== null) {
            integer(value.acceptedRevision, 0, "acceptedRevision");
            if (!value.target || value.acceptedRevision > value.revision) fail("acceptedRevision exceeds revision or has no target");
        }
    }
    function evidence(value, revision) {
        if (!value || typeof value !== "object" || Array.isArray(value)) fail("evidence");
        str(value.token,"evidence.token");
        if (typeof value.text !== "string" || typeof value.localText !== "string" || (value.baseText !== null && typeof value.baseText !== "string") || FORMATS.indexOf(value.format) < 0) fail("evidence text/format");
        var evidenceTarget = target(value.target); if (!evidenceTarget) fail("evidence target");
        integer(value.observedRevision,0,"evidence observedRevision"); integer(value.snapshotRevision,0,"evidence snapshotRevision");
        if (value.snapshotRevision > value.observedRevision || value.observedRevision > revision) fail("evidence revision");
        return evidenceTarget;
    }
    function retainCandidate(state) {
        var value = state.remoteCandidate; if (value === null) return;
        var same = state.retainedEvidence.some(function (old) {
            return old.baseText === value.baseText && old.localText === value.localText && old.text === value.text && old.format === value.format
                && old.target.identity === value.target.identity && old.target.baseline.sha256 === value.target.baseline.sha256 && old.target.baseline.byteCount === value.target.baseline.byteCount;
        });
        if (!same) state.retainedEvidence.push(copy(value));
    }
    function historyID(state,item) {
        return JSON.stringify([state.id,item.token,item.target.identity,item.target.baseline.sha256,item.target.baseline.byteCount,item.format]);
    }
    function deleteBlock(state) {
        if(state.isComposing) return "日本語の変換を確定してください。";
        if(state.uncertain) return "書込み結果を確認してから履歴を削除してください。";
        if(state.operation || state.pendingEvidenceDeletion || state.pendingEvidenceRestore || state.pendingDrafts.length) return "保護・保存処理の完了を待ってください。";
        if(state.conflict) return "外部変更を確認するまで履歴を保護します。";
        if(!state.target || state.acceptedRevision!==state.revision) return "未保存の本文があるため履歴を保護します。";
        if(state.draftError || state.protectedRevision!==state.revision) return "現在の下書き保護を確認してください。";
        return null;
    }
    function historyList(state) {
        json(state); validateState(state);
        if(!root.IyoCapacity) fail("CapacityPolicy.js must be loaded");
        var reason=deleteBlock(state);
        return state.retainedEvidence.map(function(item) {
            var base=root.IyoCapacity.utf8Bytes(item.baseText===null?"":item.baseText),local=root.IyoCapacity.utf8Bytes(item.localText),remote=root.IyoCapacity.utf8Bytes(item.text);
            return {id:historyID(state,item),name:item.target.name,baseBytes:base,localBytes:local,remoteBytes:remote,totalBytes:base+local+remote,canDelete:reason===null,deleteBlockReason:reason};
        });
    }
    function evidenceFor(state,id) {
        json(state);validateState(state);str(id,"historyID");
        var item=state.retainedEvidence.find(function(value){return historyID(state,value)===id;});
        return item?copy(item):null;
    }
    function create(seed) {
        json(seed); if (!seed || typeof seed !== "object" || Array.isArray(seed)) fail("seed");
        ["uncertain","remoteValidated"].forEach(function (key) { if (seed[key] !== undefined && typeof seed[key] !== "boolean") fail(key); });
        var state = {
            id: seed.id, sessionID: seed.sessionID, name: seed.name === undefined ? "無題.txt" : seed.name,
            text: seed.text === undefined ? "" : seed.text, format: seed.format === undefined ? "utf8" : seed.format,
            lineEnding: seed.lineEnding === undefined ? "crlf" : seed.lineEnding,
            revision: seed.revision === undefined ? 0 : seed.revision, epoch: seed.epoch === undefined ? 0 : seed.epoch,
            protectedRevision: seed.protectedRevision === undefined ? -1 : seed.protectedRevision,
            acceptedRevision: seed.acceptedRevision === undefined ? null : seed.acceptedRevision,
            target: seed.target === undefined ? null : target(seed.target), isComposing: false, operation: null,
            draftError: null, fileError: null, fileErrorCode: null, conflict: false,
            cloudStatus: "unconfirmed", pendingDrafts: [], usedTokens: [],
            remoteValidated: seed.remoteValidated === true, remoteObservation: null, remoteCandidate: seed.remoteCandidate === undefined ? null : copy(seed.remoteCandidate),
            retainedEvidence:seed.retainedEvidence === undefined ? [] : copy(seed.retainedEvidence),
            pendingEvidenceDeletion:null,pendingEvidenceRestore:null,
            uncertain: seed.uncertain === true, unknownOperation: seed.unknownOperation === undefined ? null : copy(seed.unknownOperation)
        };
        str(state.sessionID, "sessionID"); record(state);
        integer(state.protectedRevision, -1, "protectedRevision");
        if (state.protectedRevision > state.revision) fail("protectedRevision exceeds revision");
        validateState(state);
        if (state.remoteCandidate && (state.remoteCandidate.target.baseline.sha256 !== state.target.baseline.sha256 || state.remoteCandidate.target.baseline.byteCount !== state.target.baseline.byteCount ||
            (state.remoteCandidate.baseText!==null && state.target.baseText!==undefined && state.remoteCandidate.baseText!==state.target.baseText))) state.conflict = true;
        return state;
    }
    function restore(envelope) {
        json(envelope); envelope = copy(envelope);
        if (!envelope || envelope.schemaVersion !== 1) fail("Unsupported draft schema");
        if (envelope.uncertain !== undefined && typeof envelope.uncertain !== "boolean") fail("envelope.uncertain");
        if (envelope.lineEnding === undefined) envelope.lineEnding = "preserve";
        record(envelope);
        var pendingWrite = envelope.pendingWrite === undefined ? null : envelope.pendingWrite;
        var state = create({id: envelope.id, sessionID: "restore-placeholder", name: envelope.name,
            text: envelope.text, format: envelope.format, revision: envelope.revision, epoch: envelope.epoch,
            lineEnding: envelope.lineEnding, target: envelope.target, acceptedRevision: envelope.acceptedRevision, protectedRevision: envelope.revision,
            uncertain: pendingWrite !== null || envelope.uncertain === true,
            unknownOperation: pendingWrite !== null ? pendingWrite : (envelope.unknownOperation === undefined ? null : envelope.unknownOperation),
            remoteCandidate:envelope.remoteCandidate === undefined ? null : envelope.remoteCandidate,
            retainedEvidence:envelope.retainedEvidence === undefined ? [] : envelope.retainedEvidence});
        state.sessionID = null; // The host MUST inject a fresh runtime session UUID before reduce.
        return state;
    }
    function envelope(state) {
        var pendingWrite = null;
        if (state.operation && state.operation.kind !== "reload") { pendingWrite = copy(state.operation); pendingWrite.phase = "writing"; }
        return {schemaVersion: 1, id: state.id, name: state.name, text: state.text, format: state.format,
            lineEnding: state.lineEnding, revision: state.revision, epoch: state.epoch, target: copy(state.target), acceptedRevision: state.acceptedRevision,
            uncertain: state.uncertain, unknownOperation: copy(state.unknownOperation), pendingWrite:pendingWrite, remoteCandidate:copy(state.remoteCandidate),
            retainedEvidence:copy(state.retainedEvidence.filter(function(item){return !state.pendingEvidenceDeletion || state.pendingEvidenceDeletion.ids.indexOf(historyID(state,item))<0;}))};
    }
    function useToken(state, token) {
        str(token, "token");
        if (state.usedTokens.indexOf(token) >= 0) return false;
        state.usedTokens.push(token); return true;
    }
    function persist(state, token, role, effects) {
        integer(state.epoch + 1, 0, "epoch overflow"); state.epoch += 1;
        var item={token: token, sessionID: state.sessionID, revision: state.revision, epoch: state.epoch, role: role};
        if(state.pendingEvidenceDeletion){item.role="evidenceDelete";item.deletionToken=state.pendingEvidenceDeletion.token;}
        state.pendingDrafts.push(item);
        effects.push({type: "PERSIST", token: token, sessionID: state.sessionID, envelope: envelope(state)});
    }
    function snapshot(state) {
        return {id: state.id, sessionID: state.sessionID, name: state.name, text: state.text,
            format: state.format, lineEnding: state.lineEnding, revision: state.revision, target: copy(state.target)};
    }
    function pendingIndex(state, token) {
        return state.pendingDrafts.findIndex(function (item) { return item.token === token; });
    }
    function validateState(state) {
        record(state); str(state.sessionID, "sessionID must be replaced after restore");
        integer(state.protectedRevision, -1, "protectedRevision");
        if (state.protectedRevision > state.revision || state.cloudStatus !== "unconfirmed") fail("Invalid protection/cloud state");
        if (typeof state.isComposing !== "boolean" || typeof state.conflict !== "boolean" || typeof state.uncertain !== "boolean" || typeof state.remoteValidated !== "boolean") fail("Invalid flags");
        if (state.remoteObservation !== null) target(state.remoteObservation);
        if (state.remoteCandidate !== null) {
            var candidateTarget = evidence(state.remoteCandidate,state.revision);
            if (!candidateTarget || !state.target || candidateTarget.identity !== state.target.identity) fail("candidate target");
        }
        if (!Array.isArray(state.retainedEvidence)) fail("retainedEvidence");
        var historyIDs=[];
        state.retainedEvidence.forEach(function (item) { evidence(item,state.revision);var id=historyID(state,item);if(historyIDs.indexOf(id)>=0) fail("Duplicate history ID");historyIDs.push(id); });
        if(state.pendingEvidenceDeletion!==null) {
            var deletion=state.pendingEvidenceDeletion;str(deletion.token,"deletion.token");
            if(!Array.isArray(deletion.ids) || !deletion.ids.length || deletion.ids.some(function(id){return historyIDs.indexOf(id)<0;})) fail("deletion.ids");
        }
        if(state.pendingEvidenceRestore!==null) {
            var restoration=state.pendingEvidenceRestore;str(restoration.token,"restoration.token");
            if(historyIDs.indexOf(restoration.historyID)<0 || ["base","local","remote"].indexOf(restoration.source)<0 || typeof restoration.text!=="string" || typeof restoration.expectedText!=="string") fail("restoration");
            integer(restoration.revision,0,"restoration.revision");if(restoration.revision>state.revision) fail("Future restoration");
        }
        if (state.unknownOperation !== null) {
            var unknown = state.unknownOperation, unknownSnapshot = unknown.snapshot;
            str(unknown.token, "unknownOperation.token");
            if (["existing", "saveAs"].indexOf(unknown.kind) < 0 || unknown.phase !== "writing") fail("unknown operation kind/phase");
            if (!unknownSnapshot || unknownSnapshot.id !== state.id || typeof unknownSnapshot.text !== "string") fail("unknownOperation.snapshot");
            str(unknownSnapshot.sessionID, "unknown snapshot session"); name(unknownSnapshot.name);
            if (FORMATS.indexOf(unknownSnapshot.format) < 0 || LINE_ENDINGS.indexOf(unknownSnapshot.lineEnding) < 0) fail("unknown snapshot format");
            integer(unknownSnapshot.revision, 0, "unknown revision");
            if (unknownSnapshot.revision > state.revision) fail("future unknown revision");
            target(unknownSnapshot.target);
            if (unknown.kind === "existing" && !unknownSnapshot.target) fail("unknown existing target");
            if (unknown.kind === "saveAs") name(unknown.name);
        }
        if (state.uncertain !== (state.unknownOperation !== null)) fail("Invalid uncertain operation");
        [state.draftError, state.fileError, state.fileErrorCode].forEach(function (value) {
            if (value !== null && typeof value !== "string") fail("Invalid error field");
        });
        if (!Array.isArray(state.pendingDrafts) || !Array.isArray(state.usedTokens)) fail("Missing reducer bookkeeping");
        state.usedTokens.forEach(function (token) { str(token, "usedToken"); });
        state.pendingDrafts.forEach(function (item) {
            str(item.token, "pending token");
            if (item.sessionID !== state.sessionID || ["protect", "save", "metadata", "reload","evidenceDelete","evidenceRestore"].indexOf(item.role) < 0) fail("Invalid pending draft");
            if(item.role==="evidenceDelete") str(item.deletionToken,"deletionToken");
            integer(item.revision, 0, "pending revision"); integer(item.epoch, 1, "pending epoch");
            if (item.revision > state.revision || item.epoch > state.epoch) fail("Future pending draft");
        });
        if (state.operation !== null) {
            var op = state.operation; str(op.token, "operation.token");
            if (["existing", "saveAs", "reload"].indexOf(op.kind) < 0 || ["protecting", "writing", "reading"].indexOf(op.phase) < 0) fail("Invalid operation");
            if ((op.phase === "reading" && op.kind !== "reload") || (op.phase === "writing" && op.kind === "reload")) fail("Invalid operation phase");
            var snap = op.snapshot;
            if (!snap || snap.id !== state.id || snap.sessionID !== state.sessionID || typeof snap.text !== "string") fail("Invalid operation snapshot");
            integer(snap.revision, 0, "snapshot revision"); if (snap.revision > state.revision) fail("Future snapshot");
            name(snap.name); if (FORMATS.indexOf(snap.format) < 0) fail("snapshot format"); target(snap.target);
            if (LINE_ENDINGS.indexOf(snap.lineEnding) < 0) fail("snapshot lineEnding");
            if (op.kind !== "saveAs" && !snap.target) fail("Existing operation has no target");
            if (op.kind === "saveAs") name(op.name);
        }
    }
    function reduce(inputState, event) {
        json(inputState); json(event); validateState(inputState);
        if (!event || typeof event.type !== "string") fail("event.type");
        var state = copy(inputState), effects = [], op, index, item;
        var callbacks = ["EDIT", "DRAFT_OK", "DRAFT_FAILED", "WRITE_OK", "WRITE_FAILED", "CANCEL", "REMOTE_OBSERVED", "USER_ACCEPT_TARGET", "RECONCILE_OK", "CONFIRM_RETRY", "READ_OK", "READ_FAILED","DELETE_EVIDENCE","RESTORE_EVIDENCE","INVALIDATE_REMOTE"];
        if (callbacks.indexOf(event.type) >= 0 && event.sessionID !== state.sessionID) return {state: state, effects: effects};
        switch (event.type) {
        case "EDIT":
            if (typeof event.text !== "string" || typeof event.isComposing !== "boolean") fail("EDIT payload");
            if (event.text !== state.text) { integer(state.revision + 1, 0, "revision overflow"); state.revision += 1; state.text = event.text; }
            state.isComposing = event.isComposing; break;
        case "PROTECT":
            if (useToken(state, event.token)) persist(state, event.token, "protect", effects);
            break;
        case "RELOAD":
            if (state.operation || state.pendingEvidenceDeletion || state.pendingEvidenceRestore || state.isComposing || !state.target || !useToken(state, event.token)) break;
            state.operation = {token: event.token, kind: "reload", phase: "protecting", snapshot: snapshot(state)};
            state.draftError = null; state.fileError = null; state.fileErrorCode = null;
            persist(state, event.token, "reload", effects); break;
        case "SAVE":
        case "AUTO_SAVE":
        case "SAVE_AS":
            if (state.operation || state.pendingEvidenceDeletion || state.pendingEvidenceRestore || state.isComposing) break;
            if (event.type !== "SAVE_AS" && (!state.target || state.conflict || state.uncertain)) break;
            if (event.type === "AUTO_SAVE" && (!state.remoteValidated || state.acceptedRevision === state.revision)) break;
            var proposedName = event.name === undefined ? "無題.txt" : event.name;
            if (event.type === "SAVE_AS" && !validName(proposedName)) {
                state.fileError = "ファイル名を確認してください。"; state.fileErrorCode = "invalidName"; break;
            }
            if (event.type === "SAVE_AS" && state.uncertain && proposedName === (state.unknownOperation.kind === "saveAs" ? state.unknownOperation.name : state.unknownOperation.snapshot.target.name)) break;
            if (!useToken(state, event.token)) break;
            op = {token: event.token, kind: event.type === "SAVE_AS" ? "saveAs" : "existing", phase: "protecting", snapshot: snapshot(state)};
            if (op.kind === "saveAs") op.name = proposedName;
            state.operation = op; state.draftError = null; state.fileError = null; state.fileErrorCode = null;
            persist(state, event.token, "save", effects); break;
        case "DRAFT_OK":
            index = pendingIndex(state, event.token); if (index < 0) break;
            item = state.pendingDrafts[index];
            if (event.revision !== item.revision || event.epoch !== item.epoch) break;
            state.pendingDrafts.splice(index, 1);
            state.protectedRevision = Math.max(state.protectedRevision, item.revision);
            if (item.epoch === state.epoch) state.draftError = null;
            if(item.role==="evidenceDelete" && state.pendingEvidenceDeletion && item.deletionToken===state.pendingEvidenceDeletion.token) {
                var deletedIDs=state.pendingEvidenceDeletion.ids;
                state.retainedEvidence=state.retainedEvidence.filter(function(value){return deletedIDs.indexOf(historyID(state,value))<0;});
                state.pendingEvidenceDeletion=null;
            }
            if(item.role==="evidenceRestore" && state.pendingEvidenceRestore && event.token===state.pendingEvidenceRestore.token) {
                var restoreReady=state.pendingEvidenceRestore;state.pendingEvidenceRestore=null;
                if(!state.isComposing && state.revision===restoreReady.revision && state.text===restoreReady.expectedText) effects.push({type:"RESTORE_READY",token:restoreReady.token,sessionID:state.sessionID,
                    historyID:restoreReady.historyID,source:restoreReady.source,text:restoreReady.text,expectedText:restoreReady.expectedText,revision:restoreReady.revision});
            }
            op = state.operation;
            if (item.role === "save" && op && op.token === event.token && op.phase === "protecting") {
                op.phase = "writing";
                var effect = {type: "WRITE", token: op.token, sessionID: state.sessionID, kind: op.kind, snapshot: copy(op.snapshot)};
                if (op.kind === "saveAs") effect.name = op.name;
                effects.push(effect);
            }
            if (item.role === "reload" && op && op.token === event.token && op.phase === "protecting") {
                op.phase = "reading";
                var readSnapshot = copy(op.snapshot);
                readSnapshot.baselineText = op.snapshot.target.baseText === undefined ? null : op.snapshot.target.baseText;
                effects.push({type: "READ", token: op.token, sessionID: state.sessionID, snapshot: readSnapshot});
            }
            break;
        case "DRAFT_FAILED":
            index = pendingIndex(state, event.token); if (index < 0) break;
            if (typeof event.message !== "string") fail("DRAFT_FAILED message");
            item = state.pendingDrafts[index]; state.pendingDrafts.splice(index, 1);
            if (item.epoch === state.epoch || (state.operation && state.operation.token === event.token)) state.draftError = event.message;
            if ((item.role === "save" || item.role === "reload") && state.operation && state.operation.token === event.token) state.operation = null;
            if(item.role==="evidenceDelete" && state.pendingEvidenceDeletion && !state.pendingDrafts.some(function(pending){return pending.role==="evidenceDelete" && pending.deletionToken===item.deletionToken;})) state.pendingEvidenceDeletion=null;
            if(item.role==="evidenceRestore" && state.pendingEvidenceRestore && state.pendingEvidenceRestore.token===event.token) state.pendingEvidenceRestore=null;
            break;
        case "DELETE_EVIDENCE":
            if(event.confirmed!==true || event.expectedEpoch!==state.epoch || deleteBlock(state)!==null) break;
            if(!Array.isArray(event.ids) || !event.ids.length || event.ids.some(function(id,index){return typeof id!=="string" || event.ids.indexOf(id)!==index || !state.retainedEvidence.some(function(value){return historyID(state,value)===id;});})) fail("DELETE_EVIDENCE ids");
            if(!useToken(state,event.token)) break;
            state.pendingEvidenceDeletion={token:event.token,ids:copy(event.ids)};
            persist(state,event.token,"evidenceDelete",effects);break;
        case "RESTORE_EVIDENCE":
            if(event.confirmed!==true || event.expectedEpoch!==state.epoch || state.operation || state.pendingEvidenceDeletion || state.pendingEvidenceRestore || state.isComposing || state.uncertain || state.pendingDrafts.length || state.draftError) break;
            if(!Array.isArray(event.ids) || event.ids.length!==1 || ["base","local","remote"].indexOf(event.source)<0) fail("RESTORE_EVIDENCE payload");
            var restoredEvidence=evidenceFor(state,event.ids[0]);
            if(!restoredEvidence) break;
            var restoredText=event.source==="base"?restoredEvidence.baseText:event.source==="local"?restoredEvidence.localText:restoredEvidence.text;
            if(restoredText===null || !useToken(state,event.token)) break;
            state.pendingEvidenceRestore={token:event.token,historyID:event.ids[0],source:event.source,text:restoredText,expectedText:state.text,revision:state.revision};
            persist(state,event.token,"evidenceRestore",effects);break;
        case "INVALIDATE_REMOTE":
            if(state.target && event.identity===state.target.identity){state.remoteValidated=false;state.conflict=true;}
            break;
        case "WRITE_OK":
            op = state.operation;
            if (!op || op.phase !== "writing" || event.token !== op.token || event.revision !== op.snapshot.revision) break;
            var acceptedTarget = target(event.target);
            if (!acceptedTarget) fail("WRITE_OK target");
            if (op.kind === "existing" && acceptedTarget.identity !== op.snapshot.target.identity) break;
            if (op.kind === "saveAs" && acceptedTarget.name !== op.name) break;
            retainCandidate(state);
            state.target = acceptedTarget; state.name = acceptedTarget.name; state.acceptedRevision = event.revision;
            state.remoteValidated = true; state.remoteObservation = null;
            state.remoteCandidate = null;
            state.uncertain = false; state.unknownOperation = null;
            state.operation = null; state.fileError = null; state.fileErrorCode = null; state.conflict = false;
            var metadataToken = event.token + "#metadata@" + (state.epoch + 1);
            if (!useToken(state, metadataToken)) fail("Metadata token collision");
            persist(state, metadataToken, "metadata", effects); break;
        case "WRITE_FAILED":
            op = state.operation; if (!op || op.phase !== "writing" || event.token !== op.token) break;
            if (typeof event.message !== "string" || typeof event.code !== "string") fail("WRITE_FAILED payload");
            state.operation = null;
            state.fileError = event.message; state.fileErrorCode = event.code;
            state.conflict = event.code === "conflict";
            if (event.code === "unknownOutcome") {
                state.uncertain = true; state.unknownOperation = copy(op); state.remoteValidated = false;
                var unknownToken = event.token + "#unknown@" + (state.epoch + 1);
                if (!useToken(state, unknownToken)) fail("Unknown token collision");
                persist(state, unknownToken, "metadata", effects);
            } else {
                var failedToken = event.token + "#failed@" + (state.epoch + 1);
                if (!useToken(state,failedToken)) fail("Failed metadata token collision");
                persist(state,failedToken,"metadata",effects);
            }
            break;
        case "REMOTE_OBSERVED":
            if(event.comparisonBase!==undefined && typeof event.comparisonBase!=="string") fail("REMOTE_OBSERVED comparisonBase");
            var observed = target(event.target);
            if (!state.target || !observed || observed.identity !== state.target.identity) break;
            state.remoteObservation = observed;
            var sameBaseline = observed.baseline.sha256 === state.target.baseline.sha256 && observed.baseline.byteCount === state.target.baseline.byteCount;
            state.remoteValidated = sameBaseline;
            if (!sameBaseline || event.comparisonBase!==undefined) {
                state.conflict = true;
                if (observed.baseText !== undefined) {
                    var observationToken = "#observation@" + (state.epoch + 1);
                    if (!useToken(state,observationToken)) fail("Observation token collision");
                    retainCandidate(state);
                    state.remoteCandidate = {token:observationToken,text:observed.baseText,format:observed.format === undefined ? state.format : observed.format,target:observed,
                        observedRevision:state.revision,snapshotRevision:state.revision,localText:state.text,
                        baseText:event.comparisonBase===undefined?(state.target.baseText === undefined ? null : state.target.baseText):event.comparisonBase};
                    persist(state,observationToken,"metadata",effects);
                }
            }
            break;
        case "READ_OK":
            op = state.operation;
            if (!op || op.kind !== "reload" || op.phase !== "reading" || event.token !== op.token) break;
            var readTarget = target(event.target);
            if (!readTarget || readTarget.identity !== op.snapshot.target.identity) break;
            if (typeof event.text !== "string" || FORMATS.indexOf(event.format) < 0) fail("READ_OK payload");
            retainCandidate(state);
            state.remoteCandidate = {token: event.token, text: event.text, format: event.format, target: readTarget,
                observedRevision: state.revision, snapshotRevision: op.snapshot.revision, localText: state.text,
                baseText: op.snapshot.target.baseText === undefined ? null : op.snapshot.target.baseText};
            state.remoteObservation = readTarget;
            state.remoteValidated = readTarget.baseline.sha256 === state.target.baseline.sha256 && readTarget.baseline.byteCount === state.target.baseline.byteCount;
            if (!state.remoteValidated) state.conflict = true;
            state.operation = null; state.fileError = null; state.fileErrorCode = null;
            var readMetadataToken = event.token + "#read@" + (state.epoch + 1);
            if (!useToken(state,readMetadataToken)) fail("Read metadata token collision");
            persist(state,readMetadataToken,"metadata",effects); break;
        case "READ_FAILED":
            op = state.operation;
            if (!op || op.kind !== "reload" || op.phase !== "reading" || event.token !== op.token) break;
            if (typeof event.message !== "string" || typeof event.code !== "string") fail("READ_FAILED payload");
            state.fileError = event.message; state.fileErrorCode = event.code; state.operation = null; break;
        case "USER_ACCEPT_TARGET":
            var selected = target(event.target);
            if (state.operation || state.pendingEvidenceDeletion || state.pendingEvidenceRestore || state.isComposing || state.uncertain || !state.target || !selected || selected.identity !== state.target.identity) break;
            if (!useToken(state, event.token)) break;
            if (event.remoteTextAccepted !== undefined && typeof event.remoteTextAccepted !== "boolean") fail("remoteTextAccepted");
            retainCandidate(state);
            state.target = selected; state.name = selected.name; state.acceptedRevision = null; state.conflict = false; state.remoteValidated = true; state.remoteObservation = null;
            state.remoteCandidate = null;
            if (selected.format !== undefined) state.format = selected.format;
            if (event.remoteTextAccepted === true && selected.baseText === state.text) { state.acceptedRevision = state.revision; state.lineEnding = "preserve"; }
            persist(state, event.token, "metadata", effects); break;
        case "RECONCILE_OK":
            var unknown = state.unknownOperation;
            var reconciled = target(event.target);
            if (!state.uncertain || state.operation || !unknown || unknown.token !== event.unknownToken || event.revision !== unknown.snapshot.revision || event.applied !== true || !reconciled) break;
            if (unknown.kind === "existing" && reconciled.identity !== unknown.snapshot.target.identity) break;
            if (unknown.kind === "saveAs" && reconciled.name !== unknown.name) break;
            if (!useToken(state, event.token)) break;
            retainCandidate(state);
            state.target = reconciled; state.name = reconciled.name; state.acceptedRevision = event.revision;
            state.uncertain = false; state.unknownOperation = null; state.remoteValidated = true; state.conflict = false;
            state.fileError = null; state.fileErrorCode = null; state.remoteObservation = null;
            state.remoteCandidate = null;
            persist(state, event.token, "metadata", effects); break;
        case "CONFIRM_RETRY":
            var retryUnknown = state.unknownOperation, retryTarget = target(event.target);
            if (!state.uncertain || state.operation || !retryUnknown || retryUnknown.kind !== "existing" || retryUnknown.token !== event.unknownToken || !retryTarget) break;
            var original = retryUnknown.snapshot.target;
            if (retryTarget.identity !== original.identity || retryTarget.baseline.sha256 !== original.baseline.sha256 || retryTarget.baseline.byteCount !== original.baseline.byteCount) break;
            if (!useToken(state, event.token)) break;
            state.target = retryTarget; state.uncertain = false; state.unknownOperation = null; state.remoteValidated = false;
            state.fileError = null; state.fileErrorCode = null;
            persist(state, event.token, "metadata", effects); break;
        case "CANCEL":
            // A disk proposal may already be durable; only its ACK/failure resolves history work.
            if ((state.pendingEvidenceDeletion && state.pendingEvidenceDeletion.token === event.token) || (state.pendingEvidenceRestore && state.pendingEvidenceRestore.token === event.token)) break;
            op = state.operation;
            if (op && op.token === event.token) {
                state.operation = null;
                if (op.phase === "writing") {
                    state.uncertain = true; state.unknownOperation = copy(op); state.remoteValidated = false;
                    state.fileErrorCode = "unknownOutcome"; state.fileError = "取消後の書込み結果を確認してください。";
                }
                if (op.kind !== "reload") {
                    var cancelToken = event.token + "#cancel@" + (state.epoch + 1);
                    if (!useToken(state, cancelToken)) fail("Cancel token collision");
                    persist(state, cancelToken, "metadata", effects);
                }
            }
            state.pendingDrafts = state.pendingDrafts.filter(function (draft) { return draft.token !== event.token; });
            break;
        default: fail("Unknown event type: " + event.type);
        }
        validateState(state); return {state: state, effects: effects};
    }
    root.IyoCore = Object.freeze({create: create, restore: restore, reduce: reduce,historyList:historyList,evidenceFor:evidenceFor});
})(globalThis);
