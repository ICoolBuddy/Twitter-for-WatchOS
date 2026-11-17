import SwiftUI
import XKit

@main
struct PerchApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    Section("Perch") {
                        Text("Milestone 1 build")
                        LabeledContent("Endpoints", value: EndpointConfig.bundled.updatedAt)
                    }
                }
                .navigationTitle("Perch")
            }
        }
    }
}
