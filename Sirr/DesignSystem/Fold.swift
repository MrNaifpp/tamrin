import SwiftUI

extension GeometryProxy {
    /// The fold, in this proxy's space, while iPhone Duo stands half-open on
    /// a table with its hinge running across the screen.
    ///
    /// Apple's guidance for that pose: what people watch goes in the top
    /// region, what they touch goes in the bottom one, which rests on the
    /// table and doesn't wobble. Nil on every other device and pose, and
    /// before iOS 27.1.
    var tabletopFold: CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        return reservedRegions(kind: .division)
            .first { $0.isActive && $0.frame.width > $0.frame.height }?
            .frame
    }
}
