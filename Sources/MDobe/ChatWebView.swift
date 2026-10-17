import AppKit
import SwiftUI
import WebKit

/// Conversación del asistente renderizada con Markdown + KaTeX (todo local, en Resources/Web).
struct ChatWebView: NSViewRepresentable {
    let messages: [Assistant.Message]
    let goToPage: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(goToPage: goToPage) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "copy")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        if let dir = Bundle.main.url(forResource: "Web", withExtension: nil) {
            web.loadFileURL(dir.appendingPathComponent("chat.html"), allowingReadAccessTo: dir)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.goToPage = goToPage
        context.coordinator.show(messages)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var web: WKWebView?
        var goToPage: (Int) -> Void
        private var loaded = false
        private var pending: String?

        init(goToPage: @escaping (Int) -> Void) { self.goToPage = goToPage }

        func show(_ messages: [Assistant.Message]) {
            let payload = messages.map { m -> [String: String] in
                let role = switch m.role { case .user: "user"; case .ai: "ai"; case .info: "info" }
                return ["role": role, "text": m.text]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
            if loaded { web?.evaluateJavaScript("render(\(json))") } else { pending = json }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let pending { webView.evaluateJavaScript("render(\(pending))") }
            pending = nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, action.navigationType == .linkActivated else { return decisionHandler(.allow) }
            if url.scheme == "mdobe", let n = Int(url.lastPathComponent) {
                goToPage(n)
            } else if url.scheme == "https" || url.scheme == "http" {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let tex = message.body as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tex, forType: .string)
        }
    }
}
