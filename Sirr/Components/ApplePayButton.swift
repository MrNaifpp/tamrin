//
//  ApplePayButton.swift
//  Sirr
//
//  Apple Pay through Moyasar. PassKit collects the token; the SDK sends it to
//  Moyasar with the same manual (authorize-only) request the card form uses,
//  so verify-payment is the gate for both and the device never decides that a
//  seat is paid.
//

import SwiftUI
import PassKit
import MoyasarSdk

struct ApplePayButton: View {
    let quote: CardPaymentQuote
    let eventName: String
    let onResult: (CardPaymentOutcome) -> Void

    /// Set from APPLE_PAY_MERCHANT_ID in Config/Base.xcconfig, through the
    /// ApplePayMerchantID placeholder in Info.plist. Absent or unsubstituted
    /// means Apple Pay is not configured in this build, and the button hides
    /// rather than failing at the moment of payment.
    static var merchantIdentifier: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "ApplePayMerchantID") as? String,
              !id.isEmpty, !id.hasPrefix("$(") else { return nil }
        return id
    }

    /// Apple's own rule for whether to show the button: ask whether the device
    /// can pay at all. `canMakePayments(usingNetworks:)` answers a different
    /// question, whether a card is already in Wallet, and hiding the button on
    /// that would leave someone with an empty Wallet no way in. PassKit takes
    /// them to add a card instead.
    static var isAvailable: Bool {
        merchantIdentifier != nil && PKPaymentAuthorizationController.canMakePayments()
    }

    var body: some View {
        PayWithApplePayButton(.plain) {
            present()
        }
        .payWithApplePayButtonStyle(.white)
        .frame(height: 48)
        .clipShape(.rect(cornerRadius: 17, style: .continuous))
    }

    private func present() {
        guard let merchant = Self.merchantIdentifier else {
            onResult(.failed("الدفع عبر Apple Pay غير مهيأ في هذه النسخة."))
            return
        }

        let request: PaymentRequest
        do {
            request = try quote.paymentRequest()
        } catch {
            onResult(.failed("تعذر تجهيز الدفع. حاول مرة أخرى."))
            return
        }

        let pk = PKPaymentRequest()
        pk.merchantIdentifier = merchant
        pk.countryCode = "SA"
        pk.currencyCode = quote.currency
        pk.supportedNetworks = [.visa, .masterCard, .mada]
        pk.merchantCapabilities = [.threeDSecure, .credit, .debit]
        pk.paymentSummaryItems = [
            PKPaymentSummaryItem(
                label: "تمرين: \(eventName)",
                amount: NSDecimalNumber(value: quote.amountInRiyals),
                type: .final
            )
        ]

        let controller = PKPaymentAuthorizationController(paymentRequest: pk)
        let delegate = Delegate(request: request, onResult: onResult)
        controller.delegate = delegate
        Delegate.retained = delegate
        controller.present { presented in
            guard !presented else { return }
            // Wallet could not open the sheet. Say so rather than leaving a
            // tap that appears to do nothing.
            Delegate.retained = nil
            DispatchQueue.main.async {
                onResult(.failed("تعذر فتح Apple Pay. تأكد من إضافة بطاقة في Wallet."))
            }
        }
    }

    private final class Delegate: NSObject, PKPaymentAuthorizationControllerDelegate {
        /// PassKit does not retain its delegate, and the controller is created
        /// inside a struct that is gone by the time Apple Pay answers.
        static var retained: Delegate?

        let request: PaymentRequest
        let onResult: (CardPaymentOutcome) -> Void
        private var settled: CardPaymentOutcome?

        init(request: PaymentRequest, onResult: @escaping (CardPaymentOutcome) -> Void) {
            self.request = request
            self.onResult = onResult
        }

        func paymentAuthorizationController(
            _ controller: PKPaymentAuthorizationController,
            didAuthorizePayment payment: PKPayment,
            handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
        ) {
            Task {
                do {
                    let service = try ApplePayService(apiKey: request.apiKey)
                    let api = try await service.authorizePayment(request: request, token: payment.token)
                    switch api.status {
                    case .paid, .authorized, .initiated, .captured:
                        settled = .authorized(moyasarPaymentId: api.id)
                        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
                    default:
                        settled = .failed("لم تنجح عملية الدفع. حاول مرة أخرى.")
                        completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
                    }
                } catch {
                    settled = .failed("لم تنجح عملية الدفع. حاول مرة أخرى.")
                    completion(PKPaymentAuthorizationResult(status: .failure, errors: [error]))
                }
            }
        }

        func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
            controller.dismiss {
                DispatchQueue.main.async {
                    // Nothing recorded means the sheet was dismissed without
                    // authorizing, which is a cancellation, not a failure.
                    self.onResult(self.settled ?? .cancelled)
                    Delegate.retained = nil
                }
            }
        }
    }
}
