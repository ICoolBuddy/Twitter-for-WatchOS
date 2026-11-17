import SwiftUI
import XKit

@main
struct PerchWatchApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Text("Perch")
                        .font(.title3.bold())
                    Text("Milestone 1 build")
                    Text("Ops: \(EndpointConfig.bundled.operations.count)")
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("Perch")
            }
        }
    }
}
