import Foundation

/// Which Supabase project this build talks to, resolved from Info.plist and
/// ultimately from Config/Debug.xcconfig or Config/Release.xcconfig.
///
/// Debug builds get the development sandbox, Release builds get production.
/// The shared scheme maps Run to Debug and Archive to Release, so a build on
/// its way to TestFlight or the App Store cannot reach the sandbox.
///
/// Staging is the exception: its endpoint is compiled in rather than read from
/// Info.plist. A staging build ships under its own bundle id to its own App
/// Store Connect record, and pinning the sandbox in code means no xcconfig or
/// build-setting edit can aim that binary at production.
enum SupabaseEnvironment {
    // ⚠️ TEMPORARY: every build talks to the SANDBOX, production included.
    // Here so an archive of the normal `Sirr` scheme can exercise the
    // waitlist feature, whose migration has only reached the sandbox.
    // MUST become `#if STAGING` again before anything is submitted for
    // review, or real users land on the sandbox database.
    #if true
    /// Development sandbox, pinned. Config/Staging.xcconfig deliberately does
    /// not define SUPABASE_HOST or SUPABASE_ANON_KEY, so there is exactly one
    /// place these values live and nothing to drift out of sync.
    static let host = "kpcdinxusxycenfnitjc.supabase.co"

    /// Legacy JWT anon key, not the newer sb_publishable_ format — that one
    /// makes auth.uid() return NULL inside RLS (supabase#42235), which would
    /// break every policy in the migration set. Anon keys are public by
    /// design; they ship in the app binary and RLS is what protects the data.
    static let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImtwY2Rpbnh1c3h5Y2VuZm5pdGpjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk3ODc0MTUsImV4cCI6MjA4NTM2MzQxNX0.yKbHhYVZbvgU8QdCyYNrvG8rC7KtX5cqXPGpedHMJ_g"
    #else
    static let host = value("SUPABASE_HOST")
    static let anonKey = value("SUPABASE_ANON_KEY")
    #endif

    /// Built here rather than stored whole: `//` starts a comment in xcconfig,
    /// so a literal `https://…` value would silently truncate to `https:`.
    static var url: URL { URL(string: "https://\(host)")! }

    /// Traps instead of falling back. A build whose xcconfig is not wired to
    /// its configuration must fail loudly at launch — the alternative is an
    /// app that quietly talks to the wrong project, or to nothing.
    private static func value(_ key: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$(")  // unsubstituted — the xcconfig is not attached
        else {
            fatalError("Info.plist is missing a usable \(key). Is Config/<configuration>.xcconfig wired to this build configuration?")
        }
        return raw
    }
}
