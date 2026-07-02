//
//  SharedEventView.swift
//  Sirr
//
//  Shows event details when opened via deep link (sirr://event/<id>).
//  Anyone with the link can view; joining requires login.
//

import SwiftUI
import Supabase

struct SharedEventView: View {
    let eventId: UUID
    let isLoggedIn: Bool
    var onDismiss: () -> Void
    var onRequestLogin: () -> Void

    @State private var event: EventData?
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isJoining = false
    @State private var joinSuccess = false
    @State private var joinError: String?
    @State private var hasPendingPayment = false
    @State private var stcPaySheetNumber: String?
    @State private var showWaitlistSheet = false

    var body: some View {
        ZStack {
            if !isLoggedIn {
                loginPromptView
            } else if isLoading {
                loadingView
            } else if let errorMessage {
                errorView(errorMessage)
            } else if let event {
                eventDetailView(event)
            }
        }
        .task {
            guard isLoggedIn else { return }
            await loadEvent()
            await refreshOwnStatus()
        }
        .sheet(isPresented: Binding(
            get: { stcPaySheetNumber != nil },
            set: { if !$0 { stcPaySheetNumber = nil } }
        )) {
            if let number = stcPaySheetNumber, let event {
                STCPaySheet(eventName: event.name, amount: event.pricePerPerson, stcPayNumber: number)
            }
        }
        .sheet(isPresented: $showWaitlistSheet) {
            if let event {
                STCPayWaitlistSheet(eventName: event.name, onJoin: {
                    await joinWaitlistAction(event)
                })
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.3)
                Text("جاري تحميل الفعالية...")
                    .font(.appBody)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    // MARK: - Login Prompt (logged-out users)

    private var loginPromptView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                Text("سجّل الدخول لعرض هذا الحدث")
                    .font(.appBody)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button {
                    onRequestLogin()
                } label: {
                    Text("تسجيل الدخول")
                        .font(.appBodySemibold)
                        .foregroundStyle(.black)
                        .frame(width: 160, height: 48)
                        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white))
                }
                Button {
                    onDismiss()
                } label: {
                    Text("رجوع")
                        .font(.appBodySemibold)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(32)
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.appBody)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Button {
                    onDismiss()
                } label: {
                    Text("رجوع")
                        .font(.appBodySemibold)
                        .foregroundStyle(.black)
                        .frame(width: 160, height: 48)
                        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.white))
                }
            }
            .padding(32)
        }
    }

    // MARK: - Event Detail

    private func eventDetailView(_ event: EventData) -> some View {
        ZStack(alignment: .top) {
            backgroundImage(for: event)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Close button
                HStack {
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                // Content card
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text(event.name)
                            .font(.appLargeTitle)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text(event.date)
                            .font(.appBodySemibold)
                            .foregroundStyle(.white.opacity(0.9))
                    }

                    // Price badge
                    if event.pricePerPerson > 0 && !joinSuccess {
                        HStack(spacing: 6) {
                            Image(systemName: "creditcard.fill")
                                .foregroundStyle(.white.opacity(0.8))
                            Text(String(format: "%.0f ر.س / شخص", event.pricePerPerson))
                                .font(.appBody)
                                .foregroundStyle(.white.opacity(0.9))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.12))
                        )
                    }

                    // Join / status area
                    if joinSuccess {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("تم التسجيل بنجاح")
                                .font(.appBodySemibold)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity, minHeight: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.green.opacity(0.3))
                        )
                    } else if hasPendingPayment {
                        VStack(spacing: 10) {
                            HStack(spacing: 10) {
                                Image(systemName: "hourglass")
                                    .foregroundStyle(.yellow)
                                Text("بانتظار تأكيد صاحب الحدث")
                                    .font(.appBodySemibold)
                                    .foregroundStyle(.white)
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.yellow.opacity(0.25))
                            )
                            Button {
                                cancelPendingAction(event)
                            } label: {
                                Text("إلغاء الطلب")
                                    .font(.appCaption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .underline()
                            }
                            .disabled(isJoining)
                        }
                    } else if event.registrationLocked {
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
                    } else {
                        Button {
                            if !isLoggedIn {
                                onRequestLogin()
                                return
                            }
                            joinEventAction(event)
                        } label: {
                            HStack(spacing: 10) {
                                if isJoining {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                } else {
                                    Image(systemName: event.pricePerPerson > 0 ? "creditcard.fill" : "plus")
                                        .foregroundStyle(.black)
                                    Text(event.pricePerPerson > 0 ? "ادفع عبر STC Pay" : "انضم للتمرين")
                                        .font(.appBody)
                                        .foregroundStyle(.black)
                                }
                            }
                            .font(.appBodySemibold)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color.white)
                                    .shadow(color: .black.opacity(0.35), radius: 8, y: 8)
                            )
                        }
                        .disabled(isJoining)
                    }

                    if let joinError {
                        Text(joinError)
                            .font(.appCaption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 60)
            }
        }
    }

    // MARK: - Background

    private func backgroundImage(for event: EventData) -> some View {
        GeometryReader { proxy in
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
            .frame(width: proxy.size.width, height: proxy.size.height)
            .blur(radius: 14)
            .overlay(Color.black.opacity(0.4))
        }
    }

    // MARK: - Actions

    private func loadEvent() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let record = try await EventService.shared.getEventById(eventId)
            event = EventData.from(record: record)
        } catch {
            errorMessage = "هذا الحدث في مساحة خاصة.\nاطلب دعوة من صاحب المساحة للانضمام."
        }
    }

    private func joinEventAction(_ event: EventData) {
        isJoining = true
        joinError = nil
        Task {
            defer { isJoining = false }

            if event.pricePerPerson > 0 {
                await submitSTCPayPayment(for: event)
            } else {
                do {
                    try await EventService.shared.joinEvent(eventId: event.id)
                    joinSuccess = true
                } catch {
                    let msg = error.localizedDescription
                    if msg.contains("closed") || msg.contains("locked") {
                        joinError = "التسجيل مغلق لهذه الفعالية"
                    } else {
                        joinError = "فشل في الانضمام: \(msg)"
                    }
                }
            }
        }
    }

    private func submitSTCPayPayment(for event: EventData) async {
        do {
            let session = try await SupabaseClientManager.shared.client.auth.session
            let userId = session.user.id
            let result = try await STCPayService.shared.submitPayment(eventId: event.id, userId: userId)
            switch result {
            case .submitted(_, let number, _):
                hasPendingPayment = true
                stcPaySheetNumber = number
            case .seatsFull:
                showWaitlistSheet = true
            case .alreadyJoined(let status):
                if status == .confirmed { joinSuccess = true }
                else if status == .pending { hasPendingPayment = true }
                else { joinError = "أنت مسجل بالفعل في هذه الفعالية" }
            case .creatorMissingNumber:
                joinError = "صاحب الفعالية لم يضف رقم STC Pay بعد"
            case .registrationClosed:
                joinError = "التسجيل مغلق لهذه الفعالية"
            }
        } catch {
            joinError = "فشل في الانضمام: \(error.localizedDescription)"
        }
    }

    private func cancelPendingAction(_ event: EventData) {
        isJoining = true
        joinError = nil
        Task {
            defer { isJoining = false }
            do {
                let session = try await SupabaseClientManager.shared.client.auth.session
                _ = try await STCPayService.shared.cancelPending(eventId: event.id, userId: session.user.id)
                hasPendingPayment = false
            } catch {
                joinError = "تعذر إلغاء الطلب"
            }
        }
    }

    private func joinWaitlistAction(_ event: EventData) async {
        do {
            let session = try await SupabaseClientManager.shared.client.auth.session
            try await STCPayService.shared.joinWaitlist(eventId: event.id, userId: session.user.id)
        } catch {
            joinError = "تعذر الانضمام لقائمة الانتظار"
        }
    }

    /// Look up the current user's row in event_participants so we can show
    /// the pending pill or the confirmed pill when the view loads.
    private func refreshOwnStatus() async {
        guard isLoggedIn else { return }
        do {
            let session = try await SupabaseClientManager.shared.client.auth.session
            let participants = try await EventService.shared.getEventParticipants(eventId: eventId)
            if let mine = participants.first(where: { $0.userId == session.user.id && !$0.isGuest }) {
                if mine.isPending {
                    hasPendingPayment = true
                } else if mine.isConfirmed {
                    joinSuccess = true
                }
            }
        } catch {
            // Non-fatal — the join button will still work.
        }
    }
}
