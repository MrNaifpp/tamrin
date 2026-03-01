//
//  PaymentService.swift
//  Sirr
//
//  Apple Pay payment flow for event joining.
//

import Foundation
import PassKit
import os

private let paymentLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "PaymentService")

final class PaymentService: NSObject {
    static let shared = PaymentService()

    private static let merchantIdentifier = "merchant.businessech.com.test"
    private static let countryCode = "SA"
    private static let currencyCode = "SAR"

    private var paymentContinuation: CheckedContinuation<Bool, Never>?
    private var didAuthorize = false

    static var isApplePayAvailable: Bool {
        PKPaymentAuthorizationController.canMakePayments()
    }

    /// Present Apple Pay sheet and return `true` if the user authorized the payment.
    @MainActor
    func requestPayment(amount: Double, eventName: String) async -> Bool {
        let canPay = PKPaymentAuthorizationController.canMakePayments()
        let canPayNetworks = PKPaymentAuthorizationController.canMakePayments(
            usingNetworks: [.visa, .masterCard, .mada],
            capabilities: .threeDSecure
        )
        paymentLogger.info("Apple Pay check — canMakePayments: \(canPay), withNetworks: \(canPayNetworks), amount: \(amount)")

        guard canPay else {
            paymentLogger.warning("Apple Pay not available on this device at all")
            return false
        }

        let item = PKPaymentSummaryItem(label: eventName, amount: NSDecimalNumber(value: amount))
        let total = PKPaymentSummaryItem(label: "Sirr", amount: NSDecimalNumber(value: amount))

        let request = PKPaymentRequest()
        request.merchantIdentifier = Self.merchantIdentifier
        request.supportedNetworks = [.visa, .masterCard, .mada]
        request.merchantCapabilities = .threeDSecure
        request.countryCode = Self.countryCode
        request.currencyCode = Self.currencyCode
        request.paymentSummaryItems = [item, total]

        return await withCheckedContinuation { continuation in
            self.didAuthorize = false
            self.paymentContinuation = continuation
            let controller = PKPaymentAuthorizationController(paymentRequest: request)
            controller.delegate = self
            controller.present { presented in
                paymentLogger.info("Apple Pay sheet presented: \(presented)")
                if !presented {
                    paymentLogger.error("Failed to present Apple Pay sheet")
                    self.paymentContinuation?.resume(returning: false)
                    self.paymentContinuation = nil
                }
            }
        }
    }
}

// MARK: - PKPaymentAuthorizationControllerDelegate
extension PaymentService: PKPaymentAuthorizationControllerDelegate {
    func paymentAuthorizationController(
        _ controller: PKPaymentAuthorizationController,
        didAuthorizePayment payment: PKPayment,
        handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
    ) {
        // In production, send payment.token to your payment gateway (e.g. Stripe).
        // For now we treat every authorization as successful.
        paymentLogger.info("Apple Pay authorized")
        didAuthorize = true
        completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
    }

    func paymentAuthorizationControllerDidFinish(_ controller: PKPaymentAuthorizationController) {
        controller.dismiss {
            let success = self.didAuthorize
            if !success { paymentLogger.info("Apple Pay cancelled by user") }
            self.paymentContinuation?.resume(returning: success)
            self.paymentContinuation = nil
        }
    }
}
