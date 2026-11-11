//
//  SafariView.swift
//  Sirr
//
//  A web page shown inside the app with Safari's own chrome, for pages that
//  belong to someone else — today, MyFatoorah's hosted card page in test mode.
//

import SafariServices
import SwiftUI

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// Lets a URL drive `.sheet(item:)`.
struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
