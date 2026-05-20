//
//  NewActivtyCardView.swift
//  Sirr
//
//  Created by فارس أبومالح on 05/05/1447 AH.
//

import SwiftUI

struct NewActivtyCardView: View {
    var eventName: String = "اسم الفعالية"
    var eventDate: String = "يوم الثلاثاء، الساعة 6:00 م"
    var imageName: ImageResource = .card1
    
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                
                ZStack(alignment: .bottom) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.black.opacity(0.0), location: 0.0),
                                    .init(color: Color.black.opacity(0.03), location: 0.35),
                                    .init(color: Color.black.opacity(0.10), location: 0.68),
                                    .init(color: Color.black.opacity(0.18), location: 1.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blur(radius: 20)
                        .frame(height: 226)
                        .allowsHitTesting(false)
                    
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.black.opacity(0.0), location: 0.0),
                                    .init(color: Color.black.opacity(0.08), location: 0.46),
                                    .init(color: Color.black.opacity(0.28), location: 1.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: 226)
                        .allowsHitTesting(false)
                }
                
                VStack(spacing: 8) {
                    Text(eventName)
                        .font(.appFont(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.9)
                    
                    Text(eventDate)
                        .font(.appFont(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                }
                .frame(width: 206)
                .padding(.bottom, 56)
            }
        }
        .clipShape(
            RoundedRectangle(cornerRadius: 36, style: .continuous)
        )
    }
}

#Preview {
    NewActivtyCardView()
}
