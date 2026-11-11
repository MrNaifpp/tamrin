//
//  CardPayments.swift
//  Sirr
//
//  Whether this build offers Apple Pay at all. The MyFatoorah functions
//  (create-payment, pay-apple-pay, the webhook, refund-payment, payment-sweep)
//  are live on the sandbox only, so a pay button that reached for them in
//  production would fail for every member who owes. Off, pay opens the manual
//  transfer, as before.
//

import Foundation

enum CardPayments {
    /// On wherever the payment functions are deployed, which today is the
    /// sandbox only. Keyed to the project rather than the build configuration
    /// so a TestFlight build pinned to the sandbox keeps Apple Pay for testing.
    /// Add production here once its functions, secrets and webhook are live.
    static let isEnabled = SupabaseEnvironment.host.hasPrefix("kpcdinxusxycenfnitjc.")

    /// TEST ONLY: a "pay by card" button that opens MyFatoorah's hosted card
    /// page on their test server, for testing the payment pipeline with test
    /// cards while Apple Pay waits for its certificate. Sandbox builds only, so
    /// an App Store build (which talks to production) never shows it; the
    /// server's pay-card-test also refuses unless it points at the test server.
    static let testCardEnabled = SupabaseEnvironment.host.hasPrefix("kpcdinxusxycenfnitjc.")
}
