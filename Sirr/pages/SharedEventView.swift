//
//  SharedEventView.swift
//  Sirr
//
//  Shows event details when opened via deep link (sirr://event/<id>).
//  Anyone with the link can view; joining requires login.
//

import SwiftUI

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

    var body: some View {
        ZStack {
            if isLoading {
                loadingView
            } else if let errorMessage {
                errorView(errorMessage)
            } else if let event {
                eventDetailView(event)
            }
        }
        .task { await loadEvent() }
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
                                    Image(systemName: event.pricePerPerson > 0 ? "apple.logo" : "plus")
                                        .foregroundStyle(.black)
                                    Text(event.pricePerPerson > 0 ? "ادفع وانضم — Apple Pay" : "انضم للتمرين")
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
            errorMessage = "لم يتم العثور على الفعالية"
        }
    }

    private func joinEventAction(_ event: EventData) {
        isJoining = true
        joinError = nil
        Task {
            defer { isJoining = false }

            if event.pricePerPerson > 0 {
                let authorized = await PaymentService.shared.requestPayment(
                    amount: event.pricePerPerson,
                    eventName: event.name
                )
                guard authorized else {
                    joinError = "تم إلغاء الدفع"
                    return
                }
            }

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
