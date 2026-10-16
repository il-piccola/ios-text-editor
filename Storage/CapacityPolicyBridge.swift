import Foundation
import JavaScriptCore

struct DraftCapacityConfiguration: Sendable {
    var budgetBytes: Int = 256 * 1024 * 1024
    var maxIncomingBytes: Int = 64 * 1024 * 1024
    var reserveBytes: Int = 128 * 1024 * 1024
}

struct DraftCapacityStatus: Codable, Sendable {
    let budgetBytes: Int
    let usedBytes: Int
    let remainingBytes: Int
    let availableBytes: Int?
    let reserveBytes: Int
    let maxIncomingBytes: Int
    let status: String
}

struct DraftCapacityPlan: Decodable {
    let allowed: Bool
    let reason: String?
    let replacementPeakBytes: Int
    let finalBytes: Int
    let requiredAdditionalBytes: Int
}

enum DraftCapacityError: Error, LocalizedError {
    case unavailable, denied(String), simulatedWriteFailure
    var errorDescription: String? {
        switch self {
        case .unavailable: return "下書きの保護容量を確認できません。原本は削除していません。"
        case .denied(let reason): return "下書きを保護する空き容量が不足しています（\(reason)）。原本は削除していません。"
        case .simulatedWriteFailure: return "検証用の下書き書込み失敗です。"
        }
    }
}

/// Confined to DraftStore's actor. The same arithmetic source runs in Node tests.
/// Native JavaScriptCore execution is pending Mac/iOS verification.
final class CapacityPolicyBridge {
    private let context: JSContext
    init() throws {
        guard let context = JSContext(),
              let url = Bundle.main.url(forResource: "CapacityPolicy", withExtension: "js") else {
            throw DraftCapacityError.unavailable
        }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        guard context.exception == nil else { throw DraftCapacityError.unavailable }
        context.evaluateScript("function iyoCapacityPlanJSON(raw) { return JSON.stringify(IyoCapacity.plan(JSON.parse(raw))); }")
        guard context.exception == nil else { throw DraftCapacityError.unavailable }
        self.context = context
    }

    func plan(incomingBytes: Int, previousBytes: Int, existingBytes: Int, availableBytes: Int?,
              configuration: DraftCapacityConfiguration) throws -> DraftCapacityPlan {
        let input: [String: Any] = ["incomingBytes": incomingBytes, "previousBytes": previousBytes,
            "existingBytes": existingBytes, "availableBytes": availableBytes.map { $0 as Any } ?? NSNull(),
            "budgetBytes": configuration.budgetBytes, "maxIncomingBytes": configuration.maxIncomingBytes,
            "reserveBytes": configuration.reserveBytes]
        let data = try JSONSerialization.data(withJSONObject: input)
        guard let raw = String(data: data, encoding: .utf8) else { throw DraftCapacityError.unavailable }
        context.exception = nil
        let result = context.objectForKeyedSubscript("iyoCapacityPlanJSON")?.call(withArguments: [raw])
        guard context.exception == nil, let json = result?.toString(), let output = json.data(using: .utf8) else {
            throw DraftCapacityError.unavailable
        }
        return try JSONDecoder().decode(DraftCapacityPlan.self, from: output)
    }
}
