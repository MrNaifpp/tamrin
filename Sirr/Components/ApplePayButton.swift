//
//  ApplePayButton.swift
//  Sirr
//
//  Apple Pay through Moyasar. PassKit collects the token; the SDK sends it to
//  Moyasar with the same manual (authorize-only) request the card form uses,
//  so verify-payment is the gate for both.
//

import SwiftUI
import PassKit
import MoyasarSdk

struct ApplePayButton: View {
    let request: PaymentRequest
    let quote: CardPaymentQuote
    let eventName: String
    let onResult: (PaymentResult) -> Void

    static var merchantIdentifier: String? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "ApplePayMerchantID") as? String,
              !id.isEmpty, !id.hasPrefix("$(") else { return nil }
        return id
    }

    static var isAvailable: Bool {
        merchantIdentifier != nil
            && PKPaymentAuthorizationController.canMakePayments(usingNetworks: [.visa, .masterCard, .mada])
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
        guard let merchant = Self.merchantIdentifier else { return }
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
        controller.present()
    }

    private final class Delegate: NSObject, PKPaymentAuthorizationControllerDelegate {
        static var retained: Delegate?
        let request: PaymentRequest
        let onResult: (PaymentResult) -> Void
        private var settled: PaymentResult?

        init(request: PaymentRequest, onResult: @escaping (PaymentResult) -> Void) {
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
                    case .paid, .authorized, .initiated:
                        settled = .completed(api)
                        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
                    default:
                        settled = .failed(MoyasarError.unexpectedError("status \(api.status.rawValue)"))
                        completion(PKPaymentAuthorizationResult(status: .failure, errors: nil))
                    }
                } catch {
                    settled = .failed(error as? MoyasarError ?? .unexpectedError(error.localizedDescription))
                    completion(PKPaymentAuthorizationResult(status: .failure, errors: [error]))
                }
            }
        }

        func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
            controller.dismiss {
                DispatchQueue.main.async {
                    self.onResult(self.settled ?? .canceled)
                    Delegate.retained = nil
                }
            }
        }
    }
}
