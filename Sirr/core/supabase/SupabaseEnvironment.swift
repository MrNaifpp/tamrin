import Foundation

/// Which Supabase project this build talks to, resolved from Info.plist and
/// ultimately from Config/Debug.xcconfig or Config/Release.xcconfig.
///
/// Debug builds get the development sandbox, Release builds get production.
/// The shared scheme maps Run to Debug and Archive to Release, so a build on
/// its way to TestFlight or the App Store cannot reach the sandbox.
enum SupabaseEnvironment {
    static let host = value("SUPABASE_HOST")
    static let anonKey = value("SUPABASE_ANON_KEY")

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
