import SwiftUI
import AppKit
import WebKit
import Domain
import Input
import Sources

extension LibraryModel {
    func storePageURL(_ id: GameID) -> URL? {
        if let source = source(for: id) { return source.storePageURL(for: id) }
        return isPreview ? SteamStorePage.url(for: id) : nil
    }
    func storePageAllows(host: String, for id: GameID) -> Bool {
        if let source = source(for: id) { return source.storePageAllows(host: host) }
        return isPreview && SteamStorePage.allows(host: host)
    }
    var storeActions: [String] { ["Close", "Open in browser"] }
    func prepareStorePage() {
        storeScrollRequest = .init(); storeScrollFraction = 0; storeCanScroll = false; storeActionIndex = 0; storeLoadError = nil
    }
    func activateStoreAction() {
        switch storeActions[safe: storeActionIndex] {
        case "Open in browser":
            if case .storePage(let id) = panel, let url = storePageURL(id) { NSWorkspace.shared.open(url) }
        default: panel = nil
        }
    }
    func performStorePage(_ action: InputAction) {
        switch action {
        case .back: panel = nil
        case .confirm: activateStoreAction()
        case .move(.left): storeActionIndex = max(0, storeActionIndex - 1)
        case .move(.right): storeActionIndex = min(storeActions.count - 1, storeActionIndex + 1)
        case .move(.up): scrollStore(-120)
        case .move(.down): scrollStore(120)
        case .previousPage: scrollStore(-540)
        case .nextPage: scrollStore(540)
        default: break // Modal input must never move the library or switch tabs underneath it.
        }
    }
    private func scrollStore(_ points: Double) {
        storeScrollRequest = .init(sequence: storeScrollRequest.sequence + 1, points: points)
    }
}

struct StorePageViewer: View {
    @Bindable var model: LibraryModel
    let gameID: GameID
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.gameName(gameID)).font(Design.condensed(40)).lineLimit(1)
                Text("· Store page").font(Design.condensed(40)).foregroundStyle(Design.secondary)
            }
            if let url = model.storePageURL(gameID) {
                StoreWebView(url: url, request: model.storeScrollRequest, smooth: !model.reducedMotion,
                             allows: { model.storePageAllows(host: $0, for: gameID) }) { fraction, canScroll in
                    model.storeScrollFraction = fraction; model.storeCanScroll = canScroll
                } failed: { model.storeLoadError = $0 }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let error = model.storeLoadError { Text(error).font(Design.body(22)).foregroundStyle(Design.amber).lineLimit(2) }
            HStack(spacing: 28) {
                ForEach(Array(model.storeActions.enumerated()), id: \.offset) { index, title in
                    ActionButton(title: title, primary: index == 0, focused: model.storeActionIndex == index, reducedMotion: model.reducedMotion) {
                        model.storeActionIndex = index; model.activateStoreAction()
                    }
                }
                Spacer()
                if model.storeCanScroll {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(model.controllerName == nil || model.keyboardNavigation ? "↑ ↓ Scroll · PgUp / PgDn Page" : "D-pad Scroll · L2 / R2 Page")
                            .font(Design.body(22)).foregroundStyle(Design.secondary)
                        Text(model.storeScrollFraction <= 0 ? "Top" : model.storeScrollFraction >= 0.999 ? "End of page" : "\(Int(model.storeScrollFraction * 100))%")
                            .font(Design.body(20)).foregroundStyle(Design.muted).monospacedDigit()
                    }
                }
            }
        }.padding(40).frame(width: 1728, height: 1000).background(Design.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Shows the public store page without keeping Steam cookies between visits. Controller commands scroll
/// the page through script; mouse input still works normally, but navigation stays on Steam's store.
struct StoreWebView: NSViewRepresentable {
    let url: URL
    let request: LogScrollRequest
    let smooth: Bool
    let allows: (String) -> Bool
    let position: (Double, Bool) -> Void
    let failed: (String?) -> Void
    private static let positionScript = """
    (() => {
      let pending = false;
      const report = () => {
        pending = false;
        const max = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        window.webkit.messageHandlers.playdenScroll.postMessage({ fraction: max > 1 ? Math.min(1, window.scrollY / max) : 0, canScroll: max > 1 });
      };
      const schedule = () => { if (!pending) { pending = true; requestAnimationFrame(report); } };
      addEventListener('scroll', schedule, { passive: true });
      addEventListener('resize', schedule);
      new ResizeObserver(schedule).observe(document.documentElement);
      schedule();
    })();
    """
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: Self.positionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "playdenScroll")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.underPageBackgroundColor = NSColor(calibratedRed: 0.04, green: 0.035, blue: 0.03, alpha: 1)
        context.coordinator.web = web
        context.coordinator.update(self)
        context.coordinator.sequence = request.sequence
        // Steam's age check would otherwise block mature games behind a form the controller cannot fill.
        let cookies = [("birthtime", "470703601"), ("lastagecheckage", "1-0-1985"), ("wants_mature_content", "1")].compactMap {
            HTTPCookie(properties: [.domain: "store.steampowered.com", .path: "/", .name: $0.0, .value: $0.1, .secure: "TRUE"])
        }
        Task { @MainActor in
            for cookie in cookies { await configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
            web.load(URLRequest(url: url))
        }
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.update(self)
        guard coordinator.sequence != request.sequence else { return }
        coordinator.sequence = request.sequence
        web.evaluateJavaScript("window.scrollBy({ top: \(request.points), behavior: '\(smooth ? "smooth" : "instant")' })")
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "playdenScroll")
        web.stopLoading()
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var web: WKWebView?
        var sequence = 0
        private var position: ((Double, Bool) -> Void)?
        private var failed: ((String?) -> Void)?
        private var allows: ((String) -> Bool)?
        func update(_ view: StoreWebView) { position = view.position; failed = view.failed; allows = view.allows }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let fraction = body["fraction"] as? Double, let canScroll = body["canScroll"] as? Bool else { return }
            position?(fraction, canScroll)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.targetFrame?.isMainFrame == true else { return .allow }
            let host = action.request.url?.host?.lowercased() ?? ""
            return allows?(host) == true ? .allow : .cancel
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { failed?(nil) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
        private func report(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            failed?("The store page could not be loaded. Check your connection and try again.")
        }
    }
}
