//
//  CardPayments.swift
//  Sirr
//
//  Whether this build offers card and Apple Pay at all. Production has none of
//  the Moyasar functions yet (create-payment, verify-payment, the webhook,
//  refund-payment), so a pay button that reached for them there would fail for
//  every member who owes. Off, pay opens the manual transfer, as before cards.
//

import Foundation

enum CardPayments {
    /// On wherever the payment functions are deployed, which today is the
    /// sandbox only. Keyed to the project rather than the build configuration
    /// so a TestFlight build pinned to the sandbox keeps cards for testing.
    /// Add production here once its functions, secrets and webhook are live.
    /// Also off whenever the Moyasar SDK is out of the project, as it is while
    /// App Review requires no PassKit in a build that offers no Apple Pay.
    #if canImport(MoyasarSdk)
    static let isEnabled = SupabaseEnvironment.host.hasPrefix("kpcdinxusxycenfnitjc.")
    #else
    static let isEnabled = false
    #endif
}
