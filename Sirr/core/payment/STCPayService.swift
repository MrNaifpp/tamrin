//
//  STCPayService.swift
//  Sirr
//
//  Wraps the STC Pay RPCs (submit_payment, confirm_payment, reject_payment,
//  cancel_pending, join_waitlist, leave_waitlist) and exposes them as typed
//  async methods to the iOS layer.
//

import Foundation
import Supabase
import os

private let stcPayLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "STCPay")

/// Result of `submit_payment`. The RPC encodes status as a string so we can
/// route to the appropriate UI without throwing.
enum SubmitPaymentResult {
    /// Payment was submitted; pending rows exist (joiner + guests). `groupSize`
    /// is the number of seats paid for (1 + guests).
    case submitted(creatorId: UUID, paidToNumber: String, groupSize: Int)
    /// Event is full. UI should pivot to the waitlist sheet.
    case seatsFull
    /// User already has a row for this event (any status).
    case alreadyJoined(paymentStatus: PaymentStatus)
    /// Creator never set their STC Pay number — defensive; the guardrail at
    /// event-creation time should make this unreachable.
    case creatorMissingNumber
    /// Registration is closed (creator locked it).
    case registrationClosed
}

/// Generic result for RPCs that delete a row and want to notify waitlisted users.
struct SeatFreedResult {
    let waiterIds: [UUID]
}

final class STCPayService {
    static let shared = STCPayService()
    private let client = SupabaseClientManager.shared.client

    /// Submit a paid-event payment for the joiner plus optional named guests.
    func submitPayment(eventId: UUID, userId: UUID, guestNames: [String] = []) async throws -> SubmitPaymentResult {
        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventId.uuidString),
            "p_user_id": .string(userId.uuidString),
            "p_guest_names": .array(guestNames.map { .string($0) })
        ]
        let response = try await client.rpc("submit_payment", params: params).execute()
        let payload = try Self.decodeJSON(response.data)

        guard let status = payload["status"] as? String else {
            throw NSError(domain: "STCPayService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Malformed submit_payment response"])
        }

        switch status {
        case "submitted":
            guard
                let creatorIdString = payload["creator_id"] as? String,
                let creatorId = UUID(uuidString: creatorIdString),
                let number = payload["paid_to_number"] as? String
            else {
                throw NSError(domain: "STCPayService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Malformed submitted payload"])
            }
            let groupSize = (payload["group_size"] as? Int) ?? 1
            stcPayLogger.info("submit_payment submitted (eventId: \(eventId), group: \(groupSize))")
            await PushManager.shared.requestAuthorizationAndRegister()
            return .submitted(creatorId: creatorId, paidToNumber: number, groupSize: groupSize)
        case "seats_full":
            stcPayLogger.info("submit_payment seats_full (eventId: \(eventId))")
            return .seatsFull
        case "already_joined":
            let raw = payload["payment_status"] as? String ?? "confirmed"
            let s = PaymentStatus(rawValue: raw) ?? .confirmed
            stcPayLogger.info("submit_payment already_joined (eventId: \(eventId), status: \(raw))")
            return .alreadyJoined(paymentStatus: s)
        case "creator_missing_number":
            stcPayLogger.warning("submit_payment creator_missing_number (eventId: \(eventId))")
            return .creatorMissingNumber
        case "registration_closed":
            stcPayLogger.info("submit_payment registration_closed (eventId: \(eventId))")
            return .registrationClosed
        default:
            throw NSError(domain: "STCPayService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown submit_payment status: \(status)"])
        }
    }

    /// Creator confirms a pending payment.
    func confirmPayment(eventId: UUID, joinerId: UUID, creatorId: UUID) async throws {
        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_user_id": joinerId.uuidString,
            "p_creator_id": creatorId.uuidString
        ]
        try await client.rpc("confirm_payment", params: params).execute()
        stcPayLogger.info("confirm_payment ok (eventId: \(eventId), joinerId: \(joinerId))")
    }

    /// Creator rejects a pending payment. Returns waitlist user ids to push.
    func rejectPayment(eventId: UUID, joinerId: UUID, creatorId: UUID) async throws -> SeatFreedResult {
        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_user_id": joinerId.uuidString,
            "p_creator_id": creatorId.uuidString
        ]
        let response = try await client.rpc("reject_payment", params: params).execute()
        let waiters = try Self.extractWaiterIds(from: response.data)
        stcPayLogger.info("reject_payment ok (eventId: \(eventId), waiters: \(waiters.count))")
        return SeatFreedResult(waiterIds: waiters)
    }

    /// Joiner cancels their own pending payment. Returns waitlist user ids to push.
    func cancelPending(eventId: UUID, userId: UUID) async throws -> SeatFreedResult {
        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_user_id": userId.uuidString
        ]
        let response = try await client.rpc("cancel_pending", params: params).execute()
        let waiters = try Self.extractWaiterIds(from: response.data)
        stcPayLogger.info("cancel_pending ok (eventId: \(eventId), waiters: \(waiters.count))")
        return SeatFreedResult(waiterIds: waiters)
    }

    /// Join the waitlist for a full event.
    func joinWaitlist(eventId: UUID, userId: UUID) async throws {
        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_user_id": userId.uuidString
        ]
        try await client.rpc("join_waitlist", params: params).execute()
        stcPayLogger.info("join_waitlist ok (eventId: \(eventId))")
    }

    /// Leave the waitlist.
    func leaveWaitlist(eventId: UUID, userId: UUID) async throws {
        let params: [String: String] = [
            "p_event_id": eventId.uuidString,
            "p_user_id": userId.uuidString
        ]
        try await client.rpc("leave_waitlist", params: params).execute()
        stcPayLogger.info("leave_waitlist ok (eventId: \(eventId))")
    }

    // MARK: - Helpers

    private static func decodeJSON(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "STCPayService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Response is not a JSON object"])
        }
        return obj
    }

    private static func extractWaiterIds(from data: Data) throws -> [UUID] {
        let payload = try decodeJSON(data)
        guard let raw = payload["waiter_ids"] as? [String] else { return [] }
        return raw.compactMap { UUID(uuidString: $0) }
    }
}
