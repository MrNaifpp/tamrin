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
    @State private var showEnrollmentSheet = false
    
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
                   
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                   
                    .blur(radius: 14)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
            
            
        // Content
        ZStack(alignment: .bottom) {
            // Rounded glass container for content
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    // Header: title & date
                    VStack(spacing: 8) {
                        Text(event.name)
                            .font(.appLargeTitle)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                        
                        Text(event.date)
                            .font(.appBodySemibold)
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    
                    // Enroll button (pill)
                    Button {
                        if isEnrolled {
                            isEnrolled = false
                        } else {
                            showEnrollmentSheet = true
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isEnrolled ? "minus" : "plus")
                                .foregroundStyle(isEnrolled ? Color.white : Color.black)
                            Text(isEnrolled ? "الإعتــذار من التمريــــن" : "سجل في التمرين")
                                .font(.appBody)
                                .foregroundStyle(isEnrolled ? Color.white : Color.black)
                        }
                        .font(.appBodySemibold)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(isEnrolled ? Color.red : Color.white)
                                .shadow(color: .black.opacity(0.35), radius: 8, y: 8)
                                
                        )
                    }
                    .sheet(isPresented: $showEnrollmentSheet) {
                        EnrollmentSheetView(
                            event: event,
                            onEnroll: {
                                isEnrolled = true
                                showEnrollmentSheet = false
                                onEnroll()
                            }
                        )
                    }
                    
                    // Quick actions (glass chips)
                    // if isEnrolled {
                    //     HStack(spacing: 12) {
                    //         ActionChip(icon: "lock.fill", title: "قفل التسجيل", style: .solid)
                    //         ActionChip(icon: "gearshape.fill", title: "إعدادات", style: .translucent)
                    //         ActionChip(icon: "square.and.arrow.up.fill", title: "مشاركة", style: .translucent)
                    //     }
                    // }
                    
                    // Progress card (glass)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("نسبة اكتمال التمرين")
                                .font(.appCallout)
                                .foregroundStyle(.white)
                            Spacer()
                            Text("9/16")
                                .font(.appCallout)
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        
                        ProgressView(value: 9, total: 16)
                            .frame(height: 20)
                            .tint(.green)
                            
                    }
                    .padding()
                    .background(Color.white.opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                    
                    // Participants list (glass rows)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("القائمة")
                            .font(.appBodySemibold)
                            .foregroundStyle(.white.opacity(0.9))
                        
                        ForEach(participants, id: \.self) { name in
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 38, height: 38)
                                    .foregroundStyle(.white.opacity(0.9))
                                
                                Text(name)
                                    .font(.appBodyMedium)
                                    .foregroundStyle(.white)
                                
                                Spacer()
                                
                                
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .background(Color.white.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(.white.opacity(0.18), lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                        }
                    }
                    .padding(.bottom, 32)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
            .background(Color.clear)
            .padding(.horizontal, 14)
            .padding(.top, 160)
            .padding(.bottom, 24)
        }
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
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial)
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .clipShape(Circle())
        }
    }
}

// Small helper chip
private struct ActionChip: View {
    enum Style {
        case translucent  // Translucent green background with white icons/text
        case solid        // Solid light gray background with black icons/text, wider
    }
    
