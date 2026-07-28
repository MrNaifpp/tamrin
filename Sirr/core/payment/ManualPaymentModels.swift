//
//  ManualPaymentModels.swift
//  Sirr
//
//  Shared domain models and validation for manual payment destinations.
//

import Foundation
import SwiftUI

enum PaymentMethodType: String, Codable, Hashable {
    case cash
    case mobileWallet = "mobile_wallet"
    case bankAccount = "bank_account"
}

enum PaymentProvider: String, Codable, CaseIterable, Identifiable, Hashable {
    case cash
    case stcBank = "stc_bank"
    case barq
    case alRajhi = "al_rajhi"
    case snb
    case alinma
    case riyad

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cash: "الدفع كاش في الملعب"
        case .stcBank: "STC Bank"
        case .barq: "برق"
        case .alRajhi: "مصرف الراجحي"
        case .snb: "البنك الأهلي السعودي"
        case .alinma: "مصرف الإنماء"
        case .riyad: "بنك الرياض"
        }
    }

    /// Short label used inside the code-native provider mark.
    var logoName: String {
        switch self {
        case .cash: "كاش"
        case .stcBank: "stc"
        case .barq: "برق"
        case .alRajhi: "الراجحي"
        case .snb: "SNB"
        case .alinma: "الإنماء"
        case .riyad: "الرياض"
        }
    }

    var methodType: PaymentMethodType {
        switch self {
        case .cash: .cash
        case .stcBank, .barq: .mobileWallet
        case .alRajhi, .snb, .alinma, .riyad: .bankAccount
        }
    }

    var isCash: Bool { self == .cash }
    var requiresPhone: Bool { methodType == .mobileWallet }
    var requiresMobileNumber: Bool { requiresPhone }
    var requiresIBAN: Bool { methodType == .bankAccount }
    var supportsAccountNumber: Bool { methodType == .bankAccount }

    var brandColor: Color {
        switch self {
        case .cash: Color(red: 0.12, green: 0.23, blue: 0.17)
        case .stcBank: Color(red: 0.31, green: 0.00, blue: 0.55)
        case .barq: Color(red: 0.45, green: 0.22, blue: 0.90)
        case .alRajhi: Color(red: 0.08, green: 0.06, blue: 0.88)
        case .snb: Color(red: 0.00, green: 0.42, blue: 0.23)
        case .alinma: Color(red: 0.42, green: 0.30, blue: 0.24)
        case .riyad: Color(red: 0.15, green: 0.00, blue: 0.43)
        }
    }

    var brandForegroundColor: Color {
        .white
    }

    var brandSurfaceColor: Color {
        brandColor.opacity(0.13)
    }

    var systemImageName: String? {
        switch self {
        case .cash: "banknote.fill"
        case .barq: "bolt.fill"
        default: nil
        }
    }

    var logoAssetName: String? {
        switch self {
        case .cash: nil
        case .stcBank: "PaymentLogoSTCBank"
        case .barq: "PaymentLogoBarq"
        case .alRajhi: "PaymentLogoAlRajhi"
        case .snb: "PaymentLogoSNB"
        case .alinma: "PaymentLogoAlinma"
        case .riyad: "PaymentLogoRiyad"
        }
    }

    var logoSurfaceColor: Color {
        self == .stcBank ? brandColor : .white
    }

    var openAppTitle: String? {
        switch self {
        case .cash: nil
        case .stcBank: "افتح تطبيق STC Bank"
        case .barq: "افتح تطبيق برق"
        case .alRajhi: "افتح تطبيق الراجحي"
        case .snb: "افتح تطبيق الأهلي"
        case .alinma: "افتح تطبيق الإنماء"
        case .riyad: "افتح تطبيق بنك الرياض"
        }
    }
}

enum PaymentMethodValidationIssue: Error, Equatable, LocalizedError {
    case missingMobileNumber
    case invalidSaudiMobile
    case missingIBAN
    case invalidSaudiIBAN
    case invalidAccountNumber

