import Foundation
import Supabase
import os

private let configLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "AppConfig")

/// The single row of `public.app_config`. Readable without a session, because
/// the update gate has to work before the user signs in.
struct AppConfigRecord: Decodable, Identifiable, Equatable {
    let minimumVersion: String
    let updateUrl: String

    /// `sheet(item:)` needs an identity. The floor is the only thing that can
    /// change what the sheet says, so it is the right key.
    var id: String { minimumVersion }

    enum CodingKeys: String, CodingKey {
        case minimumVersion = "minimum_version"
        case updateUrl = "update_url"
    }
}

final class AppConfigService {
    static let shared = AppConfigService()
    private init() {}

    private var client: SupabaseClient { SupabaseClientManager.shared.client }

    /// Returns nil on any failure — network, decoding, missing row, anything.
    ///
    /// The gate must fail open. A config we cannot read is never a reason to
    /// lock someone out of the app: production runs on the free plan, and a
    /// paused or slow project locking out every user is a far worse outcome
    /// than someone staying on an old version another day.
    func fetch() async -> AppConfigRecord? {
        do {
            let record: AppConfigRecord = try await client
                .from("app_config")
                .select("minimum_version, update_url")
                .single()
                .execute()
                .value
            configLogger.info("API app_config fetch succeeded (minimum: \(record.minimumVersion, privacy: .public))")
            return record
        } catch {
            configLogger.error("API app_config fetch failed: \(error.localizedDescription)")
            return nil
        }
    }
}
