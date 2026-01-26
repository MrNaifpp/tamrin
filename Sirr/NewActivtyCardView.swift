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
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background image
                Image(imageName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                
                // Bottom gradient overlay with blur to separate image and text
                ZStack(alignment: .bottom) {
                    // Blurred gradient layer (lighter, more blur, smaller height)
                    Rectangle()
                        .fill( 
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.black.opacity(0.0), location: 0.0),
                                    .init(color: Color.black.opacity(0.12), location: 0.35),
                                    .init(color: Color.black.opacity(0.28), location: 0.65),
                                    .init(color: Color.black.opacity(0.45), location: 1.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blur(radius: 22)
                        .frame(height: max(geometry.size.height * 0.32, 160))
                        .allowsHitTesting(false)
                    
                    // Sharper gradient for text readability (still light)
                    Rectangle()
                        .fill(
                            LinearGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Color.black.opacity(0.0), location: 0.0),
                                    .init(color: Color.black.opacity(0.18), location: 0.45),
                                    .init(color: Color.black.opacity(0.5), location: 1.0)
                                ]),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(height: max(geometry.size.height * 0.28, 140))
                        .allowsHitTesting(false)
                }
                
                // Text overlay at bottom
                VStack(spacing: 12) {
                    Text(eventName)
                        .font(.appHeadline)
                        .foregroundStyle(.white)
                    Text(eventDate)
                        .font(.appSubheadline)
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 56)
                .padding(.horizontal, 24)
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
