import SwiftUI
import CoreSpotlight

@main
struct DuoReaderApp: App {
    var body: some Scene {
        WindowGroup {
            ReaderWebView()
                .ignoresSafeArea()
                .onOpenURL { url in
                    NativeBridge.shared.importFile(url)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    NativeBridge.shared.openFromSpotlight(activity)
                }
        }
    }
}
