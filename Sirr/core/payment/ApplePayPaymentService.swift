//
//  ApplePayPaymentService.swift
//  Sirr
//
//  Typed client for the two payment Edge Functions. The app never talks to
//  MyFatoorah: it asks the server what is owed, shows Apple's sheet for that
//  amount, and hands the token Apple returns to the server, which charges it
//  with a key the app never holds. The server's answer is the word that counts.
//

import Foundation
import PassKit
import Supabase
import os

private let paymentLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Sirr",
    category: "ApplePayPaymentService"
)

final class ApplePayPaymentService {
    static let shared = ApplePayPaymentService()

    private let client = SupabaseClientManager.shared.client
    private let decoder = JSONDecoder()

    private init() {}

    private struct StartEnvelope: Decodable {
        let status: String
    }

    private struct PayEnvelope: Decodable {
        let status: String
        let reason: String?
    }

    func startPayment(eventId: UUID) async throws -> CardPaymentStart {
        let data = try await invoke(
            "create-payment",
            body: ["event_id": eventId.uuidString.lowercased()]
        )
        let envelope = try decoder.decode(StartEnvelope.self, from: data)
        paymentLogger.info("create-payment -> \(envelope.status, privacy: .public)")
        switch envelope.status {
        case "ready": return .ready(try decoder.decode(CardPaymentQuote.self, from: data))
        case "free_event": return .freeEvent
        case "nothing_due": return .nothingDue
        case "already_paid": return .alreadyPaid
        case "event_closed": return .eventClosed
        case "processing": return .processing
        default: throw ApplePayPaymentServiceError.malformedResponse
        }
    }

    /// Sends Apple's token to the server, which charges exactly the amount it
    /// quoted. Only the server's answer decides whether the seat is paid.
    func pay(paymentId: UUID, token: PKPaymentToken) async throws -> CardPaymentVerification {
        let body = PayBody(
            payment_id: paymentId.uuidString.lowercased(),
            token: try ApplePayToken(token)
        )
        let data = try await invoke("pay-apple-pay", body: body)
        let envelope = try decoder.decode(PayEnvelope.self, from: data)
        paymentLogger.info("pay-apple-pay -> \(envelope.status, privacy: .public)")
        switch envelope.status {
        case "paid": return .paid
        case "processing": return .processing
        default: return .failed(reason: envelope.reason)
        }
    }

    private func invoke(_ name: String, body: some Encodable) async throws -> Data {
        do {
            return try await client.functions.invoke(
                name,
                options: FunctionInvokeOptions(body: body)
            ) { data, response in
                guard (200..<300).contains(response.statusCode) else {
                    throw ApplePayPaymentServiceError.http(
                        response.statusCode,
                        String(data: data, encoding: .utf8) ?? ""
                    )
                }
                return data
            }
        } catch let error as ApplePayPaymentServiceError {
            throw error
        } catch let error as FunctionsError {
            if case let .httpError(code, data) = error {
                throw ApplePayPaymentServiceError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            throw error
        }
    }
}

// MARK: - Wire shape for pay-apple-pay

private struct PayBody: Encodable {
    let payment_id: String
    let token: ApplePayToken
}

/// The PKPaymentToken in the shape MyFatoorah's Apple Pay endpoint takes:
/// `{ PaymentData, PaymentMethod, TransactionIdentifier }`, with PaymentData
/// being Apple's encrypted payload as a JSON object, untouched.
private struct ApplePayToken: Encodable {
    struct Header: Codable {
        let ephemeralPublicKey: String?
        let publicKeyHash: String
        let transactionId: String
        let wrappedKey: String?
    }

    struct EncryptedData: Codable {
        let version: String
        let data: String
        let signature: String
        let header: Header
    }

    struct Method: Encodable {
        let displayName: String
        let network: String
        let type: String
    }

    let encrypted: EncryptedData
    let method: Method
    let transactionIdentifier: String

    enum CodingKeys: String, CodingKey {
        case encrypted = "PaymentData"
        case method = "PaymentMethod"
        case transactionIdentifier = "TransactionIdentifier"
    }

    init(_ token: PKPaymentToken) throws {
        encrypted = try JSONDecoder().decode(EncryptedData.self, from: token.paymentData)
        method = Method(
            displayName: token.paymentMethod.displayName ?? "",
            network: token.paymentMethod.network?.rawValue ?? "",
            type: Self.typeName(token.paymentMethod.type)
        )
        transactionIdentifier = token.transactionIdentifier
    }

    private static func typeName(_ type: PKPaymentMethodType) -> String {
        switch type {
        case .debit: "debit"
        case .credit: "credit"
        case .prepaid: "prepaid"
        case .store: "store"
        case .eMoney: "emoney"
        default: "unknown"
        }
    }
}
