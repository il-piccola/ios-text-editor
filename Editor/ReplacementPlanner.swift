import Foundation
import JavaScriptCore

enum EditorPlannerError: LocalizedError {
    case unavailable
    case rejected(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "置換プランナーを読み込めません。ReplacementPlan.js の同梱を確認してください。"
        case .rejected(let message): return message
        }
    }
}

/// Fixed production ceilings; smaller injected limits support admission tests.
/// No UI automatically raises them after a failure.
struct ReplacementPlannerLimits {
    var maxInputUTF16 = 4 * 1024 * 1024
    var maxOutputUTF16 = 4 * 1024 * 1024
    var maxInputUTF8UpperBound = 20 * 1024 * 1024
    var maxOutputUTF8UpperBound = 20 * 1024 * 1024
    var maxMatches = 100_000
    var memoryBudgetBytes = 128 * 1024 * 1024
    var dictionary: [String: Int] {
        ["maxInputUTF16": maxInputUTF16, "maxOutputUTF16": maxOutputUTF16,
         "maxInputUTF8UpperBound": maxInputUTF8UpperBound, "maxOutputUTF8UpperBound": maxOutputUTF8UpperBound,
         "maxMatches": maxMatches, "memoryBudgetBytes": memoryBudgetBytes]
    }
}

/// Production uses the same authored JS planner exercised by Node tests.
/// Foundation supplies grapheme boundaries; JavaScript never guesses them.
@MainActor
final class ReplacementPlanner {
    private let context: JSContext
    private let api: JSValue
    private let limits: ReplacementPlannerLimits

    init(bundle: Bundle = .main, limits: ReplacementPlannerLimits = .init()) throws {
        guard let context = JSContext(),
              let url = bundle.url(forResource: "ReplacementPlan", withExtension: "js")
                ?? bundle.url(forResource: "ReplacementPlan", withExtension: "js", subdirectory: "Resources")
        else { throw EditorPlannerError.unavailable }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
        guard context.exception == nil,
              let api = context.objectForKeyedSubscript("IyoReplacement"), !api.isUndefined else {
            throw EditorPlannerError.unavailable
        }
        self.context = context
        self.api = api
        self.limits = limits
    }

    static func boundaries(_ text: String) -> [Int] {
        let string = text as NSString
        var result = [0], offset = 0
        while offset < string.length {
            let range = string.rangeOfComposedCharacterSequence(at: offset)
            offset = NSMaxRange(range)
            result.append(offset)
        }
        return result
    }

    func preview(text: String, selection: NSRange, request: EditorReplacementRequest) throws -> EditorReplacementPreview {
        // Reject before Foundation creates a full boundary array or text crosses into JS.
        let inputLengths = [text.utf16.count, request.query.utf16.count, request.replacement.utf16.count]
        guard inputLengths.allSatisfy({ $0 <= limits.maxInputUTF16 && $0 <= 4 * 1024 * 1024 }) else {
            throw EditorPlannerError.rejected("置換する文字列が上限を超えています。本文は変更していません。")
        }
        let inputUnits = inputLengths.reduce(0, +)
        guard inputUnits * 3 <= limits.maxInputUTF8UpperBound,
              8 * 1024 * 1024 + inputUnits * 76 <= limits.memoryBudgetBytes else {
            throw EditorPlannerError.rejected("入力または置換に必要な推定メモリが上限を超えています。本文は変更していません。")
        }
        let input: [String: Any] = ["text": text, "query": request.query, "replacement": request.replacement,
                                    "limits": limits.dictionary, "includeMatches": false]
        let _: Admission = try invoke("preflight", input: input)
        let originalSelection = EditorUTF16Range(location: selection.location, length: selection.length)
        let plan: Plan = try invoke("plan", input: [
            "text": text, "query": request.query, "replacement": request.replacement,
            "scope": request.scope.rawValue, "selection": ["location": selection.location, "length": selection.length],
            "boundaries": Self.boundaries(text), "limits": limits.dictionary, "includeMatches": false
        ])
        let selection = try normalizedSelection(text: plan.candidate, selection: plan.proposedSelection)
        return EditorReplacementPreview(id: UUID(), sessionID: request.sessionID, originalText: text,
            originalSelection: originalSelection, candidate: plan.candidate, selection: selection,
            count: plan.count, isNoOp: plan.isNoOp)
    }

    func normalizedSelection(text: String, selection: EditorUTF16Range) throws -> EditorUTF16Range {
        let length = text.utf16.count
        guard length <= limits.maxOutputUTF16, length <= 4 * 1024 * 1024,
              length * 3 <= limits.maxOutputUTF8UpperBound,
              8 * 1024 * 1024 + length * 76 <= limits.memoryBudgetBytes else {
            throw EditorPlannerError.rejected("候補の文字数または推定メモリが上限を超えています。本文は変更していません。")
        }
        return try invoke("finalizeSelection", input: ["text": text, "boundaries": Self.boundaries(text),
            "selection": ["location": selection.location, "length": selection.length], "limits": limits.dictionary])
    }

    func admitApplication(current: String, candidate: String) throws {
        let input = current.utf16.count, output = candidate.utf16.count
        guard input <= limits.maxInputUTF16, input <= 4 * 1024 * 1024,
              output <= limits.maxOutputUTF16, output <= 4 * 1024 * 1024,
              input * 3 <= limits.maxInputUTF8UpperBound, output * 3 <= limits.maxOutputUTF8UpperBound,
              8 * 1024 * 1024 + (input + output) * 76 <= limits.memoryBudgetBytes else {
            throw EditorPlannerError.rejected("現在の本文・候補・Undo に必要な推定メモリが上限を超えています。本文は変更していません。")
        }
        let _: ApplicationAdmission = try invoke("applicationPreflight", input: ["current": current,
            "candidate": candidate, "limits": limits.dictionary])
    }

    private func invoke<T: Decodable>(_ function: String, input: [String: Any]) throws -> T {
        context.exception = nil
        let result = api.forProperty(function)?.call(withArguments: [input])
        if let exception = context.exception {
            throw EditorPlannerError.rejected(exception.toString() ?? "置換計画を作成できません。")
        }
        guard let value = result?.toObject(), JSONSerialization.isValidJSONObject(value) else {
            throw EditorPlannerError.unavailable
        }
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private struct Plan: Decodable {
        let candidate: String
        let count: Int
        let proposedSelection: EditorUTF16Range
        let isNoOp: Bool
    }
    private struct Admission: Decodable { let estimatedInputPeakBytes: Int }
    private struct ApplicationAdmission: Decodable { let estimatedPeakBytes: Int }
}
