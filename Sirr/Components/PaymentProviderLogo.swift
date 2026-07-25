//
//  PaymentProviderLogo.swift
//  Sirr
//
//  Code-native marks for payment providers. These deliberately avoid image
//  downloads so the picker remains complete and useful offline.
//

import SwiftUI

struct PaymentProviderLogo: View {
    let provider: PaymentProvider
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(provider.isCash ? provider.brandColor : provider.logoSurfaceColor)

            if let assetName = provider.logoAssetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
            } else {
                logoContent
                    .foregroundStyle(provider.brandForegroundColor)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.displayName)
    }

    @ViewBuilder
    private var logoContent: some View {
        switch provider {
        case .cash:
            Image(systemName: "banknote.fill")
                .font(.system(size: size * 0.38, weight: .semibold))
        default:
            Text(provider.logoName)
                .font(TamrinFont.font(size: size * 0.22, weight: .bold))
        }
    }
}

#Preview {
    LazyVGrid(columns: [.init(), .init()]) {
        ForEach(PaymentProvider.allCases) { provider in
            VStack(spacing: 8) {
                PaymentProviderLogo(provider: provider)
                Text(provider.displayName)
                    .font(TamrinFont.caption)
            }
        }
    }
    .padding()
}
