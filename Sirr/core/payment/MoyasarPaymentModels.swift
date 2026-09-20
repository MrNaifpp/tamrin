//
//  MoyasarPaymentModels.swift
//  Sirr
//
//  Wire shapes for the create-payment / verify-payment Edge Functions, and the
//  four states the card sheet can show. Nothing here decides an outcome — the
//  server does, and the sheet renders what it says.
//

import Foundation

struct CardPaymentSplit: Decodable, Equatable {
    let recipientId: String
    let recipientType: String?
    let amount: Int
    let feeSource: Bool
    let refundable: Bool

    enum CodingKeys: String, CodingKey {
        case recipientId = "recipient_id"
        case recipientType = "recipient_type"
        case amount
        case feeSource = "fee_source"
        case refundable
    }
}

struct CardPaymentQuote: Decodable, Equatable {
    let paymentId: UUID
    let givenId: UUID
    let amount: Int
    let currency: String
    let seatCount: Int
    let publishableKey: String
    let description: String
    let metadata: [String: String]
    let splits: [CardPaymentSplit]

    enum CodingKeys: String, CodingKey {
        case paymentId = "payment_id"
        case givenId = "given_id"
        case amount, currency
        case seatCount = "seat_count"
        case publishableKey = "publishable_key"
        case description, metadata, splits
    }

    /// Halalas → riyals for display only. Never sent anywhere.
    var amountInRiyals: Double { Double(amount) / 100 }
}

enum CardPaymentStart: Equatable {
    case ready(CardPaymentQuote)
    case freeEvent
    case nothingDue
    case alreadyPaid
    case recipientNotOnboarded
    case eventClosed
}

enum CardPaymentVerification: Equatable {
    case paid
    case processing
    case failed(reason: String?)
}

/// What the sheet shows. `processing` covers both "SDK is talking to Moyasar"
/// and "we are asking the server"; the person sees one spinner either way.
enum CardPaymentState: Equatable {
    case idle
    case processing
    case success
    case failed(String)
    case cancelled
}

enum MoyasarPaymentServiceError: Error, LocalizedError {
    case malformedResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse: "تعذر قراءة رد الخادم."
        case .http(401, _): "انتهت الجلسة. سجّل الدخول مرة أخرى."
        case .http: ServerErrorMessage.general
        }
    }
}
