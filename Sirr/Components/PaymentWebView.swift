//
//  PaymentWebView.swift
//  Sirr
//
//  MyFatoorah's hosted card page, shown in the app (test mode only today). The
//  moment the page sends the payer to the "payment done" address we gave
//  MyFatoorah, the page closes itself and the caller checks the payment; that
//  address itself is never loaded. A close button lets the payer cancel.
//

import SwiftUI
import WebKit

struct PaymentWebSheet: View {
    let url: URL
    /// Where MyFatoorah sends the payer once payment is done. Must match the
    /// redirect the server gives MyFatoorah (pay-card-test: https://tamrien.app/).
    var finishHost = "tamrien.app"
    let onFinish: () -> Void

    var body: some View {
        NavigationStack {
            PaymentWebView(url: url, finishHost: finishHost, onFinish: onFinish)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("الدفع")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("إغلاق", action: onFinish)
                    }
                }
        }
    }
}

private struct PaymentWebView: UIViewRepresentable {
    let url: URL
    let finishHost: String
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(finishHost: finishHost, onFinish: onFinish)
    }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let finishHost: String
        let onFinish: () -> Void
        private var finished = false

        init(finishHost: String, onFinish: @escaping () -> Void) {
            self.finishHost = finishHost
            self.onFinish = onFinish
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let host = navigationAction.request.url?.host(),
                  host == finishHost || host.hasSuffix("." + finishHost) else {
                decisionHandler(.allow)
                return
            }
            // MyFatoorah is done with the payer. Don't load our website; close.
            decisionHandler(.cancel)
            guard !finished else { return }
            finished = true
            onFinish()
        }
    }
}

/// Lets a URL drive `.sheet(item:)`.
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