    var errorDescription: String? {
        switch self {
        case .missingMobileNumber:
            "أدخل رقم الجوال المرتبط بوسيلة الدفع."
        case .invalidSaudiMobile:
            "أدخل رقم جوال سعودي صحيح."
        case .missingIBAN:
            "أدخل رقم الآيبان."
        case .invalidSaudiIBAN:
            "أدخل آيبان سعودي صحيح يبدأ بـ SA ويتبعه 22 رقمًا."
        case .invalidAccountNumber:
            "رقم الحساب اختياري، وإذا أضفته يجب أن يتكوّن من 6 إلى 24 رقمًا."
        }
    }
}

struct PaymentMethodDraft: Hashable {
    var provider: PaymentProvider
    var phoneNumber: String
    var iban: String
    var accountNumber: String

    var mobileNumber: String {
        get { phoneNumber }
        set { phoneNumber = newValue }
    }

    init(
        provider: PaymentProvider,
        phoneNumber: String = "",
        iban: String = "",
        accountNumber: String = ""
    ) {
        self.provider = provider
        self.phoneNumber = phoneNumber
        self.iban = iban
        self.accountNumber = accountNumber
    }

    init(
        provider: PaymentProvider,
        mobileNumber: String,
        iban: String = "",
        accountNumber: String = ""
    ) {
        self.init(
            provider: provider,
            phoneNumber: mobileNumber,
            iban: iban,
            accountNumber: accountNumber
        )
    }

    init(record: PaymentMethodRecord) {
        self.init(
            provider: record.provider,
            phoneNumber: record.mobileNumber ?? "",
            iban: record.iban ?? "",
            accountNumber: record.accountNumber ?? ""
        )
    }

    var validationIssue: PaymentMethodValidationIssue? {
        switch provider.methodType {
        case .cash:
            return nil
        case .mobileWallet:
            guard !phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missingMobileNumber
            }
            return PaymentInputValidator.normalizedSaudiMobile(phoneNumber) == nil
                ? .invalidSaudiMobile
                : nil
        case .bankAccount:
            guard !iban.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .missingIBAN
            }
            guard PaymentInputValidator.normalizedSaudiIBAN(iban) != nil else {
                return .invalidSaudiIBAN
            }
            let rawAccount = accountNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rawAccount.isEmpty,
               !PaymentInputValidator.isValidAccountNumber(rawAccount) {
                return .invalidAccountNumber
            }
            return nil
        }
    }

    var isValid: Bool { validationIssue == nil }

    var normalizedMobileNumber: String? {
        provider.requiresMobileNumber
            ? PaymentInputValidator.normalizedSaudiMobile(phoneNumber)
            : nil
    }

    var normalizedIBAN: String? {
        provider.requiresIBAN
            ? PaymentInputValidator.normalizedSaudiIBAN(iban)
            : nil
    }

    var normalizedAccountNumber: String? {
        guard provider.supportsAccountNumber else { return nil }
        let value = PaymentInputValidator.normalizedAccountNumber(accountNumber)
        return value.isEmpty ? nil : value
    }
}

struct PaymentMethodRecord: Codable, Identifiable, Hashable {
    let id: UUID
    let workspaceId: UUID
    let provider: PaymentProvider
    let mobileNumber: String?
    let iban: String?
    let accountNumber: String?
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceId = "workspace_id"
        case provider
        case mobileNumber = "mobile_number"
        case iban
        case accountNumber = "account_number"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var asDraft: PaymentMethodDraft {
        PaymentMethodDraft(record: self)
    }

    var maskedSummary: String {
        switch provider.methodType {
        case .cash:
            return "الدفع عند الحضور"
        case .mobileWallet:
            guard let mobileNumber else { return provider.displayName }
            return "رقم الجوال •••• \(mobileNumber.suffix(4))"
        case .bankAccount:
            guard let iban else { return provider.displayName }
            return "IBAN •••• \(iban.suffix(4))"
        }
    }
}

enum PaymentDestinationStatus: String, Codable, Hashable {
    case available
    case free
    case paymentMethodRequired = "payment_method_required"
}

/// One destination the organizer made available for an event. This is kept
/// separate from `PaymentMethodRecord`: members may read only these transfer
/// details, never the owner's full saved-method rows or timestamps.
struct PaymentDestinationMethod: Codable, Identifiable, Hashable {
    let paymentMethodId: UUID
    let provider: PaymentProvider
    let mobileNumber: String?
    let iban: String?
    let accountNumber: String?

