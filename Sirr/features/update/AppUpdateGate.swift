import Foundation
import SwiftUI
// Explicit: MEMBER_IMPORT_VISIBILITY is on, so SwiftUI no longer re-exports
// Combine and @Published would not resolve without this.
import Combine

/// Decides whether the installed build is too old to keep running.
///
/// `required` is non-nil only when the app is genuinely below the floor. Every
/// other outcome — fetch failed, no row, version is fine — leaves it nil, so
/// the app carries on. See `AppConfigService.fetch()` for why failing open is
/// deliberate rather than lax.
@MainActor
final class AppUpdateGate: ObservableObject {
    @Published private(set) var required: AppConfigRecord?

    /// Binding for `sheet(item:)`. The setter is intentionally a no-op: the
    /// only thing allowed to clear the gate is `refresh()` deciding the build
    /// is acceptable. SwiftUI would otherwise write nil here on dismissal,
    /// which is precisely the escape route this screen must not have.
    var presentation: Binding<AppConfigRecord?> {
        Binding(get: { self.required }, set: { _ in })
    }

    /// The marketing version, e.g. "1.2" — the same string App Store Connect
    /// shows, which is what the floor in `app_config` is written against.
    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `.numeric` compares runs of digits as numbers, so 1.10 correctly sorts
    /// above 1.9. A plain string comparison gets that backwards and would let
    /// a blocked build through the moment the minor version reaches double
    /// figures.
    static func isOutdated(installed: String, minimum: String) -> Bool {
        installed.compare(minimum, options: .numeric) == .orderedAscending
    }

    func refresh() async {
        guard let config = await AppConfigService.shared.fetch() else {
            required = nil
            return
        }
        required = Self.isOutdated(installed: Self.installedVersion, minimum: config.minimumVersion)
            ? config
            : nil
    }
}
