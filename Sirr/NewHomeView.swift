//
//  NewHomeView.swift
//  Sirr
//
//  Created by فارس أبومالح on 15/05/1447 AH.
//

import SwiftUI

struct NewHomeView: View {
    @Namespace var namespace
    var body: some View {
        VStack(spacing: 40) {
            HStack {
                Text("القادمة")
                    .font(.title)
                    .fontWeight(.bold)
                Image(systemName: "chevron.up.chevron.down")
                Spacer()
                HStack {
                    Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.gray)
                }
            }
            .padding(4)
            NewActivtyCardView()
        }
            .padding(20)
        Spacer()
    }
}
#Preview {
    NewHomeView()
}
