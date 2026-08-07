//
//  ForceUpdateSheet.swift
//  Sirr
//
//  Shown when the installed build is older than the minimum the app still
//  supports. It is the one sheet in the app the user cannot leave: no grabber,
//  no close button, and a swipe down does nothing — the only way forward is the
//  App Store.
//

import SwiftUI

struct ForceUpdateSheet: View {
    /// Where "حدث التطبيق" sends the user. Optional so the sheet still renders
    /// (with the button disabled) before the listing URL is known.
    var storeURL: URL?

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            // Fills the 93 × 90 slot the design leaves for it. Outline, not
            // `.fill`: a solid disc at this size lands as a second black blob
            // above the black action capsule and the two fight each other.
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 60, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 93, height: 90)
                .padding(.top, 32)
                .accessibilityHidden(true)

            Text("فيه تحديث مطلوب للتطبيق")
                .font(TamrinFont.font(size: 20, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 16)

            Text("لاهنت حدث التطبيق عشان تجيك آخر المزايا والتحسينات")
                .font(TamrinFont.font(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            // `.primary` tint, not the accent: the design's action is the
            // inverted neutral — black on the light sheet, white on the dark
            // one — which is exactly what tinting the stock prominent glass
            // style with the foreground colour gives on both. The label then
            // has to be the background colour punched out of that fill, since
            // the style would otherwise keep it white on both.
            TamrinActionButton(
                title: "حدث التطبيق",
                tint: .primary,
                labelColor: Color(uiColor: .systemBackground)
            ) {
                if let storeURL { openURL(storeURL) }
            }
            .disabled(storeURL == nil)
            .padding(.top, 28)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .environment(\.layoutDirection, .rightToLeft)
        .fittedSheet(background: TamrinTheme.sheet, dragIndicator: .hidden)
        // Nothing behind this sheet is usable on an unsupported build, so the
        // swipe, the tap-outside and the hardware back gesture all stay off.
        .interactiveDismissDisabled()
    }
}

#Preview {
    Color.gray
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            ForceUpdateSheet(storeURL: URL(string: "https://apps.apple.com"))
        }
}
