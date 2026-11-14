#if canImport(HotwireNative) && canImport(UIKit)
import HotwireNative
import os
import StoreKit
import UIKit

/// The `tillbell` Hotwire Native bridge component: runs the App Store subscription purchase flow
/// for the Tillbell paywall of a Rails app.
///
/// Register it with Hotwire next to your other components:
///
/// ```swift
/// Hotwire.registerBridgeComponents([TillbellComponent.self])
/// ```
///
/// It answers the page's `products`, `purchase` and `restore` messages, always, including on
/// errors, and opens the App Store subscription management sheet on `manage`. It reports what
/// the App Store says and never grants access: the server verifies every purchase.
public final class TillbellComponent: BridgeComponent {
    /// The bridge component name the Tillbell paywall page talks to.
    override public nonisolated class var name: String { "tillbell" }

    /// Hosts of the pages allowed to start a purchase, e.g. `["example.com"]`, compared with
    /// the host of the page that sent the message. Messages from any other page (a link that
    /// left your site inside the app) get an `error` reply, and `manage` is ignored. Nil, the
    /// default, accepts every page the app shows. Set it at launch:
    ///
    /// ```swift
    /// TillbellComponent.allowedHosts = [rootURL.host!]
    /// ```
    ///
    /// It checks the page shown in the web view, not the frames inside it: Hotwire Native does
    /// not tell which frame sent a message, so keep third-party iframes off your paywall pages.
    /// Setting it also starts listening to App Store transactions, as `start()` does.
    @MainActor public static var allowedHosts: Set<String>? {
        get { TillbellStore.shared.allowedHosts }
        set { TillbellStore.shared.allowedHosts = newValue }
    }

    /// Starts listening to App Store transactions now rather than with the first paywall
    /// message, as Apple recommends: renewals and Ask to Buy approvals that arrive while the
    /// app runs are finished at once. Call it in `application(_:didFinishLaunchingWithOptions:)`.
    @MainActor public static func start() {
        _ = TillbellStore.shared
    }

    /// Handles a message from the paywall page.
    override public func onReceive(message: HotwireNative.Message) {
        if message.event == "manage" {
            guard TillbellStore.shared.isTrusted(jsonData: message.jsonData) else {
                let host = TillbellStore.shared.pageHost(jsonData: message.jsonData)
                logger.warning("Ignoring manage from \(host, privacy: .public), outside the allowed hosts")
                return
            }
            manageSubscriptions()
            return
        }
        // Replies to this exact message, not to the latest message with the same event. The
        // purchase goes on if the page goes away meanwhile: the reply is then dropped, the
        // transaction is still finished, and `restore` returns it.
        Task {
            guard let reply = await TillbellStore.shared.answer(event: message.event, jsonData: message.jsonData) else { return }
            do {
                try await self.reply(with: message.replacing(jsonData: reply))
            } catch {
                logger.warning("Could not reply to \(message.event, privacy: .public): \(error, privacy: .public)")
            }
        }
    }

    // The App Store sheet where the customer manages their subscriptions, or the App Store
    // account page when there is no window to show it on. `manage` gets no reply, so a failure
    // can only be logged. The productId of the message is not needed: the sheet lists them all.
    private func manageSubscriptions() {
        let scene = (delegate?.destination as? UIViewController)?.view.window?.windowScene
        Task {
            if let scene {
                do {
                    try await AppStore.showManageSubscriptions(in: scene)
                    return
                } catch {
                    logger.warning("Could not show the subscriptions sheet: \(error, privacy: .public)")
                }
            }
            await UIApplication.shared.open(URL(string: "https://apps.apple.com/account/subscriptions")!)
        }
    }
}

private let logger = Logger(subsystem: "com.pmaker.tillbell", category: "tillbell")
#endif
