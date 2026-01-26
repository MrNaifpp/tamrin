//
//  NavigationBarView.swift
//  Sirr
//
//  Created for Figma design implementation
//

import SwiftUI

struct NavigationBarView: View {
    var title: String
    var showDiamondIcons: Bool = true
    var onPlusButtonTap: (() -> Void)? = nil
    
    var body: some View {
        HStack(alignment: .center) {
            // Right side (RTL): Title with diamond icons
            HStack(spacing: 8) {
                Text(title)
                    .font(.appTitle)
                    .foregroundStyle(Color.white)
                
                if showDiamondIcons {
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.up")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                            .foregroundStyle(Color.gray)
                        
                        Image(systemName: "chevron.down")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                            .foregroundStyle(Color.gray)
                    }
                    .frame(height: 12)
                }
            }
            
            Spacer()
            
            // Left side (RTL): Plus button and Profile icon
            HStack(spacing: 12) {
                // Plus button
                if let onPlusButtonTap = onPlusButtonTap {
                    Button(action: onPlusButtonTap) {
                        Image(systemName: "plus")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .foregroundStyle(Color.black)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    }
                }
                
                // Profile icon
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Color.gray.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .environment(\.layoutDirection, .rightToLeft)
    }
}

#Preview {
    NavigationBarView(title: "القادمة")
        .padding()
}

