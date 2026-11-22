import SwiftUI

@main
struct SelfStoreApp: App {
    @State private var store = StoreModel()
    @State private var openError: String?

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
    }
}
