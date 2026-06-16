//
//  EventHeroDetailView.swift
//  Sirr
//
//  Created to show event details with hero animation
//

import SwiftUI
internal import Auth
import Supabase

struct EventHeroDetailView: View {
    let event: EventData
    var onClose: () -> Void
    var onEnroll: () -> Void

    @State private var isEnrolled = false
    @State private var isLeavingEvent = false
    @State private var showEnrollmentSheet = false
    @State private var isRegistrationLocked: Bool
    @State private var isTogglingLock = false
    @State private var currentUserId: UUID?
    @State private var participants: [ParticipantRecord] = []
    @State private var participantsLoading = false
    @State private var stcPaySheetNumber: String?
    @State private var showWaitlistSheet = false
    @State private var hasPendingPayment = false
    @State private var isCancellingPending = false

    init(event: EventData, onClose: @escaping () -> Void, onEnroll: @escaping () -> Void) {
        self.event = event
        self.onClose = onClose
        self.onEnroll = onEnroll
        self._isRegistrationLocked = State(initialValue: event.registrationLocked)
    }

    private var isOwner: Bool {
        guard let uid = currentUserId else { return false }
        return event.creatorId == uid
    }
    
    private var eventHeroBackgroundImage: some View {
        Group {
            if let resource = EventData.imageResource(for: event.imageUrl) {
                Image(resource).resizable().scaledToFill()
            } else if let urlString = event.imageUrl,
                      urlString.hasPrefix("http"),
                      let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure, .empty: Image(.card1).resizable().scaledToFill()
                    @unknown default: Image(.card1).resizable().scaledToFill()
                    }
                }
            } else {
                Image(.card1).resizable().scaledToFill()
            }
        }
    }


    var body: some View {
        ZStack(alignment: .top) {
            // Background
            GeometryReader { proxy in
                eventHeroBackgroundImage
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
                    
                    if isOwner {
                        // Owner actions
                        HStack(spacing: 12) {
                            Button {
                                guard !isTogglingLock else { return }
                                isTogglingLock = true
                                Task {
                                    defer { isTogglingLock = false }
                                    do {
                                        let newValue = try await EventService.shared.toggleRegistrationLock(eventId: event.id)
                                        isRegistrationLocked = newValue
                                    } catch {
                                        print("[ToggleLock] Error — \(error.localizedDescription)")
                                    }
                                }
                            } label: {
                                ActionChip(
                                    icon: isRegistrationLocked ? "lock.open.fill" : "lock.fill",
                                    title: isRegistrationLocked ? "فتح التسجيل" : "قفل التسجيل",
                                    style: .solid
                                )
                                .opacity(isTogglingLock ? 0.5 : 1.0)
                            }
                            .buttonStyle(.plain)
                            .disabled(isTogglingLock)

                            ShareLink(item: "sirr://event/\(event.id.uuidString)") {
                                ActionChip(icon: "square.and.arrow.up.fill", title: "مشاركة", style: .translucent)
                            }
                            .buttonStyle(.plain)

                            Button {
                                // Settings action placeholder
                            } label: {
                                ActionChip(icon: "gearshape.fill", title: "الإعدادات", style: .translucent)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        // Participant: enroll / unenroll button
                        if isRegistrationLocked && !isEnrolled {
                            HStack(spacing: 10) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(.white.opacity(0.7))
                                Text("التسجيل مغلق")
                                    .font(.appBody)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                            .font(.appBodySemibold)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.gray.opacity(0.4))
                            )
                        } else if hasPendingPayment {
                            VStack(spacing: 10) {
                                HStack(spacing: 10) {
                                    Image(systemName: "hourglass")
                                        .foregroundStyle(.yellow)
                                    Text("بانتظار تأكيد صاحب الحدث")
                                        .font(.appBody)
                                        .foregroundStyle(.white)
                                }
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .background(
                                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        .fill(Color.yellow.opacity(0.25))
                                )
                                Button {
                                    handleCancelPending()
                                } label: {
                                    HStack(spacing: 6) {
                                        if isCancellingPending { ProgressView().tint(.white) }
                                        Text("إلغاء الطلب")
                                            .font(.appCaption)
                                            .foregroundStyle(.white.opacity(0.85))
                                            .underline()
                                    }
                                }
                                .disabled(isCancellingPending)
                            }
                        } else {
                            Button {
                                if isEnrolled {
                                    handleLeaveEvent()
                                } else {
                                    showEnrollmentSheet = true
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    if isLeavingEvent {
                                        ProgressView()
                                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    } else {
                                        Image(systemName: isEnrolled ? "minus" : "plus")
                                            .foregroundStyle(isEnrolled ? Color.white : Color.black)
                                        Text(isEnrolled ? "اعتذار عن التمرين" : "سجل في التمرين")
                                            .font(.appBody)
                                            .foregroundStyle(isEnrolled ? Color.white : Color.black)
                                    }
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
                            .disabled(isLeavingEvent)
                            .sheet(isPresented: $showEnrollmentSheet) {
                                EnrollmentSheetView(
                                    event: event,
                                    onEnroll: {
                                        isEnrolled = true
                                        showEnrollmentSheet = false
                                        Task { await loadParticipants() }
                                        onEnroll()
                                    },
                                    onSubmittedPayment: { number in
                                        showEnrollmentSheet = false
                                        hasPendingPayment = true
                                        stcPaySheetNumber = number
                                        Task { await loadParticipants() }
                                    },
                                    onSeatsFull: {
                                        showEnrollmentSheet = false
                                        showWaitlistSheet = true
                                    }
                                )
                            }
                        }
                    }
                    
                    // Progress card (glass)
                    if let max = event.maxParticipants, max > 0 {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("نسبة اكتمال التمرين")
                                    .font(.appCallout)
                                    .foregroundStyle(.white)
                                Spacer()
                                Text("\(participants.count)/\(max)")
                                    .font(.appCallout)
                                    .foregroundStyle(.white.opacity(0.9))
                            }

                            ProgressView(value: Double(participants.count), total: Double(max))
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
                    }

                    // Participants list (glass rows)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("القائمة")
                                .font(.appBodySemibold)
                                .foregroundStyle(.white.opacity(0.9))
                            Spacer()
                            Text("\(participants.count)")
                                .font(.appBody)
                                .foregroundStyle(.white.opacity(0.6))
                        }

                        if participantsLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .frame(maxWidth: .infinity, minHeight: 60)
                        } else if participants.isEmpty {
                            Text("لا يوجد مشاركين بعد")
                                .font(.appBody)
                                .foregroundStyle(.white.opacity(0.5))
                                .frame(maxWidth: .infinity, minHeight: 60)
                        } else {
                            ForEach(participants) { participant in
                                HStack(spacing: 12) {
                                    if let avatarUrl = participant.avatarUrl, let url = URL(string: avatarUrl) {
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable().scaledToFill()
                                            default:
                                                Image(systemName: "person.crop.circle.fill")
                                                    .resizable().scaledToFit()
                                                    .foregroundStyle(.white.opacity(0.9))
                                            }
                                        }
                                        .frame(width: 38, height: 38)
                                        .clipShape(Circle())
                                    } else {
                                        Image(systemName: "person.crop.circle.fill")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 38, height: 38)
                                            .foregroundStyle(.white.opacity(0.9))
                                    }

                                    Text(participant.displayName ?? "مشارك")
                                        .font(.appBodyMedium)
                                        .foregroundStyle(.white)

                                    Spacer()

                                    if participant.userId == event.creatorId {
                                        Text("المنظم")
                                            .font(.appCaption)
                                            .foregroundStyle(.white.opacity(0.6))
                                    }
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
        .onAppear {
            Task {
                let client = SupabaseClientManager.shared.client
                currentUserId = try? await client.auth.session.user.id
                await loadParticipants()
            }
        }
        .sheet(isPresented: Binding(
            get: { stcPaySheetNumber != nil },
            set: { if !$0 { stcPaySheetNumber = nil } }
        )) {
            if let number = stcPaySheetNumber {
                STCPaySheet(eventName: event.name, amount: event.pricePerPerson, stcPayNumber: number)
            }
        }
        .sheet(isPresented: $showWaitlistSheet) {
            STCPayWaitlistSheet(eventName: event.name, onJoin: {
                guard let uid = currentUserId else { return }
                do {
                    try await STCPayService.shared.joinWaitlist(eventId: event.id, userId: uid)
                } catch {
                    print("[Waitlist] Error — \(error.localizedDescription)")
                }
            })
        }
    }

    private func loadParticipants() async {
        participantsLoading = true
        defer { participantsLoading = false }
        do {
            participants = try await EventService.shared.getEventParticipants(eventId: event.id)
            if let uid = currentUserId, let mine = participants.first(where: { $0.userId == uid }) {
                isEnrolled = mine.isConfirmed
                hasPendingPayment = mine.isPending
            } else {
                isEnrolled = false
                hasPendingPayment = false
            }
        } catch {
            print("[Participants] Error — \(error.localizedDescription)")
        }
    }

    private func handleLeaveEvent() {
        isLeavingEvent = true
        Task {
            defer { isLeavingEvent = false }
            do {
                try await EventService.shared.leaveEvent(eventId: event.id)
                isEnrolled = false
                await loadParticipants()
            } catch {
                print("[LeaveEvent] Error — \(error.localizedDescription)")
            }
        }
    }

    private func handleCancelPending() {
        guard let uid = currentUserId else { return }
        isCancellingPending = true
        Task {
            defer { isCancellingPending = false }
            do {
                _ = try await STCPayService.shared.cancelPending(eventId: event.id, userId: uid)
                hasPendingPayment = false
                await loadParticipants()
            } catch {
                print("[CancelPending] Error — \(error.localizedDescription)")
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
    var onSubmittedPayment: ((String) -> Void)? = nil
    var onSeatsFull: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var currentPage: Int = 0
    @State private var isNameSelected: Bool = false
    @State private var showAddParticipant: Bool = false
    @State private var newParticipantName: String = ""
    @State private var participants: [String] = []
    @State private var isProcessingPayment = false
    @State private var paymentError: String?
    
    // Sample events for preview (including current event in the middle)
    private var allEvents: [EventData] {
        [
            EventData(id: UUID(), name: "اسم الفعالية", date: "يوم الثلاثاء، الساعة 6:00 م", imageUrl: nil),
            event,
            EventData(id: UUID(), name: "التمرين", date: "يوم الاثنين", imageUrl: nil)
        ]
    }
    
    // Current user
    private let userName = "محمد معلا"

    private var enrollmentEventImage: some View {
        Group {
            if let resource = EventData.imageResource(for: event.imageUrl) {
                Image(resource).resizable().scaledToFill()
            } else if let urlString = event.imageUrl,
                      urlString.hasPrefix("http"),
                      let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure, .empty: Image(.card1).resizable().scaledToFill()
                    @unknown default: Image(.card1).resizable().scaledToFill()
                    }
                }
            } else {
                Image(.card1).resizable().scaledToFill()
            }
        }
    }
    
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
                            enrollmentEventImage
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

                            if event.pricePerPerson > 0 {
                                HStack(spacing: 6) {
                                    Image(systemName: "creditcard.fill")
                                        .foregroundStyle(.white.opacity(0.8))
                                    Text(String(format: "%.0f ر.س / شخص", event.pricePerPerson))
                                        .font(.appBodySemibold)
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.white.opacity(0.12))
                                )
                            }

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
                    VStack(spacing: 8) {
                        Button {
                            handleEnroll()
                        } label: {
                            HStack(spacing: 8) {
                                if isProcessingPayment {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    if event.pricePerPerson > 0 {
                                        Image(systemName: "creditcard.fill")
                                            .foregroundStyle(.white)
                                    }
                                    Text(event.pricePerPerson > 0 ? "ادفع عبر STC Pay" : "سجل")
                                        .font(.appBodySemibold)
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(isNameSelected ? Color.blue : Color.blue.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
                            .shadow(color: isNameSelected ? .black.opacity(0.3) : .clear, radius: 8, y: 4)
                        }
                        .disabled(!isNameSelected || isProcessingPayment)

                        if let paymentError {
                            Text(paymentError)
                                .font(.appCaption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func handleEnroll() {
        if event.pricePerPerson > 0 {
            isProcessingPayment = true
            paymentError = nil
            Task {
                defer { isProcessingPayment = false }
                do {
                    let session = try await SupabaseClientManager.shared.client.auth.session
                    let result = try await STCPayService.shared.submitPayment(
                        eventId: event.id,
                        userId: session.user.id
                    )
                    switch result {
                    case .submitted(_, let number):
                        onSubmittedPayment?(number)
                        dismiss()
                    case .seatsFull:
                        onSeatsFull?()
                        dismiss()
                    case .alreadyJoined(let status):
                        switch status {
                        case .confirmed: paymentError = "أنت مسجل بالفعل في هذه الفعالية"
                        case .pending: paymentError = "لديك طلب دفع قيد التأكيد"
                        case .rejected: paymentError = "تم رفض طلبك سابقاً"
                        }
                    case .creatorMissingNumber:
                        paymentError = "صاحب الفعالية لم يضف رقم STC Pay بعد"
                    case .registrationClosed:
                        paymentError = "التسجيل مغلق لهذه الفعالية"
                    }
                } catch {
                    paymentError = error.localizedDescription
                }
            }
        } else {
            onEnroll()
            dismiss()
        }
    }
}
