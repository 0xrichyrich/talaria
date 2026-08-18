import SwiftUI
import TalariaKit
import TalariaTheme

// In-app sign-in sheet for the gateway's native PKCE broker flow.
//
// Why not the system browser: Lockdown Mode's Safari refuses http:// on
// non-standard ports ("Not allowed to use restricted network port"), which
// breaks the RFC 8252 loopback redirect outright. A WKWebView can intercept
// the redirect to http://127.0.0.1:<port>/callback as a *navigation policy
// decision* — the loopback socket is never dialed, so no port rules apply.
// Desktop has the same embedded fallback (its legacy BrowserWindow flow).

/// Attach to any view that owns an AuthController; presents the in-app
/// sign-in sheet whenever the controller requests one. No-op on macOS,
/// which keeps the loopback-listener + system-browser flow.
struct WebAuthPresenter: ViewModifier {
    var auth: AuthController
    var theme: ThemePack

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(item: Binding(
            get: { auth.webAuthRequest },
            set: { if $0 == nil { auth.webAuthCancelled() } }
        )) { request in
            AuthWebSheet(request: request, theme: theme,
                         onCallback: { auth.handleWebCallback($0) },
                         onCancel: { auth.webAuthCancelled() })
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
import WebKit

struct AuthWebSheet: View {
    var request: AuthController.WebAuthRequest
    var theme: ThemePack
    var onCallback: (URL) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            AuthWebView(url: request.url, onCallback: onCallback)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                            .tint(theme.accent)
                    }
                }
        }
        .interactiveDismissDisabled(false)
    }
}

private struct AuthWebView: UIViewRepresentable {
    let url: URL
    let onCallback: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCallback: onCallback) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onCallback: (URL) -> Void
        init(onCallback: @escaping (URL) -> Void) { self.onCallback = onCallback }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     preferences: WKWebpagePreferences,
                     decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            if let url = navigationAction.request.url,
               url.host == "127.0.0.1" || url.host == "::1" || url.host == "[::1]",
               url.path == "/callback" {
                decisionHandler(.cancel, preferences)
                let callback = self.onCallback
                DispatchQueue.main.async { callback(url) }
                return
            }
            // The gateway/IdP pages inside this dedicated sign-in sheet may
            // opt out of Lockdown Mode's WebKit restrictions so login forms
            // render; nothing else in the app hosts web content.
            preferences.isLockdownModeEnabled = false
            decisionHandler(.allow, preferences)
        }
    }
}
#endif
