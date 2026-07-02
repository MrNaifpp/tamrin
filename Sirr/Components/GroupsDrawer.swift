//
//  GroupsDrawer.swift
//  Sirr
//
//  Slide-in "المجموعات" panel (replaces the old half-sheet switcher).
//  Dark panel enters from the leading edge over a dimmed home. The blue +
//  creates a workout in the current group; "مجموعة جديدة" creates a group;
//  the gear opens the current group's settings (which also hosts logout).
//

import SwiftUI

struct GroupsDrawer: View {
    @Binding var isPresented: Bool
    let workspaces: [WorkspaceRecord]
    let currentId: UUID?
    var onSelect: (WorkspaceRecord) -> Void
    var onNewWorkout: () -> Void
    var onNewGroup: () -> Void
    var onOpenSettings: () -> Void

    /// Drag offset while the user swipes the panel toward the edge.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let panelWidth = geometry.size.width * 0.82

            ZStack(alignment: .leading) {
                // Dim layer — tap to close.
                if isPresented {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { close() }
                }

                // Panel. In RTL, .leading is the right edge — matching the mockup.
                panel(width: panelWidth, height: geometry.size.height)
                    .offset(x: isPresented ? dragOffset : -panelWidth)
                    .animation(.spring(response: 0.35, dampingFraction: 0.86), value: isPresented)
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // In RTL, dragging toward the leading edge closes.
                        let translation = value.translation.width
                        dragOffset = translation > 0 ? 0 : max(-panelWidth, translation)
                    }
                    .onEnded { value in
                        if value.translation.width < -panelWidth * 0.3 {
                            close()
                        }
                        dragOffset = 0
                    }
            )
        }
        .environment(\.layoutDirection, .rightToLeft)
        .allowsHitTesting(isPresented)
        .opacity(isPresented ? 1 : 0)
    }

    private func close() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            isPresented = false
        }
    }

    private func panel(width: CGFloat, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title row: "المجموعات" + blue + (new workout in current group).
            HStack {
                Text("المجموعات")
                    .font(.appSubheadline)
                    .foregroundStyle(.white)
                Spacer()
                if currentId != nil {
                    Button {
                        close()
                        onNewWorkout()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(workspaces) { ws in
                        groupRow(ws)
                    }
                    newGroupRow
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
            }

            // Gear → combined settings of the current group (+ logout).
            HStack {
                Button {
                    close()
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(width: width, height: height)
        .background(Color(white: 0.07))
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: 0,
                bottomTrailingRadius: 28, topTrailingRadius: 28,
                style: .continuous
            )
        )
        .ignoresSafeArea(edges: .vertical)
    }

    private func groupRow(_ ws: WorkspaceRecord) -> some View {
        Button {
            close()
            onSelect(ws)
        } label: {
            HStack(spacing: 12) {
                WorkspaceAvatar(name: ws.name, id: ws.id, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ws.name)
                        .font(.appBodyMedium)
                        .foregroundStyle(.white)
                    if let count = ws.memberCount {
                        Text("الأعضاء \(count)")
                            .font(.appCaption)
                            .foregroundStyle(Color(white: 0.6))
                    }
                }
                Spacer()
                if ws.id == currentId {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(ws.id == currentId ? .white.opacity(0.16) : .white.opacity(0.07))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newGroupRow: some View {
        Button {
            close()
            onNewGroup()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: "plus").foregroundStyle(.white))
                Text("مجموعة جديدة")
                    .font(.appBodyMedium)
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white.opacity(0.07))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    struct DrawerPreview: View {
        @State var shown = true
        var body: some View {
            ZStack {
                Color.gray.ignoresSafeArea()
                GroupsDrawer(
                    isPresented: $shown,
                    workspaces: [],
                    currentId: nil,
                    onSelect: { _ in }, onNewWorkout: {}, onNewGroup: {}, onOpenSettings: {}
                )
            }
        }
    }
    return DrawerPreview()
}