    var id: UUID { paymentMethodId }

    enum CodingKeys: String, CodingKey {
        case paymentMethodId = "payment_method_id"
        case provider
        case mobileNumber = "mobile_number"
        case iban
        case accountNumber = "account_number"
    }
}

struct PaymentDestination: Codable, Identifiable, Hashable {
    let status: PaymentDestinationStatus
    let eventId: UUID
    /// The selected destination snapshot. It is nil before the player chooses
    /// one of `paymentMethods`, and remains populated after submission.
    let paymentMethodId: UUID?
    let provider: PaymentProvider?
    let mobileNumber: String?
    let iban: String?
    let accountNumber: String?
    /// Organizer-provided choices before submission. Older servers omit this
    /// key, so decoding intentionally defaults it to an empty array.
    let paymentMethods: [PaymentDestinationMethod]
    let totalPrice: Double
    let pricePerPerson: Double
    let groupSize: Int?

    var id: UUID { paymentMethodId ?? eventId }
    var isAvailable: Bool {
        status == .available && !availablePaymentMethods.isEmpty
    }

    /// Available choices in organizer order. A submitted/legacy singular
    /// snapshot is exposed as one method so older responses stay readable.
    var availablePaymentMethods: [PaymentDestinationMethod] {
        guard status == .available else { return [] }
        if !paymentMethods.isEmpty { return paymentMethods }
        guard
            let paymentMethodId,
            let provider
        else { return [] }
        return [
            PaymentDestinationMethod(
                paymentMethodId: paymentMethodId,
                provider: provider,
                mobileNumber: mobileNumber,
                iban: iban,
                accountNumber: accountNumber
            )
        ]
    }

    var selectedMethod: PaymentDestinationMethod? {
        guard let paymentMethodId, let provider else { return nil }
        return PaymentDestinationMethod(
            paymentMethodId: paymentMethodId,
            provider: provider,
            mobileNumber: mobileNumber,
            iban: iban,
            accountNumber: accountNumber
        )
    }

    init(
        status: PaymentDestinationStatus,
        eventId: UUID,
        paymentMethodId: UUID?,
        provider: PaymentProvider?,
        mobileNumber: String?,
        iban: String?,
        accountNumber: String?,
        paymentMethods: [PaymentDestinationMethod] = [],
        totalPrice: Double,
        pricePerPerson: Double,
        groupSize: Int?
    ) {
        self.status = status
        self.eventId = eventId
        self.paymentMethodId = paymentMethodId
        self.provider = provider
        self.mobileNumber = mobileNumber
        self.iban = iban
        self.accountNumber = accountNumber
        self.paymentMethods = paymentMethods
        self.totalPrice = totalPrice
        self.pricePerPerson = pricePerPerson
        self.groupSize = groupSize
    }

