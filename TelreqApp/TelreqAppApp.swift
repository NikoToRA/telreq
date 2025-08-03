import SwiftUI

@main
struct TelreqAppApp: App {
    @StateObject private var serviceContainer = ServiceContainer.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(serviceContainer)
                .task {
                    do {
                        try await serviceContainer.initializeServices()
                    } catch {
                        print("Failed to initialize services: \(error)")
                    }
                }
        }
    }
}