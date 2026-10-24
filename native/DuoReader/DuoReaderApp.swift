import SwiftUI

@main
struct DuoReaderApp: App {
    var body: some Scene {
        WindowGroup {
            ReaderWebView()
                .ignoresSafeArea()
        }
    }
}