    var icon: String
    var title: String
    var style: Style = .translucent
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.appSubheadline)
            Text(title)
                .font(.appCaption)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .foregroundStyle(style == .translucent ? Color.white : Color.black)
        .frame(maxWidth: style == .solid ? 120 : 60)
        .frame(minWidth: style == .solid ? 80 : 40)
        
        .padding(.horizontal, style == .solid ? 16 : 8)
        .padding(.vertical, 12)
        .background(
            ZStack {
                if style == .translucent {
                    // Translucent green background with glass effect
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.green.opacity(0.25))
                } else {
                    // Solid light gray background
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white)
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(style == .translucent ? Color.white.opacity(0.15) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

// MARK: - Enrollment Sheet
struct EnrollmentSheetView: View {
    let event: EventData
    let onEnroll: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage: Int = 0
    @State private var isNameSelected: Bool = false
    @State private var showAddParticipant: Bool = false
    @State private var newParticipantName: String = ""
    @State private var participants: [String] = []
    
    // Sample events for preview (including current event in the middle)
    private var allEvents: [EventData] {
        [
            EventData(name: "اسم الفعالية", date: "يوم الثلاثاء، الساعة 6:00 م", image: .card1),
            event,
            EventData(name: "التمرين", date: "يوم الاثنين", image: .actnew)
        ]
    }
    
    // Current user
    private let userName = "محمد معلا"
    
    var body: some View {
        ZStack {
            // Dark background
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    Text("سجل في التمرين")
                        .font(.appBody)
                    
                        .foregroundStyle(.white)
                    
                    Spacer()
                    
                    // Balance the header
                    Color.clear
                        .frame(width: 40, height: 40)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
                
                VStack(spacing: 0) {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 24) {
                            Image(event.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 140, height: 100)
                                .clipped()
                                .cornerRadius(16)
                                .shadow(radius: 6)
                                .frame(maxWidth: .infinity)

                            Text(event.name)
                                .font(.appBodySemibold)
                                .foregroundStyle(.white)
                                .padding(.top, 8)

                            Text(event.date)
                                .font(.appBody)
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.top, 8)
                            
                            // Instructional text
                            HStack {
                                Text("اضغط على اسمك لإكمال التسجيل")
                                    .font(.appBodyMedium)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .padding(.top, 10)
                                Spacer()
                            }
                            
                            // User selection button
                            Button {
                                isNameSelected = true
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.crop.circle.fill")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 40, height: 40)
                                        .foregroundStyle(.white.opacity(0.9))
                                    
                                    Text(userName)
                                        .font(.appBodySemibold)
                                        .foregroundStyle(.white)
                                    
                                    Spacer()
                                    
                                    if isNameSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                            .font(.system(size: 20))
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 14)
                                .background(isNameSelected ? Color.green.opacity(0.2) : Color.gray.opacity(0.3))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }

                            Divider()
                                .background(Color.white.opacity(0.25))
                                .padding(.vertical, 12)
                            
                            // Participants list
                            if participants.count > 0 {
                                VStack(spacing: 12) {
                                    ForEach(participants, id: \.self) { participant in
                                        HStack(spacing: 12) {
                                            Image(systemName: "person.crop.circle.fill")
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 40, height: 40)
                                                .foregroundStyle(.white.opacity(0.9))
                                            
                                            Text(participant)
                                                .font(.appBodySemibold)
                                                .foregroundStyle(.white)
                                            
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .background(participant == userName ? Color.green.opacity(0.2) : Color.gray.opacity(0.3))
                                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    }
                                }
                            }
                            
                            // Add participant button
                            if !showAddParticipant {
                                Button {
                                    showAddParticipant.toggle()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 16, weight: .semibold))
                                        Text("بسجل معي أحد")
                                            .font(.appBodyMedium)
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.gray.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                                }
                            }
                            
                            // Add participant input field (shown when button is tapped)
                            if showAddParticipant {
                                VStack(spacing: 12) {
                                    TextField("", text: $newParticipantName, prompt:
                                        Text("الاسم كامل")
                                            .foregroundColor(.white.opacity(0.7))
                                    )
                                        .font(.appBody)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 14)
                                        .background(Color.gray.opacity(0.3))
                                        .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                                    
                                    Button {
                                        // Save the new participant and add a card with their name below user's name
                                        if !newParticipantName.isEmpty {
                                            if let selectedIdx = participants.firstIndex(of: userName) {
                                                // Insert below user's name
                                                participants.insert(newParticipantName, at: selectedIdx + 1)
                                            } else {
                                                // If userName doesn't exist, append at the end
                                                participants.append(newParticipantName)
                                            }
                                            newParticipantName = ""
                                            showAddParticipant = false
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: "plus")
                                                .font(.system(size: 16, weight: .semibold))
                                            Text("بسجل واحد زيادة")
                                                .font(.appBodyMedium)
                                        }
                                        .foregroundStyle(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(newParticipantName.isEmpty ? Color.gray.opacity(0.5) : Color.blue)
                                        .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                                    }
                                    .disabled(newParticipantName.isEmpty)
                                }
                                .padding(.top, 12)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                        .padding(.bottom, 24)
                    }
                    
                    // Register button at bottom
                    VStack {
                        Button {
                            onEnroll()
                            dismiss()
                        } label: {
                            Text("سجل")
                                .font(.appBodySemibold)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(isNameSelected ? Color.blue : Color.blue.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                                .shadow(color: isNameSelected ? .black.opacity(0.3) : .clear, radius: 8, y: 4)
                        }
                        .disabled(!isNameSelected)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
