//
//  ManualPaymentService.swift
//  Sirr
//
//  Typed client for workspace payment methods and manual event payments.
//

import Foundation
import Supabase
import os

private let manualPaymentLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Sirr",
    category: "ManualPaymentService"
)

enum ManualPaymentSubmissionResult {
    case submitted(destination: PaymentDestination, groupSize: Int, totalAmount: Double)
    case seatsFull
    case alreadyJoined(PaymentStatus)
    case pendingGuestRequest
    case creatorMissingPaymentMethod
    case registrationClosed
    case eventTermsChanged
}

/// A second request made by someone who already owns a confirmed seat. Its
/// group size is only the newly-added guests; the member is never charged or
/// inserted again.
enum GuestRegistrationSubmissionResult {
    case submitted(destination: PaymentDestination, groupSize: Int, totalAmount: Double)
    case seatsFull
    case notRegistered
    case selfAlreadyRegistered
    case selfRegistrationPending
    case emptyGuests
    case duplicateName
    case pendingGuestRequest
    case creatorMissingPaymentMethod
    case registrationClosed
    case eventTermsChanged
    case notPublished
    case cancelled
}

enum ManualPaymentServiceError: Error, LocalizedError {
    case invalidDraft(PaymentMethodValidationIssue)
    case paymentMethodNotSelected
    case featureUnavailable
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case let .invalidDraft(issue):
            issue.localizedDescription
        case .paymentMethodNotSelected:
            "اختر وسيلة الدفع قبل تأكيد التسجيل."
        case .featureUnavailable:
            "وسائل الدفع غير متاحة حاليًا. حاول مرة أخرى لاحقًا."
        case let .malformedResponse(message):
            message
        }
    }
}

final class ManualPaymentService {
    static let shared = ManualPaymentService()

    private let client = SupabaseClientManager.shared.client
    private let decoder: JSONDecoder

