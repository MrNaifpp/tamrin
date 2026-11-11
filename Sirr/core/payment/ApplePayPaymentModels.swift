//
//  ApplePayPaymentModels.swift
//  Sirr
//
//  Wire shapes for the create-payment / pay-apple-pay Edge Functions, and the
//  outcomes the screens act on. Nothing here decides an outcome — the server
//  does, and the screens render what it says.
//

import Foundation

struct CardPaymentQuote: Decodable, Equatable {
    let paymentId: UUID
    let amount: Int
    let currency: String
    let seatCount: Int
    let eventName: String

    enum CodingKeys: String, CodingKey {
        case paymentId = "payment_id"
        case amount, currency
        case seatCount = "seat_count"
        case eventName = "event_name"
    }

    /// Halalas → riyals for display only. Never sent anywhere.
    var amountInRiyals: Double { Double(amount) / 100 }
}

enum CardPaymentStart: Equatable {
    case ready(CardPaymentQuote)
    case freeEvent
    case nothingDue
    case alreadyPaid
    case eventClosed
    /// An earlier payment for these seats is still being confirmed. The server
    /// will not open a second charge until it settles.
    case processing
}

enum CardPaymentVerification: Equatable {
    case paid
    case processing
    case failed(reason: String?)
}

enum ApplePayPaymentServiceError: Error, LocalizedError {
    case malformedResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .malformedResponse: String(localized: "تعذر قراءة رد الخادم.")
        case .http(401, _): String(localized: "انتهت الجلسة. سجّل الدخول مرة أخرى.")
        case .http: ServerErrorMessage.general
        }
    }
}

/// What an Apple Pay attempt came back as, after the server has spoken.
enum CardPaymentOutcome: Equatable {
    /// The server charged it and confirmed the seats.
    case paid
    /// The charge is on its way; the webhook or the sweep confirms the seats.
    case processing
    case failed(String)
    case cancelled
}
