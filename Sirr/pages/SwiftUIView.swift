//
//  SwiftUIView.swift
//  Sirr
//
//  Created by فارس أبومالح on 07/08/1447 AH.
//

import SwiftUI

struct SwiftUIView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                Image(.card1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .cornerRadius(48)
                    .padding(.horizontal, 36)
            }
            .toolbarTitleDisplayMode(.inline)
            .navigationTitle("Tamreen")
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled)
        .environment(\.colorScheme, .dark)
    }
}

#Preview {
    SwiftUIView()
}
