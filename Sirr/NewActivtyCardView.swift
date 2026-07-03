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
    /// When non-nil, load image from URL; otherwise use imageName.
    var imageURL: String? = nil
    var imageName: ImageResource = .card1
    /// Shows the "يتكرر أسبوعيًا" badge for series-linked events.
    var isRecurring: Bool = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Background image — same aspect ratio for all cards (4:3)
                Group {
                    if let resource = EventData.imageResource(for: imageURL) {
                        Image(resource)
                            .resizable()
                            .scaledToFill()
                    } else if let urlString = imageURL, urlString.hasPrefix("http"), let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .failure, .empty:
                                Image(imageName)
                                    .resizable()
                                    .scaledToFill()
                            @unknown default:
                                Image(imageName)
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                    } else {
                        Image(imageName)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .aspectRatio(4/3, contentMode: .fill)
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
                        .font(.appFont(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                    Text(eventDate)
                        .font(.appFont(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.bottom, 56)
                .padding(.horizontal, 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isRecurring {
                HStack(spacing: 6) {
                    Image(systemName: "repeat")
                        .font(.system(size: 12, weight: .semibold))
                    Text("يتكرر أسبوعيًا")
                        .font(.appCaption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(.black.opacity(0.35)))
                .padding(16)
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