    private init() {
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let preciseFormatter = ISO8601DateFormatter()
            preciseFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = preciseFormatter.date(from: value) {
                return date
            }

            let standardFormatter = ISO8601DateFormatter()
            standardFormatter.formatOptions = [.withInternetDateTime]
            if let date = standardFormatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(value)"
            )
        }
    }

    func upsertWorkspaceMethod(
        workspaceId: UUID,
        draft: PaymentMethodDraft
    ) async throws -> PaymentMethodRecord {
        if let issue = draft.validationIssue {
            throw ManualPaymentServiceError.invalidDraft(issue)
        }

        let params: [String: AnyJSON] = [
            "p_workspace_id": .string(workspaceId.uuidString),
            "p_provider": .string(draft.provider.rawValue),
            "p_mobile_number": draft.normalizedMobileNumber.map(AnyJSON.string) ?? .null,
            "p_iban": draft.normalizedIBAN.map(AnyJSON.string) ?? .null,
            "p_account_number": draft.normalizedAccountNumber.map(AnyJSON.string) ?? .null
        ]
        let response: PostgrestResponse<Void>
        do {
            response = try await client
                .rpc("upsert_workspace_payment_method", params: params)
                .execute()
        } catch {
            throw translatedRPCError(error, function: "upsert_workspace_payment_method")
        }
        let record = try decode(PaymentMethodRecord.self, from: response.data)
        manualPaymentLogger.info("Payment method saved (workspace: \(workspaceId), provider: \(draft.provider.rawValue))")
        return record
    }

    func getMyWorkspaceMethods(workspaceId: UUID) async throws -> [PaymentMethodRecord] {
        let response: PostgrestResponse<Void>
        do {
            response = try await client
                .rpc(
                    "get_my_workspace_payment_methods",
                    params: ["p_workspace_id": workspaceId.uuidString]
                )
                .execute()
        } catch {
            throw translatedRPCError(error, function: "get_my_workspace_payment_methods")
        }
        let methods = try decode([PaymentMethodRecord].self, from: response.data)
        manualPaymentLogger.info("Payment methods loaded (workspace: \(workspaceId), count: \(methods.count))")
        return methods
    }

    func getEventDestination(eventId: UUID) async throws -> PaymentDestination {
        let response: PostgrestResponse<Void>
        do {
            response = try await client
                .rpc(
                    "get_event_payment_destination",
                    params: ["p_event_id": eventId.uuidString]
                )
                .execute()
        } catch {
            throw translatedRPCError(error, function: "get_event_payment_destination")
        }
        return try decode(PaymentDestination.self, from: response.data)
    }

    /// Current event terms for a follow-up guest request. Unlike the regular
    /// destination RPC, this deliberately ignores the member's old immutable
    /// payment snapshot so a removed method cannot be submitted again.
    func getEventGuestDestination(eventId: UUID) async throws -> PaymentDestination {
        let response: PostgrestResponse<Void>
        do {
            response = try await client
                .rpc(
                    "get_event_guest_payment_destination",
                    params: ["p_event_id": eventId.uuidString]
                )
                .execute()
        } catch {
            throw translatedRPCError(error, function: "get_event_guest_payment_destination")
        }
        return try decode(PaymentDestination.self, from: response.data)
    }

    func submitPayment(
        eventId: UUID,
        guestNames: [String] = [],
        expectedDestination: PaymentDestination
    ) async throws -> ManualPaymentSubmissionResult {
        if expectedDestination.status == .available,
           expectedDestination.paymentMethodId == nil {
            throw ManualPaymentServiceError.paymentMethodNotSelected
        }

        struct SubmissionPayload: Decodable {
            let status: String
            let paymentStatus: String?
            let groupSize: Int?
            let eventId: UUID?
            let paymentMethodId: UUID?
            let provider: PaymentProvider?
            let mobileNumber: String?
            let iban: String?
            let accountNumber: String?
            let totalPrice: Double?
            let pricePerPerson: Double?

            enum CodingKeys: String, CodingKey {
                case status
                case paymentStatus = "payment_status"
                case groupSize = "group_size"
                case eventId = "event_id"
                case paymentMethodId = "payment_method_id"
                case provider
                case mobileNumber = "mobile_number"
                case iban
                case accountNumber = "account_number"
                case totalPrice = "total_price"
                case pricePerPerson = "price_per_person"
            }
        }

        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventId.uuidString),
            "p_guest_names": .array(guestNames.map(AnyJSON.string)),
            "p_payment_method_id": expectedDestination.paymentMethodId.map {
                .string($0.uuidString)
            } ?? .null,
            // Kept during the rollout so a server/client pair on either side
            // of the singular-to-array migration still agrees on the choice.
            "p_expected_payment_method_id": expectedDestination.paymentMethodId.map {
                .string($0.uuidString)
            } ?? .null,
            "p_expected_price_per_person": .double(expectedDestination.pricePerPerson)
        ]
        let response: PostgrestResponse<Void>
        do {
            response = try await client
                .rpc("submit_payment_v2", params: params)
                .execute()
        } catch {
            throw translatedRPCError(error, function: "submit_payment_v2")
        }
        let payload = try decode(SubmissionPayload.self, from: response.data)

        switch payload.status {
        case "submitted":
            let destinationStatus: PaymentDestinationStatus = payload.provider == nil ? .free : .available
            let destination = PaymentDestination(
                status: destinationStatus,
                eventId: payload.eventId ?? eventId,
                paymentMethodId: payload.paymentMethodId,
                provider: payload.provider,
                mobileNumber: payload.mobileNumber,
                iban: payload.iban,
                accountNumber: payload.accountNumber,
                paymentMethods: [],
                totalPrice: payload.totalPrice ?? expectedDestination.totalPrice,
                pricePerPerson: payload.pricePerPerson ?? expectedDestination.pricePerPerson,
                groupSize: payload.groupSize
            )
            guard destination.status == .free || destination.isAvailable else {
                throw ManualPaymentServiceError.malformedResponse(
                    "تعذر تحميل وسيلة الدفع المرتبطة بالموعد."
                )
            }
            let groupSize = payload.groupSize ?? max(1, guestNames.count + 1)
            let totalAmount = destination.pricePerPerson * Double(groupSize)
            manualPaymentLogger.info("Manual payment submitted (event: \(eventId), group: \(groupSize))")
            await PushManager.shared.requestAuthorizationAndRegister()
            return .submitted(
                destination: destination,
                groupSize: groupSize,
                totalAmount: totalAmount
            )

        case "seats_full":
            return .seatsFull

        case "already_joined":
            let status = PaymentStatus(rawValue: payload.paymentStatus ?? "confirmed") ?? .confirmed
            return .alreadyJoined(status)

        case "pending_guest_request":
            return .pendingGuestRequest

        case "payment_method_required", "creator_missing_payment_method", "creator_missing_number":
            return .creatorMissingPaymentMethod

        case "registration_closed":
            return .registrationClosed

        case "event_terms_changed":
            return .eventTermsChanged

        default:
            throw ManualPaymentServiceError.malformedResponse(
                "استجابة غير معروفة من submit_payment_v2: \(payload.status)"
            )
        }
    }

    func registerGuests(
        eventId: UUID,
        guestNames: [String],
        expectedDestination: PaymentDestination,
        withoutSelf: Bool = false
    ) async throws -> GuestRegistrationSubmissionResult {
        if expectedDestination.status == .available,
           expectedDestination.paymentMethodId == nil {
            throw ManualPaymentServiceError.paymentMethodNotSelected
        }

        struct SubmissionPayload: Decodable {
            let status: String
            let groupSize: Int?
            let eventId: UUID?
            let paymentMethodId: UUID?
            let provider: PaymentProvider?
            let mobileNumber: String?
            let iban: String?
            let accountNumber: String?
            let totalPrice: Double?
            let pricePerPerson: Double?

            enum CodingKeys: String, CodingKey {
                case status
                case groupSize = "group_size"
                case eventId = "event_id"
                case paymentMethodId = "payment_method_id"
                case provider
                case mobileNumber = "mobile_number"
                case iban
                case accountNumber = "account_number"
                case totalPrice = "total_price"
                case pricePerPerson = "price_per_person"
            }
        }

        let params: [String: AnyJSON] = [
            "p_event_id": .string(eventId.uuidString),
            "p_guest_names": .array(guestNames.map(AnyJSON.string)),
            "p_payment_method_id": expectedDestination.paymentMethodId.map {
                .string($0.uuidString)
            } ?? .null,
            "p_expected_payment_method_id": expectedDestination.paymentMethodId.map {
                .string($0.uuidString)
            } ?? .null,
            "p_expected_price_per_person": .double(expectedDestination.pricePerPerson)
        ]

        let response: PostgrestResponse<Void>
        let function = withoutSelf
            ? "register_event_guest_only"
            : "register_event_guests"
        do {
            response = try await client
                .rpc(function, params: params)
                .execute()
        } catch {
            throw translatedRPCError(error, function: function)
        }
        let payload = try decode(SubmissionPayload.self, from: response.data)

        switch payload.status {
        case "submitted":
            let destinationStatus: PaymentDestinationStatus = payload.provider == nil ? .free : .available
            let destination = PaymentDestination(
                status: destinationStatus,
                eventId: payload.eventId ?? eventId,
                paymentMethodId: payload.paymentMethodId,
                provider: payload.provider,
                mobileNumber: payload.mobileNumber,
                iban: payload.iban,
                accountNumber: payload.accountNumber,
                paymentMethods: [],
                totalPrice: payload.totalPrice ?? expectedDestination.totalPrice,
                pricePerPerson: payload.pricePerPerson ?? expectedDestination.pricePerPerson,
                groupSize: payload.groupSize
            )
            guard destination.status == .free || destination.isAvailable else {
                throw ManualPaymentServiceError.malformedResponse(
                    "تعذر تحميل وسيلة الدفع المرتبطة بالموعد."
                )
            }
            let groupSize = payload.groupSize ?? guestNames.count
            let totalAmount = destination.pricePerPerson * Double(groupSize)
            manualPaymentLogger.info("Guests registered (event: \(eventId), group: \(groupSize))")
            await PushManager.shared.requestAuthorizationAndRegister()
            return .submitted(
                destination: destination,
                groupSize: groupSize,
                totalAmount: totalAmount
            )

        case "seats_full": return .seatsFull
        case "not_registered": return .notRegistered
        case "self_already_registered": return .selfAlreadyRegistered
        case "self_registration_pending": return .selfRegistrationPending
        case "empty_guests": return .emptyGuests
        case "duplicate_name": return .duplicateName
        case "pending_guest_request": return .pendingGuestRequest
        case "payment_method_required", "creator_missing_payment_method", "creator_missing_number":
            return .creatorMissingPaymentMethod
        case "registration_closed": return .registrationClosed
        case "event_terms_changed": return .eventTermsChanged
        case "not_published": return .notPublished
        case "cancelled": return .cancelled
        default:
            throw ManualPaymentServiceError.malformedResponse(
                "استجابة غير معروفة من \(function): \(payload.status)"
            )
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            manualPaymentLogger.error("Failed to decode payment response: \(error.localizedDescription, privacy: .public)")
            throw ManualPaymentServiceError.malformedResponse(
                "تعذر قراءة استجابة وسيلة الدفع."
            )
        }
    }

    private func translatedRPCError(_ error: Error, function: String) -> Error {
        let description = error.localizedDescription.lowercased()
        let postgrestCode = (error as? PostgrestError)?.code
        let isMissingSchemaEntry = postgrestCode == "PGRST202"
            || postgrestCode == "PGRST203"
            || description.contains("schema cache")
            || description.contains("could not find public.")

        if isMissingSchemaEntry {
            manualPaymentLogger.error(
                "Payment RPC unavailable (function: \(function, privacy: .public), code: \(postgrestCode ?? "unknown", privacy: .public))"
            )
            return ManualPaymentServiceError.featureUnavailable
        }
        return error
    }
}
