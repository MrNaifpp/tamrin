//
//  EventHeroDetailView.swift
//  Sirr
//
//  Created to show event details with hero animation
//

import SwiftUI

#if os(iOS)

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
    private let supervisorName = "محمد معلا"
    private let progressCurrent = 9
    private let progressTotal = 16

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                backgroundLayer(proxy: proxy)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        heroSection(proxy: proxy)

                        VStack(spacing: 12) {
                            if isEnrolled {
                                actionRow
                                    .padding(.top, -16)
                            } else {
                                enrollButton
                                    .padding(.top, -16)
                            }

                            progressCard

                            if isEnrolled {
                                labeledSection(title: "المشرف") {
                                    DetailParticipantRow(name: supervisorName)
                                }
                            }

                            labeledSection(title: "القائمة") {
                                VStack(spacing: 8) {
                                    ForEach(participants, id: \.self) { name in
                                        DetailParticipantRow(name: name)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                    }
                }
            }
            .ignoresSafeArea()
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
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    @ViewBuilder
    private func backgroundLayer(proxy: GeometryProxy) -> some View {
        ZStack {
            Image(event.image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .ignoresSafeArea()
                .blur(radius: 18)
                .allowsHitTesting(false)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.20),
                    Color.black.opacity(0.36)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 320)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.0),
                                Color.black.opacity(0.42)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: proxy.size.height)
                    .blur(radius: 30)
            }
        }
    }

    @ViewBuilder
    private func heroSection(proxy: GeometryProxy) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(event.image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: 520)
                .clipped()
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.0),
                            Color.black.opacity(0.15),
                            Color.black.opacity(0.45)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 230)
                }

            Button(action: onClose) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.28))

                    Circle()
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .padding(.top, 76)
            .padding(.trailing, 16)

            VStack(spacing: 4) {
                Spacer()

                VStack(spacing: 0) {
                    Text(event.name)
                        .font(.appFont(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)

                    Text(event.date)
                        .font(.appFont(size: 20, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: 206)
                .padding(.bottom, 28)
            }
            .frame(height: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var enrollButton: some View {
        Button {
            showEnrollmentSheet = true
        } label: {
            HStack(spacing: 8) {
                Text("سجــــل في التمريــــن")
                    .font(.appFont(size: 20, weight: .regular))
                    .foregroundStyle(.black)

                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color.white.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
        }
        .buttonStyle(.plain)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            DetailActionCard(
                title: "قفــل التسجيـــل",
                systemImage: "lock.fill",
                isPrimary: true
            )
            .frame(maxWidth: .infinity)

            DetailActionCard(
                title: "مشاركـــة",
                systemImage: "square.and.arrow.up.fill",
                isPrimary: false
            )
            .frame(width: 92)

            DetailActionCard(
                title: "الإعدادات",
                systemImage: "gearshape.fill",
                isPrimary: false
            )
            .frame(width: 92)
        }
    }

    private var progressCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("نسبــة إكتمــال التمريـــن")
                    .font(.appFont(size: 18, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(progressTotal)\\\(progressCurrent)")
                    .font(.appFont(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }

            GeometryReader { proxy in
                ZStack(alignment: .trailing) {
                    Capsule()
                        .fill(Color.white.opacity(0.20))

                    Capsule()
                        .fill(Color(red: 0.24, green: 0.72, blue: 0.34))
                        .frame(width: proxy.size.width * progressRatio)
                }
            }
            .frame(height: 12)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var progressRatio: CGFloat {
        guard progressTotal > 0 else { return 0 }
        return CGFloat(progressCurrent) / CGFloat(progressTotal)
    }

    private func labeledSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .trailing, spacing: 12) {
            Text(title)
                .font(.appFont(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, alignment: .trailing)

            content()
        }
    }
}

private struct DetailActionCard: View {
    var title: String
    var systemImage: String
    var isPrimary: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))

            Text(title)
                .font(.appFont(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(isPrimary ? Color.black : Color.white.opacity(0.85))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(isPrimary ? Color.white.opacity(0.82) : Color.white.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(isPrimary ? 0.0 : 0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DetailParticipantRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.appFont(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Circle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    .frame(maxWidth: .infinity)
                    
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
#else
struct EventHeroDetailView: View {
    let event: EventData
    var onClose: () -> Void
    var onEnroll: () -> Void

    var body: some View {
        ContentUnavailableView(
            "تفاصيل الفعالية متاحة على iOS فقط",
            systemImage: "rectangle.portrait.on.rectangle.portrait",
            description: Text("الشاشة الأصلية الخاصة بانتقالات الهاتف ما زالت محفوظة، لكن النسخة المكتبية تستخدم تدفقًا مختلفًا بالكامل.")
        )
    }
}
#endif
