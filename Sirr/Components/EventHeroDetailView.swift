//
//  EventHeroDetailView.swift
//  Sirr
//
//  Created to show event details with hero animation
//

import SwiftUI

struct EventHeroDetailView: View {
    let event: EventData
    var onClose: () -> Void
    var onEnroll: () -> Void

    @State private var isEnrolled = false
    
    // Sample participants
    private let participants: [String] = [
        "محمد معلا",
        "عبدالله قحطاني",
        "عبدالمحسن",
        "مراد الجهني",
        "باسل العسكر",
        "أحمد رشوان",
        "عبدالرحمن الظاهر",
        "حسن الشهري",
        "خالد المسلم"
    ]

    var body: some View {
        ZStack(alignment: .top) {
            // Background
            GeometryReader { proxy in
                Image(event.image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                    .clipped()
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
            
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.25), location: 0.35),
                    .init(color: .black.opacity(0.55), location: 0.6),
                    .init(color: .black.opacity(0.75), location: 1)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .blur(radius: 18)
            .ignoresSafeArea()
            
            // Content
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // Title & date
                    VStack(spacing: 8) {
                        Text(event.name)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        
                        Text(event.date)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 140)
                    
                    // Enroll button
                    Button {
                        isEnrolled.toggle()
                        onEnroll()
                    } label: {
                        HStack(spacing: 8) {
                            Text(isEnrolled ? "تم التسجيل" : "سجل في التمرين")
                            Image(systemName: isEnrolled ? "checkmark" : "plus")
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(isEnrolled ? Color.green.opacity(0.85) : Color.blue)
                                .shadow(color: .black.opacity(0.25), radius: 10, y: 6)
                        )
                    }
                    .padding(.horizontal, 4)
                    
                    // Quick actions
                    HStack(spacing: 12) {
                        ActionChip(icon: "gearshape.fill", title: "إعدادات")
                        ActionChip(icon: "square.and.arrow.up.fill", title: "مشاركة")
                        ActionChip(icon: "lock.fill", title: "قفل التسجيل")
                    }
                    
                    // Progress card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("نسبة اكتمال التمرين")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("9/16")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        
                        ProgressView(value: 9, total: 16)
                            .tint(.green)
                    }
                    .padding()
                    .background(.ultraThinMaterial.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    
                    // Participants list
                    VStack(alignment: .leading, spacing: 12) {
                        Text("القائمة")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        
                        ForEach(participants, id: \.self) { name in
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 36, height: 36)
                                    .foregroundStyle(.white.opacity(0.8))
                                
                                Text(name)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white)
                                
                                Spacer()
                                
                                Circle()
                                    .fill(.white.opacity(0.35))
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Image(systemName: "person.fill")
                                            .foregroundStyle(Color.gray.opacity(0.8))
                                    )
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 14)
                            .background(.ultraThinMaterial.opacity(0.55))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                    }
                    .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .padding(.top, 20)
            
            // Top controls
            HStack {
                IconButton(system: "chevron.backward", action: onClose)
                Spacer()
                IconButton(system: "xmark", action: onClose)
            }
            .padding(.horizontal, 20)
            .padding(.top, 52)
        }
    }
}

//////////////////////////////////////////////////
// MARK: - Components
//////////////////////////////////////////////////

private struct IconButton: View {
    let system: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
    }
}

// Small helper chip
private struct ActionChip: View {
    var icon: String
    var title: String
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Color.black)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
