import SwiftUI

@main
struct SelfStoreApp: App {
    @State private var store = StoreModel()
    @State private var openError: String?
    @State private var wasInBackground = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StoreView()
                .environment(store)
                .onOpenURL { url in
                    Task {
                        do { try await store.handle(openURL: url) }
                        catch { openError = error.localizedDescription }
                    }
                }
                .alert("Couldn't Add Mac", isPresented: .constant(openError != nil)) {
                    Button("OK") { openError = nil }
                } message: { Text(openError ?? "") }
        }
        .onChange(of: scenePhase) { _, phase in
            // Refresh every Mac when the app comes back to the foreground (launch is handled by StoreView's .task).
            switch phase {
            case .background: wasInBackground = true
            case .active where wasInBackground:
                wasInBackground = false
                Task { await store.refreshAll() }
            default: break
            }
        }
    }
}
