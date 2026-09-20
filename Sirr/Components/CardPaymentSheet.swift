//
//  CardPaymentSheet.swift
//  Sirr
//
//  Card payment through Moyasar. Asks the server for the quote, shows the
//  SDK's Arabic card form with manual (authorize-only) mode, then asks the
//  server to verify. The SDK saying "paid" moves us to a spinner, not to a
//  tick: only verify-payment ends in success.
//

import SwiftUI
import MoyasarSdk

struct CardPaymentSheet: View {
    let eventId: UUID
    let eventName: String
    let onSettled: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var quote: CardPaymentQuote?
    @State private var request: PaymentRequest?
    @State private var state: CardPaymentState = .idle
    @State private var loadError: String?

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                switch state {
                case .idle:
                    if let request, let quote {
                        amountCard(quote)
                        CreditCardView(request: request) { result in
                            handle(result, quote: quote)
                        }
                        .padding(.horizontal, 16)
                    } else if let loadError {
                        statusView(icon: "exclamationmark.triangle", title: loadError, tint: .orange)
                    } else {
                        ProgressView().tint(.white).padding(.top, 60)
                    }
                case .processing:
                    statusView(icon: "hourglass", title: "نتحقق من الدفع…", tint: .white, spinning: true)
                case .success:
                    statusView(icon: "checkmark.circle.fill", title: "تم الدفع وتأكد مقعدك", tint: .green)
                case .failed(let message):
                    statusView(icon: "xmark.circle.fill", title: message, tint: .red)
                    retryButton
                case .cancelled:
                    statusView(icon: "arrow.uturn.backward.circle", title: "ألغيت عملية الدفع", tint: .white.opacity(0.7))
                    retryButton
                }
                Spacer()
            }
        }
        .task { await load() }
        .interactiveDismissDisabled(state == .processing)
    }

    private var header: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
            .disabled(state == .processing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func amountCard(_ quote: CardPaymentQuote) -> some View {
        VStack(spacing: 4) {
            Text("الدفع بالبطاقة")
                .font(TamrinFont.font(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text(eventName)
                .font(TamrinFont.font(size: 15))
                .foregroundStyle(Color(white: 0.7))
            Text(quote.amountInRiyals.formatted(.number.precision(.fractionLength(0...2))) + " ريال")
                .font(TamrinFont.font(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 8)
            if quote.seatCount > 1 {
                Text("لعدد \(quote.seatCount.counted(.player))")
                    .font(TamrinFont.font(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.48))
            }
        }
        .padding(.vertical, 20)
    }

    private func statusView(icon: String, title: String, tint: Color, spinning: Bool = false) -> some View {
        VStack(spacing: 14) {
            if spinning {
                ProgressView().tint(tint).scaleEffect(1.4)
            } else {
                Image(systemName: icon).font(.system(size: 44)).foregroundStyle(tint)
            }
            Text(title)
                .font(TamrinFont.font(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    private var retryButton: some View {
        Button {
            state = .idle
            Task { await load() }
        } label: {
            Text("حاول مرة أخرى")
                .font(TamrinFont.font(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(.white, in: .rect(cornerRadius: 17, style: .continuous))
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    private func load() async {
        loadError = nil
        do {
            switch try await MoyasarPaymentService.shared.startPayment(eventId: eventId) {
            case .ready(let q):
                quote = q
                request = try PaymentRequest(
                    apiKey: q.publishableKey,
                    amount: q.amount,
                    currency: q.currency,
                    description: q.description,
                    metadata: q.metadata.mapValues { MetadataValue.stringValue($0) },
                    manual: true,
                    givenID: q.givenId.uuidString.lowercased(),
                    allowedNetworks: [.mada, .visa, .mastercard],
                    payButtonType: .pay,
                    splits: q.splits.map {
                        PaymentSplit(
                            recipientId: $0.recipientId,
                            amount: $0.amount,
                            recipientType: $0.recipientType,
                            feeSource: $0.feeSource,
                            refundable: $0.refundable
                        )
                    }
                )
            case .alreadyPaid:
                state = .success
            case .freeEvent, .nothingDue:
                loadError = "لا يوجد مبلغ مستحق على هذا الموعد."
            case .recipientNotOnboarded:
                loadError = "الدفع بالبطاقة غير متاح لهذه المجموعة بعد."
            case .eventClosed:
                loadError = "أُغلق التسجيل لهذا الموعد."
            }
        } catch {
            loadError = ServerErrorMessage.arabic(for: error)
        }
    }

    private func handle(_ result: PaymentResult, quote: CardPaymentQuote) {
        switch result {
        case .completed(let payment):
            // Authorized or paid on Moyasar's side — the server decides which
            // of those becomes a seat.
            state = .processing
            Task { await verify(moyasarPaymentId: payment.id, paymentId: quote.paymentId) }
        case .failed(let error):
            Haptics.error()
            state = .failed(error.localizedDescription.isEmpty
                            ? "لم تنجح عملية الدفع. تحقق من البطاقة وحاول مرة أخرى."
                            : error.localizedDescription)
        case .canceled:
            state = .cancelled
        case .saveOnlyToken:
            // Not requested (createSaveOnlyToken is false); nothing was charged.
            state = .failed("لم تنجح عملية الدفع.")
        }
    }

    private func verify(moyasarPaymentId: String, paymentId: UUID) async {
        do {
            for attempt in 0..<4 {
                switch try await MoyasarPaymentService.shared.verify(
                    paymentId: paymentId, moyasarPaymentId: moyasarPaymentId
                ) {
                case .paid:
                    Haptics.success()
                    state = .success
                    onSettled()
                    return
                case .processing:
                    try await Task.sleep(for: .seconds(1 + attempt))
                case .failed(let reason):
                    Haptics.error()
                    state = .failed(reason == "amount" || reason == "recipient"
                                    ? "تعذر التحقق من الدفع. لم يُخصم أي مبلغ."
                                    : "لم تنجح عملية الدفع.")
                    return
                }
            }
            state = .failed("تأخر التحقق من الدفع. سيتأكد مقعدك تلقائيًا عند وصول التأكيد.")
        } catch {
            state = .failed(ServerErrorMessage.arabic(for: error))
        }
    }
}
