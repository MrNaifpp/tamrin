//
//  PaymentOwed.swift
//  Sirr
//
//  The server refuses any registration while an ended workout in the same group
//  is unpaid (guard_event_registration_insert, 20260929120000). It names that
//  workout in the error's hint, not its detail: PostgREST sends `details` and
//  PostgrestError decodes `detail`, so a detail never arrives.
//

import Foundation
import Supabase

enum PaymentOwed {
    static let hintPrefix = "payment_owed:"

    /// The unpaid workout's id when `error` is that refusal, otherwise nil.
    static func unpaidEventID(in error: Error) -> UUID? {
        guard let hint = (error as? PostgrestError)?.hint,
              hint.hasPrefix(hintPrefix) else { return nil }
        return UUID(uuidString: String(hint.dropFirst(hintPrefix.count)))
    }
}
