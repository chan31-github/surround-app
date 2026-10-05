import SwiftData
import SwiftUI

@main
struct SurroundApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-pivotGallery") {
                PivotGallery()
            } else {
                LibraryView()
            }
            #else
            LibraryView()
            #endif
        }
        .modelContainer(for: [SphereRecord.self, TripRecord.self])
    }
}
