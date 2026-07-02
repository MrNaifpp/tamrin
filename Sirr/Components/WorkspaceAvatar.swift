//
//  WorkspaceAvatar.swift
//  Sirr
//
//  Colored-initial square used everywhere a group needs an identity.
//  The hue is derived from the group id so it is stable across launches.
//

import SwiftUI

struct WorkspaceAvatar: View {
    let name: String
    let id: UUID
    var size: CGFloat = 34

    private var color: Color {
        // Stable across launches: hashValue is per-process randomized, so
        // derive the hue from the UUID's raw bytes instead.
        let bytes = withUnsafeBytes(of: id.uuid) { $0.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } }
        let hue = Double(bytes % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.75)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)))
                    .font(.system(size: size * 0.45, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}
