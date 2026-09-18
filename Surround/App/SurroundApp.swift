import SwiftData
import SwiftUI

@main
struct SurroundApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryView()
        }
        .modelContainer(for: SphereRecord.self)
    }
}
