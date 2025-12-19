//
//  ActivityCardView.swift
//  Sirr
//
//  Created by فارس أبومالح on 05/05/1447 AH.
//

import SwiftUI

struct ActivityCardView: View {
    var name: String
    var date: String
    var image: Image
    var body: some View {
        Rectangle ()
            .frame(height: 335)
            .overlay {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .overlay(alignment: .bottom) {
                HStack (alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .fontWeight(.semibold)
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                        Text(date)
                            .fontWeight(.medium)
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .padding()
                        .glassEffect()
                }
                .padding(24)
                
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

#Preview {
    ActivityCardView(name: "كورة", date: "يوم الثلاثاء", image: Image(.pizza))
}
