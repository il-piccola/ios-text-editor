import SwiftUI

/// Prototype starts against an app-private fake provider. No Google account is used.
@main
struct IyoEditorApp: App {
    var body: some Scene {
        WindowGroup { StartupView() }
    }
}

@MainActor
private struct StartupView: View {
    @State private var session: SessionController?
    @State private var startupError: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let session {
                SessionRoot(session: session)
            } else if let startupError {
                VStack(alignment: .leading, spacing: 16) {
                    Text("エディタを開けませんでした").font(.headline)
                    Text(startupError).textSelection(.enabled)
                    Text("端末の下書きを削除せず、起動を停止しています。")
                        .foregroundStyle(.secondary)
                    Button("もう一度開く") {
                        self.startupError = nil
                        attempt += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
            } else {
                ProgressView("端末の下書きを確認中")
            }
        }
        .task(id: attempt) {
            guard session == nil else { return }
            do {
                let candidate = try SessionController()
                await candidate.start()
                guard !Task.isCancelled else { return }
                session = candidate
            } catch {
                startupError = error.localizedDescription
            }
        }
    }
}

@MainActor
private struct SessionRoot: View {
    @ObservedObject var session: SessionController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        EditorScreen(state: session.screenState, actions: session.screenActions)
            .sheet(isPresented: $session.showsFilesPicker) {
                FilesDocumentPicker(onPick: { session.pickedFilesURL($0) },
                                    onCancel: { session.showsFilesPicker = false })
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { session.protectNow() }
            }
    }
}
