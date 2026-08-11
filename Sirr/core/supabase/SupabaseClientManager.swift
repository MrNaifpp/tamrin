//
//  SupabaseClientManager.swift
//  Sirr
//
//  Created by naif ali alshahrani on 11/08/1447 AH.
//

import Supabase
import Foundation
import os

final class SupabaseClientManager {
    static let shared = SupabaseClientManager()

    let client: SupabaseClient

    private init() {
        client = SupabaseClient(
            supabaseURL: SupabaseEnvironment.url,
            supabaseKey: SupabaseEnvironment.anonKey
        )
        #if DEBUG
        // Which project this build is pointed at is the first thing worth
        // knowing when something behaves unexpectedly on device.
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "Supabase")
            .info("Supabase host: \(SupabaseEnvironment.host, privacy: .public)")
        #endif
    }
}
