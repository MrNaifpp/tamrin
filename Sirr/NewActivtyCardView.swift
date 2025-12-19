//
//  NewActivtyCardView.swift
//  Sirr
//
//  Created by فارس أبومالح on 05/05/1447 AH.
//

import SwiftUI

struct NewActivtyCardView: View {
    var body: some View {
        Rectangle()
            .frame(height: 612)
            .overlay {
                Image(.pic)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .overlay(alignment: .bottom) {
                VStack(alignment: .center, spacing: 12) {
                    Text("اسم الفعالية")
                        .font(.system(size: 28))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text("يوم الثلاثاء، الساعة 6:00 م")
                        .font(.system(size: 18))
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                }
                .padding(56)
            }
            .clipShape(
                RoundedRectangle(cornerRadius: 36, style: .continuous)
            )
            .shadow(color: .black.opacity(0.2), radius: 40)


    }
}

#Preview {
    NewActivtyCardView()
}
