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
}
