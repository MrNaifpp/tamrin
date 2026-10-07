//
//  PaymentStatus.swift
//  Sirr
//
//  Payment status on an event_participants row.
//

import Foundation

enum PaymentStatus: String, Codable {
    case pending
    case confirmed
    case rejected
    /// Written by waive_expired_event_debts() 24 hours after a workout starts,
    /// on a seat nobody paid for. Without this case one waived row fails the
    /// whole roster decode, and a past workout shows nobody registered.
    case waived
}
