import AppKit
import SwiftUI
import WebKit

struct GitHubHTMLBodyView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.setAccessibilityLabel("GitHub Markdown description")
        context.coordinator.render(html, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(html, in: webView)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var renderedHTML: String?
        private var allowsDocumentLoad = false

        func render(_ html: String, in webView: WKWebView) {
            guard renderedHTML != html else { return }
            renderedHTML = html
            allowsDocumentLoad = true
            webView.loadHTMLString(Self.document(containing: html), baseURL: Self.gitHubURL)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.navigationType == .linkActivated {
                if Self.isSameDocumentAnchor(url, currentURL: webView.url) {
                    decisionHandler(.allow)
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                    decisionHandler(.cancel)
                } else {
                    decisionHandler(.cancel)
                }
                return
            }

            if allowsDocumentLoad {
                allowsDocumentLoad = false
                decisionHandler(.allow)
                return
            }

            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            allowsDocumentLoad = false
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            allowsDocumentLoad = false
        }

        private static let gitHubURL = URL(string: "https://github.com")!

        private static func isSameDocumentAnchor(_ url: URL, currentURL: URL?) -> Bool {
            guard url.fragment != nil, let currentURL else { return false }
            var target = URLComponents(url: url, resolvingAgainstBaseURL: true)
            var current = URLComponents(url: currentURL, resolvingAgainstBaseURL: true)
            target?.fragment = nil
            current?.fragment = nil
            return target == current
        }

        private static func document(containing bodyHTML: String) -> String {
            """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; media-src https:; style-src 'unsafe-inline'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
              <style>
                :root { color-scheme: light dark; }
                * { box-sizing: border-box; }
                body {
                  max-width: 760px;
                  margin: 0 auto;
                  padding: 24px 24px 48px;
                  color: #1f2328;
                  background: transparent;
                  font: 14px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
                  overflow-wrap: anywhere;
                }
                a { color: #0969da; text-decoration: none; }
                a:hover { text-decoration: underline; }
                h1, h2, h3, h4, h5, h6 { margin: 1.4em 0 0.55em; line-height: 1.25; }
                h1, h2 { padding-bottom: 0.3em; border-bottom: 1px solid #d0d7de; }
                h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
                p, blockquote, ul, ol, table, pre { margin: 0 0 16px; }
                ul, ol { padding-left: 2em; }
                blockquote { margin-left: 0; padding-left: 1em; color: #59636e; border-left: 4px solid #d0d7de; }
                code { padding: 0.15em 0.35em; border-radius: 4px; background: #818b981f; font: 0.9em ui-monospace, SFMono-Regular, Menlo, monospace; }
                pre { padding: 16px; overflow: auto; border-radius: 6px; background: #f6f8fa; }
                pre code { padding: 0; background: transparent; }
                img, video { max-width: 100%; height: auto; }
                table { display: block; max-width: 100%; overflow: auto; border-collapse: collapse; }
                th, td { padding: 6px 13px; border: 1px solid #d0d7de; }
                tr:nth-child(2n) { background: #f6f8fa; }
                input[type="checkbox"] { margin-right: 0.45em; }
                @media (prefers-color-scheme: dark) {
                  body { color: #f0f6fc; }
                  a { color: #58a6ff; }
                  h1, h2, th, td { border-color: #3d444d; }
                  blockquote { color: #9198a1; border-color: #3d444d; }
                  pre, tr:nth-child(2n) { background: #151b23; }
                }
              </style>
            </head>
            <body>\(bodyHTML)</body>
            </html>
            """
        }
    }
}
