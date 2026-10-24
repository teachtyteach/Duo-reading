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
    private var savedBrightness: CGFloat?

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
        NativeBridge.shared.host = self
        lightTap.prepare()
        NotificationCenter.default.addObserver(self, selector: #selector(restoreBrightness), name: UIApplication.willResignActiveNotification, object: nil)
        if let url = URL(string: "duoreader://app/index.html") {
            webView.load(URLRequest(url: url))
        }
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }

    func runJavaScript(_ script: String) {
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private var screen: UIScreen? {
        view.window?.windowScene?.screen
    }

    @objc func restoreBrightness() {
        if let saved = savedBrightness {
            screen?.brightness = saved
            savedBrightness = nil
        }
    }

    private func setDim(_ amount: Double) {
        guard let screen = screen else { return }
        if savedBrightness == nil { savedBrightness = screen.brightness }
        let base = savedBrightness ?? screen.brightness
        screen.brightness = max(0.03, base * CGFloat(1 - min(0.85, amount * 1.4)))
    }

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
        case "ready":
            NativeBridge.shared.markReady()
        case "state":
            NativeBridge.shared.receiveState(body)
        case "speak":
            var segments: [Speaker.Segment] = []
            if let raw = body["segments"] as? [[Any]] {
                for item in raw where item.count >= 2 {
                    guard let text = item[1] as? String else { continue }
                    let offset = (item[0] as? NSNumber)?.intValue ?? 0
                    let heading = item.count > 2 && ((item[2] as? NSNumber)?.intValue ?? 0) == 1
                    segments.append(Speaker.Segment(offset: offset, text: text, isHeading: heading))
                }
            } else if let text = body["text"] as? String {
                segments = [Speaker.Segment(offset: (body["offset"] as? NSNumber)?.intValue ?? 0, text: text, isHeading: false)]
            }
            Speaker.shared.speak(
                segments: segments,
                rate: (body["rate"] as? NSNumber)?.doubleValue ?? 1.0,
                voiceID: body["voice"] as? String ?? "",
                title: body["title"] as? String ?? "",
                author: body["author"] as? String ?? ""
            )
        case "voices":
            Speaker.shared.sendVoices()
        case "voiceSample":
            Speaker.shared.sample(voiceID: body["id"] as? String ?? "")
        case "personalVoice":
            Speaker.shared.requestPersonalVoice()
        case "share":
            shareFile(name: body["name"] as? String ?? "Duo Reader Backup.json", text: body["text"] as? String ?? "")
        case "speechPause":
            Speaker.shared.pause()
        case "speechResume":
            Speaker.shared.resume()
        case "speechStop":
            Speaker.shared.stop()
        case "bright":
            if (body["restore"] as? Bool) == true {
                restoreBrightness()
            } else if let dim = body["dim"] as? Double {
                setDim(dim)
            }
        case "icon":
            let name = body["name"] as? String
            if UIApplication.shared.supportsAlternateIcons {
                UIApplication.shared.setAlternateIconName((name?.isEmpty ?? true) ? nil : name) { _ in }
            }
        case "reminders":
            Reminders.shared.configure(
                on: (body["on"] as? Bool) ?? false,
                hour: body["hour"] as? Int ?? 19,
                minute: body["minute"] as? Int ?? 30
            )
        default:
            break
        }
    }

    private func shareFile(name: String, text: String) {
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            NativeBridge.shared.send("window.duoToast && window.duoToast('The backup couldn’t be saved.')")
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        sheet.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        top.present(sheet, animated: true)
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        NativeBridge.shared.markNotReady()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NativeBridge.shared.markNotReady()
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

        if path.hasPrefix("__import/") {
            let relative = String(path.dropFirst("__import/".count))
            let fileURL = NativeBridge.importFolder.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: fileURL),
               let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream", "Content-Length": String(data.count)]) {
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
                try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
                return
            }
        }
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
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }
}
