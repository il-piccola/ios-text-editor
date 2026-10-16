import Foundation
import JavaScriptCore
import CoreFoundation

enum CoreBridgeError: Error, LocalizedError {
    case missingResource, invalidResult, script(String)
    var errorDescription: String? {
        switch self {
        case .missingResource: return "本番状態管理ファイル SessionCore.js がアプリに含まれていません。"
        case .invalidResult: return "状態管理の返答を確認できません。処理を止めました。"
        case .script(let text): return "状態管理を実行できません: " + text
        }
    }
}

/// Executes the same bundled JS reducer tested by Node. No state transitions are reproduced in Swift.
@MainActor
final class SessionCoreBridge {
    private let context: JSContext
    private var lastException: String?

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "SessionCore", withExtension: "js"),
              let context = JSContext() else { throw CoreBridgeError.missingResource }
        self.context = context
        context.exceptionHandler = { [weak self] _, value in self?.lastException = value?.toString() ?? "JavaScript exception" }
        let source = try String(contentsOf: url, encoding: .utf8)
        context.evaluateScript(source, withSourceURL: url)
        if let error = lastException { throw CoreBridgeError.script(error) }
        guard let mergeURL = bundle.url(forResource: "MergeCore", withExtension: "js") else { throw CoreBridgeError.missingResource }
        context.evaluateScript(try String(contentsOf: mergeURL, encoding: .utf8), withSourceURL: mergeURL)
        if let error = lastException { throw CoreBridgeError.script(error) }
        guard let capacityURL = bundle.url(forResource: "CapacityPolicy", withExtension: "js") else { throw CoreBridgeError.missingResource }
        context.evaluateScript(try String(contentsOf: capacityURL, encoding: .utf8), withSourceURL: capacityURL)
        if let error = lastException { throw CoreBridgeError.script(error) }
        // All crossings are JSON strings. This avoids NSNumber Bool/Int coercion and JS undefined ambiguity.
        context.evaluateScript("""
        function __iyoInvokeJSON(method, json) {
          try {
            var input = JSON.parse(json), value;
            if (method === 'create') value = IyoCore.create(input);
            else if (method === 'restore') value = IyoCore.restore(input);
            else if (method === 'reduce') value = IyoCore.reduce(input.state, input.event);
            else if (method === 'compare') value = IyoMerge.compare(input);
            else if (method === 'resolve') value = {text:IyoMerge.resolve(input.result,input.choices)};
            else if (method === 'capacityPlan') value = IyoCapacity.plan(input);
            else if (method === 'historyList') value = {entries:IyoCore.historyList(input.state)};
            else if (method === 'evidenceFor') value = IyoCore.evidenceFor(input.state,input.id);
            else throw new Error('Unknown bridge method');
            return JSON.stringify({ok:true,value:value});
          } catch (error) { return JSON.stringify({ok:false,error:String(error)}); }
        }
        """)
        if let error = lastException { throw CoreBridgeError.script(error) }
    }

    func invoke(_ method: String, _ input: [String: Any]) throws -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(input) else { throw CoreBridgeError.invalidResult }
        let bytes = try JSONSerialization.data(withJSONObject: input)
        guard let json = String(data: bytes, encoding: .utf8) else { throw CoreBridgeError.invalidResult }
        lastException = nil
        context.exception = nil
        guard let function = context.objectForKeyedSubscript("__iyoInvokeJSON"),
              let reply = function.call(withArguments: [method, json]),
              !reply.isUndefined, !reply.isNull, reply.isString, let response = reply.toString()?.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let successNumber = envelope["ok"] as? NSNumber,
              CFGetTypeID(successNumber) == CFBooleanGetTypeID() else { throw CoreBridgeError.invalidResult }
        if let error = lastException { throw CoreBridgeError.script(error) }
        guard successNumber.boolValue else { throw CoreBridgeError.script(envelope["error"] as? String ?? "Unknown exception") }
        guard let value = envelope["value"] as? [String: Any] else { throw CoreBridgeError.invalidResult }
        return value
    }

    static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        else { throw CoreBridgeError.invalidResult }
        return object
    }

    static func decode<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: dictionary))
    }
}

struct CoreStateCodable: Decodable {
    let id: UUID
    let sessionID: UUID
    let name: String
    let text: String
    let format: String
    let revision: Int
    let epoch: Int
    let protectedRevision: Int
    let acceptedRevision: Int?
    let target: CoreTarget?
    let isComposing: Bool
    let operation: CoreOperation?
    let draftError: String?
    let fileError: String?
    let fileErrorCode: String?
    let conflict: Bool
    let cloudStatus: String
    let lineEnding: String
    let uncertain: Bool
    let remoteValidated: Bool
    let unknownOperation: CoreOperation?
}

struct CoreOperation: Codable, Equatable, Sendable {
    let token: String
    let kind: String
    let phase: String
    let snapshot: CoreWriteSnapshot
    let name: String?
}
