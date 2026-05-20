//
//  SupabaseClientManager.swift
//  Sirr
//
//  Created by naif ali alshahrani on 11/08/1447 AH.
//

import Supabase
import Foundation

final class SupabaseClientManager {
    static let shared = SupabaseClientManager()

    let client: SupabaseClient

    // Legacy JWT anon key — required for auth.uid() in RLS policies.
    // The newer sb_publishable_ key has a known bug (supabase/supabase#42235)
    // where auth.uid() returns NULL inside RLS evaluation.
    private static let supabaseAnonKey =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtwY2Rpbnh1c3h5Y2VuZm5pdGpjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk3ODc0MTUsImV4cCI6MjA4NTM2MzQxNX0.yKbHhYVZbvgU8QdCyYNrvG8rC7KtX5cqXPGpedHMJ_g"

    private init() {
        client = SupabaseClient(
            supabaseURL: URL(string: "https://kpcdinxusxycenfnitjc.supabase.co")!,
            supabaseKey: Self.supabaseAnonKey
        )
    }
}
