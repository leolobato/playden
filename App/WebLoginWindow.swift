import AppKit
import WebKit

/// A store's login page in its own window, for a player with a keyboard (PRD 10 AR-MULTI-12). It
/// watches navigation and hands back the address the login ends on, which is never loaded.
/// Keys typed here go to the page: the launcher's keyboard monitor passes this window's events through.
@MainActor
final class WebLoginWindow: NSWindow, WKNavigationDelegate {
    private let webView: WKWebView
    private let matches: (URL) -> Bool
    private var onRedirect: ((String) -> Void)?
    var onClose: (() -> Void)?

    init(loginURL: URL, title: String, matches: @escaping (URL) -> Bool, onRedirect: @escaping (String) -> Void) {
        let configuration = WKWebViewConfiguration()
        // A fresh, private session each time: nothing from the login is kept on this Mac.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 720), configuration: configuration)
        self.matches = matches; self.onRedirect = onRedirect
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        level = .floating
        contentView = webView
        webView.navigationDelegate = self
        webView.load(URLRequest(url: loginURL))
        center()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(webView)
    }

    override func close() {
        onRedirect = nil
        webView.stopLoading()
        super.close()
        onClose?(); onClose = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, matches(url) else { decisionHandler(.allow); return }
        decisionHandler(.cancel)
        let handler = onRedirect
        close()
        handler?(url.absoluteString)
    }
}
