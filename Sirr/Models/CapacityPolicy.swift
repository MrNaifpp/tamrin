//
//  CapacityPolicy.swift
//  Sirr
//
//  What happens to a session once every seat is taken. The organizer picks
//  this when creating the session and can change it later; `waitlist` is the
//  default everywhere, including the column default in Postgres.
//

import Foundation

enum CapacityPolicy: String, Codable, CaseIterable {
    /// Latecomers queue, and the longest waiter is seated automatically the
    /// moment anyone withdraws.
    case waitlist
    /// Registration simply ends at capacity — no queue is offered.
    case closed
}
