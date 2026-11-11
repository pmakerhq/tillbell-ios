import HotwireNative
import SwiftUI
import Tillbell

/// The smallest app that sells subscriptions through the Tillbell paywall: it registers the
/// component, which is all the native setup there is. Point `Navigator` at your Rails app to
/// show the paywall; the test target uses this app as its host to run StoreKitTest.
@main
struct TillbellExampleApp: App {
    init() {
        Hotwire.registerBridgeComponents([TillbellComponent.self])
    }

    var body: some Scene {
        WindowGroup {
            Text("Tillbell example")
        }
    }
}