    /// Returns the same event terms with the chosen method copied into the
    /// singular snapshot fields consumed by the details and submit screens.
    func selecting(_ method: PaymentDestinationMethod) -> PaymentDestination {
        guard availablePaymentMethods.contains(where: { $0.id == method.id }) else {
            return self
        }
        return PaymentDestination(
            status: status,
            eventId: eventId,
            paymentMethodId: method.paymentMethodId,
            provider: method.provider,
            mobileNumber: method.mobileNumber,
            iban: method.iban,
            accountNumber: method.accountNumber,
            paymentMethods: paymentMethods,
            totalPrice: totalPrice,
            pricePerPerson: pricePerPerson,
            groupSize: groupSize
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(PaymentDestinationStatus.self, forKey: .status)
        eventId = try container.decode(UUID.self, forKey: .eventId)
        paymentMethodId = try container.decodeIfPresent(UUID.self, forKey: .paymentMethodId)
        provider = try container.decodeIfPresent(PaymentProvider.self, forKey: .provider)
        mobileNumber = try container.decodeIfPresent(String.self, forKey: .mobileNumber)
        iban = try container.decodeIfPresent(String.self, forKey: .iban)
        accountNumber = try container.decodeIfPresent(String.self, forKey: .accountNumber)
        paymentMethods = try container.decodeIfPresent(
            [PaymentDestinationMethod].self,
            forKey: .paymentMethods
        ) ?? []
        totalPrice = try container.decodeIfPresent(Double.self, forKey: .totalPrice) ?? 0
        pricePerPerson = try container.decodeIfPresent(Double.self, forKey: .pricePerPerson) ?? 0
        groupSize = try container.decodeIfPresent(Int.self, forKey: .groupSize)
    }

    enum CodingKeys: String, CodingKey {
        case status
        case eventId = "event_id"
        case paymentMethodId = "payment_method_id"
        case provider
        case mobileNumber = "mobile_number"
        case iban
        case accountNumber = "account_number"
        case paymentMethods = "payment_methods"
        case totalPrice = "total_price"
        case pricePerPerson = "price_per_person"
        case groupSize = "group_size"
    }
}

enum PaymentInputValidator {
    /// Accepts 05XXXXXXXX, 5XXXXXXXX, +9665XXXXXXXX and 009665XXXXXXXX.
    /// The stored result always uses +9665XXXXXXXX.
    static func normalizedSaudiMobile(_ raw: String) -> String? {
        var digits = asciiDigits(in: raw)

        if digits.hasPrefix("00966") {
            digits.removeFirst(5)
        } else if digits.hasPrefix("966") {
            digits.removeFirst(3)
        } else if digits.hasPrefix("0") {
            digits.removeFirst()
        }

        guard digits.count == 9, digits.hasPrefix("5") else { return nil }
        return "+966" + digits
    }

    /// Saudi IBANs contain SA followed by 22 digits. The checksum is also
    /// verified, so format-correct typing errors are caught before submission.
    static func normalizedSaudiIBAN(_ raw: String) -> String? {
        let compact = raw
            .uppercased()
            .unicodeScalars
            .compactMap { scalar -> String? in
                if let digit = asciiDigit(for: scalar) { return String(digit) }
                if CharacterSet.letters.contains(scalar) { return String(scalar) }
                if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "-" { return nil }
                return String(scalar)
            }
            .joined()

        guard compact.count == 24, compact.hasPrefix("SA") else { return nil }
        let digits = compact.dropFirst(2)
        guard digits.count == 22, digits.allSatisfy(\.isNumber), hasValidIBANChecksum(compact) else {
            return nil
        }
        return compact
    }

    static func normalizedAccountNumber(_ raw: String) -> String {
        asciiDigits(in: raw)
    }

    nonisolated static func isAccountNumberCharacter(_ scalar: UnicodeScalar) -> Bool {
        asciiDigit(for: scalar) != nil
            || CharacterSet.whitespacesAndNewlines.contains(scalar)
            || scalar == "-"
    }

    static func isValidSaudiMobile(_ raw: String) -> Bool {
        normalizedSaudiMobile(raw) != nil
    }

    static func isValidSaudiIBAN(_ raw: String) -> Bool {
        normalizedSaudiIBAN(raw) != nil
    }

    static func isValidAccountNumber(_ raw: String) -> Bool {
        let compact = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedAccountNumber(compact)
        return normalized.count >= 6
            && normalized.count <= 24
            && compact.unicodeScalars.allSatisfy(isAccountNumberCharacter)
    }

    private static func asciiDigits(in value: String) -> String {
        value.unicodeScalars.compactMap(asciiDigit(for:)).map(String.init).joined()
    }

    nonisolated private static func asciiDigit(for scalar: UnicodeScalar) -> Int? {
        switch scalar.value {
        case 48 ... 57: Int(scalar.value - 48)
        case 0x0660 ... 0x0669: Int(scalar.value - 0x0660)
        case 0x06F0 ... 0x06F9: Int(scalar.value - 0x06F0)
        default: nil
        }
    }

    private static func hasValidIBANChecksum(_ iban: String) -> Bool {
        let moved = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0

        for scalar in moved.unicodeScalars {
            let value: Int
            if let digit = asciiDigit(for: scalar) {
                value = digit
            } else {
                let upper = scalar.value
                guard (65 ... 90).contains(upper) else { return false }
                value = Int(upper - 55)
            }

            if value >= 10 {
                remainder = (remainder * 10 + value / 10) % 97
            }
            remainder = (remainder * 10 + value % 10) % 97
        }

        return remainder == 1
    }
}
