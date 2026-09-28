import SwiftUI
import Core
import Libmpv

@main
struct TubeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Tube · libmpv API \(mpv_client_api_version()) · \(Formatters.duration(3723))")
        }
    }
}
