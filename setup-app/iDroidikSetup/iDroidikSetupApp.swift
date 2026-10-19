import SwiftUI

@main
struct iDroidikSetupApp: App {
    @StateObject private var state = SetupState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
    }
}
