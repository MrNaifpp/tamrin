//
//  MoyasarPaymentService.swift
//  Sirr
//
//  Typed client for the two card-payment Edge Functions. The app never talks
//  to Moyasar with anything but the publishable key the server hands back, and
//  never treats an SDK result as final — verify() is the word that counts.
//

import Foundation
import Supabase
import os

private let moyasarLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Sirr",
    category: "MoyasarPaymentService"
)

final class MoyasarPaymentService {
    static let shared = MoyasarPaymentService()

    private let client = SupabaseClientManager.shared.client
    private let decoder = JSONDecoder()

    private init() {}

    private struct StartEnvelope: Decodable {
        let status: String
    }

    private struct VerifyEnvelope: Decodable {
        let status: String
        let reason: String?
    }

    func startPayment(eventId: UUID) async throws -> CardPaymentStart {
        let data = try await invoke(
            "create-payment",
            body: ["event_id": eventId.uuidString.lowercased()]
        )
        let envelope = try decoder.decode(StartEnvelope.self, from: data)
        moyasarLogger.info("create-payment -> \(envelope.status, privacy: .public)")
        switch envelope.status {
        case "ready": return .ready(try decoder.decode(CardPaymentQuote.self, from: data))
        case "free_event": return .freeEvent
        case "nothing_due": return .nothingDue
        case "already_paid": return .alreadyPaid
        case "recipient_not_onboarded": return .recipientNotOnboarded
        case "event_closed": return .eventClosed
        default: throw MoyasarPaymentServiceError.malformedResponse
        }
    }

    func verify(paymentId: UUID, moyasarPaymentId: String) async throws -> CardPaymentVerification {
        let data = try await invoke(
            "verify-payment",
            body: [
                "payment_id": paymentId.uuidString.lowercased(),
                "moyasar_payment_id": moyasarPaymentId
            ]
        )
        let envelope = try decoder.decode(VerifyEnvelope.self, from: data)
        moyasarLogger.info("verify-payment -> \(envelope.status, privacy: .public)")
        switch envelope.status {
        case "paid": return .paid
        case "processing": return .processing
        default: return .failed(reason: envelope.reason)
        }
    }

    private func invoke(_ name: String, body: [String: String]) async throws -> Data {
        do {
            return try await client.functions.invoke(
                name,
                options: FunctionInvokeOptions(body: body)
            ) { data, response in
                guard (200..<300).contains(response.statusCode) else {
                    throw MoyasarPaymentServiceError.http(
                        response.statusCode,
                        String(data: data, encoding: .utf8) ?? ""
                    )
                }
                return data
            }
        } catch let error as MoyasarPaymentServiceError {
            throw error
        } catch let error as FunctionsError {
            if case let .httpError(code, data) = error {
                throw MoyasarPaymentServiceError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            throw error
        }
    }
}
