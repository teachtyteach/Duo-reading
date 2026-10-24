import SwiftUI
import UIKit
import WebKit

/// Hosts the Duo Reader web app inside a native iPhone app.
struct ReaderWebView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebHostController {
        WebHostController()
    }

    func updateUIViewController(_ controller: WebHostController, context: Context) {}
}

final class WebHostController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView!
    private let lightTap = UIImpactFeedbackGenerator(style: .light)
    private let mediumTap = UIImpactFeedbackGenerator(style: .medium)
    private let notifier = UINotificationFeedbackGenerator()

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: "duoreader")
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.allowsInlineMediaPlayback = true

        let contentController = WKUserContentController()
        contentController.add(WeakMessageHandler(self), name: "native")
        config.userContentController = contentController

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.scrollView.alwaysBounceVertical = false
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        #if DEBUG
        if #available(iOS 16.4, *) {
            web.isInspectable = true
        }
        #endif
        webView = web
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        lightTap.prepare()
        if let url = URL(string: "duoreader://app/index.html") {
            webView.load(URLRequest(url: url))
        }
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: Messages from the web app

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "haptic":
            let style = body["style"] as? String ?? "light"
            switch style {
            case "success":
                notifier.notificationOccurred(.success)
            case "medium":
                mediumTap.impactOccurred()
            default:
                lightTap.impactOccurred()
                lightTap.prepare()
            }
        case "reading":
            UIApplication.shared.isIdleTimerDisabled = (body["on"] as? Bool) ?? false
        default:
            break
        }
    }

    // MARK: Links open in Safari

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "mailto", "tel"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

/// Avoids a retain cycle between the web view and its message handler.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Serves the bundled web files at duoreader://app/... so the app works fully offline.
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        var path = url.path
        while path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }
        let name = (path as NSString).lastPathComponent
        let folder = (path as NSString).deletingLastPathComponent

        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: folder.isEmpty ? "Web" : "Web/" + folder),
            Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Web"),
            Bundle.main.url(forResource: name, withExtension: nil)
        ]

        guard let fileURL = candidates.compactMap({ $0 }).first,
              let data = try? Data(contentsOf: fileURL) else {
            if let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"]) {
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(Data())
                urlSchemeTask.didFinish()
            }
            return
        }

        let headers = [
            "Content-Type": mimeType(for: fileURL.pathExtension),
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache"
        ]
        if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers) {
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }
}
