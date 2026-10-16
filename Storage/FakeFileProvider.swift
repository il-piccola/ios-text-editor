import Foundation

enum FakeScenario: String, CaseIterable, Identifiable, Sendable {
    case normal, delayed, accessRevoked, conflict, interrupted, writeFailure, moved, deleted, unknownOutcome, offline
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return "通常"
        case .delayed: return "保存に時間がかかる"
        case .accessRevoked: return "アクセス取消"
        case .conflict: return "別端末の変更"
        case .interrupted: return "通信中断"
        case .writeFailure: return "書き込み失敗"
        case .moved: return "外部で名前変更"
        case .deleted: return "外部で削除"
        case .unknownOutcome: return "書き込み後に応答なし"
        case .offline: return "オフライン（検証用）"
        }
    }
}

/// App-private fake storage. This adapter never contacts Files, Drive, or a network.
actor FakeFileProvider: ProviderAdapter {
    private struct File: Codable {
        let identity: String
        var name: String
        var text: String
        let format: String
        var baseline: CoreBaseline
        var lastWriteKey: String? = nil
    }
    private let url: URL
    private var files: [File]
    private var scenario: FakeScenario = .normal
    static let location = "検証用の偽保存先（端末内）"

    init(directory: URL? = nil) throws {
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                           appropriateFor: nil, create: true).appendingPathComponent("IyoFakeProvider", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("files.json")
        files = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([File].self, from: Data(contentsOf: url)) : []
        var identities = Set<String>()
        var names = Set<String>()
        for file in files {
            guard UUID(uuidString: file.identity) != nil, identities.insert(file.identity).inserted,
                  names.insert(file.name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  let format = TextFileFormat(rawValue: file.format),
                  try CoreBaseline.make(format.encode(file.text)) == file.baseline else { throw StorageError.invalidDraft }
        }
    }

    func setScenario(_ value: FakeScenario) { scenario = value }

    func read(identity: String) async throws -> CoreTarget {
        if scenario == .offline { throw ProviderFailure(code: "offline", message: "検証用オフライン: 保存先を読み込めません。端末下書きは保持します。") }
        if scenario == .interrupted { throw ProviderFailure(code: "interrupted", message: "検証用通信中断: 保存先の読み込みが中断しました。端末下書きは保持します。") }
        if scenario == .delayed { try await Task.sleep(nanoseconds: 3_000_000_000) }
        try Task.checkCancellation()
        if scenario == .accessRevoked { throw ProviderFailure(code: "permission", message: "検証: 保存先のアクセス権が失効しています。") }
        try reload()
        guard let index = files.firstIndex(where: { $0.identity == identity }) else {
            throw ProviderFailure(code: "deleted", message: "保存先のファイルが見つかりません。端末下書きは残っています。")
        }
        if scenario == .deleted {
            var changed = files; changed.remove(at: index); try commit(changed); scenario = .normal
            throw ProviderFailure(code: "deleted", message: "検証: 外部でファイルが削除されました。")
        }
        if scenario == .moved {
            var changed = files; changed[index].name = "移動-" + changed[index].name
            try commit(changed); scenario = .normal
        } else if scenario == .conflict {
            var changed = files; changed[index].text += "\n別端末で追記した内容（検証）"
            guard let format = TextFileFormat(rawValue: changed[index].format) else { throw StorageError.invalidDraft }
            changed[index].baseline = .make(try format.encode(changed[index].text))
            changed[index].lastWriteKey = nil
            try commit(changed); scenario = .normal
        }
        return target(files[index])
    }

    func find(name: String) async throws -> CoreTarget? {
        if scenario == .offline { throw ProviderFailure(code: "offline", message: "検証用オフライン: 書き込み結果を照合できません。") }
        if scenario == .interrupted { throw ProviderFailure(code: "interrupted", message: "検証用通信中断: 書き込み結果を照合できません。") }
        if scenario == .accessRevoked { throw ProviderFailure(code: "permission", message: "保存先のアクセス権が失効しています。") }
        try reload()
        return files.first(where: { $0.name == name }).map { target($0) }
    }

    func sample() throws -> (text: String, format: String, target: CoreTarget) {
        try reload()
        if let file = files.first { return (file.text, file.format, target(file)) }
        let text = "ここは検証用の保存先です。\nGoogle ドライブには接続していません。\n"
        let bytes = try TextFileFormat.utf8.encode(text)
        let file = File(identity: UUID().uuidString, name: "練習用.txt", text: text, format: "utf8", baseline: .make(bytes))
        try commit(files + [file])
        return (file.text, file.format, target(file))
    }

    func write(kind: String, snapshot: CoreWriteSnapshot, name: String?) async throws -> CoreTarget {
        let selectedScenario = scenario
        if selectedScenario == .delayed { try await Task.sleep(nanoseconds: 3_000_000_000) }
        try Task.checkCancellation()
        switch selectedScenario {
        case .offline: throw ProviderFailure(code: "offline", message: "検証用オフライン: 保存先に書き込めません。端末下書きは保持します。")
        case .accessRevoked: throw ProviderFailure(code: "permission", message: "検証: 保存先のアクセスが取り消されました。")
        case .interrupted: throw ProviderFailure(code: "interrupted", message: "検証: 通信が途中で中断しました。")
        case .writeFailure: throw ProviderFailure(code: "write", message: "検証: 保存先が書き込みを受け付けませんでした。")
        default: break
        }
        let bytes = try snapshot.encodedBytes()
        try reload()
        // App-private idempotency mock, not a remote API guarantee.
        let writeKey = snapshot.sessionID.uuidString + ":" + String(snapshot.revision) + ":" + CoreBaseline.make(bytes).sha256 + ":" + kind + ":" + (name ?? snapshot.name)
        if let prior = files.first(where: { $0.lastWriteKey == writeKey }) { return target(prior) }
        if kind == "saveAs" {
            let requested = try SaveName.validate(name ?? snapshot.name)
            guard !files.contains(where: { $0.name.precomposedStringWithCanonicalMapping.lowercased() == requested.precomposedStringWithCanonicalMapping.lowercased() })
            else { throw ProviderFailure(code: "nameCollision", message: "同じ名前のファイルがあります。別の名前を入力してください。") }
            let file = File(identity: UUID().uuidString, name: requested, text: snapshot.outputText,
                            format: snapshot.format, baseline: .make(bytes), lastWriteKey: writeKey)
            try commit(files + [file])
            if selectedScenario == .unknownOutcome { throw ProviderFailure(code: "unknownOutcome", message: "書き込み後に応答が途切れました。結果を再確認するまで同じファイルへ再保存しません。") }
            return target(file)
        }
        guard kind == "existing", let expected = snapshot.target,
              UUID(uuidString: expected.identity) != nil,
              let index = files.firstIndex(where: { $0.identity == expected.identity })
        else { throw ProviderFailure(code: "permission", message: "検証用の保存先が見つかりません。選び直してください。") }
        if selectedScenario == .deleted {
            var changed = files; changed.remove(at: index); try commit(changed); scenario = .normal
            throw ProviderFailure(code: "deleted", message: "検証: 保存先のファイルが削除されました。")
        }
        if selectedScenario == .moved {
            var changed = files; changed[index].name = "移動-" + changed[index].name; try commit(changed); scenario = .normal
        }
        if selectedScenario == .conflict {
            var changed = files
            changed[index].text += "\n別端末で追記した内容（検証）"
            guard let format = TextFileFormat(rawValue: changed[index].format) else { throw StorageError.invalidDraft }
            changed[index].baseline = .make(try format.encode(changed[index].text))
            changed[index].lastWriteKey = nil
            try commit(changed)
            scenario = .normal
        }
        // Identity plus complete bytes hash is mandatory. Failed reads/validation never fall through to write.
        guard files[index].baseline == expected.baseline else {
            throw ProviderFailure(code: "conflict", message: "保存先に別の変更があります。下書きは残っています。別のファイルに保存してください。")
        }
        var changed = files
        changed[index].text = snapshot.outputText
        let file = File(identity: files[index].identity, name: files[index].name, text: snapshot.outputText,
                        format: snapshot.format, baseline: .make(bytes), lastWriteKey: writeKey)
        changed[index] = file
        try commit(changed)
        if selectedScenario == .unknownOutcome { throw ProviderFailure(code: "unknownOutcome", message: "書き込み後に応答が途切れました。結果を再確認してください。") }
        return target(file)
    }

    func nameIsAvailable(_ name: String) throws -> Bool {
        let requested = try SaveName.validate(name)
        try reload()
        return !files.contains { $0.name.precomposedStringWithCanonicalMapping.lowercased() == requested.precomposedStringWithCanonicalMapping.lowercased() }
    }

    private func reload() throws {
        // Re-read the fake provider's disk state so another fake instance or damaged file is not silently overwritten.
        guard FileManager.default.fileExists(atPath: url.path) else {
            guard files.isEmpty else { throw ProviderFailure(code: "permission", message: "検証用の保存先が削除されました。") }
            return
        }
        let loaded = try JSONDecoder().decode([File].self, from: Data(contentsOf: url))
        var identities = Set<String>()
        var names = Set<String>()
        for file in loaded {
            guard UUID(uuidString: file.identity) != nil, identities.insert(file.identity).inserted,
                  names.insert(file.name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  let format = TextFileFormat(rawValue: file.format),
                  try CoreBaseline.make(format.encode(file.text)) == file.baseline else { throw StorageError.invalidDraft }
        }
        files = loaded
    }

    private func target(_ file: File) -> CoreTarget {
        CoreTarget(identity: file.identity, name: file.name, location: Self.location, baseline: file.baseline,
                   baseText: file.text, format: file.format, lineEnding: "preserve")
    }

    private func commit(_ updated: [File]) throws {
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        files = updated
    }
}
