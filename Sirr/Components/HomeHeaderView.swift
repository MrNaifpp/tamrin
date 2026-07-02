//
//  HomeHeaderView.swift
//  Sirr
//
//  Home header: hamburger (opens the groups drawer) · "التمارين القادمة" pill
//  (pushes the upcoming page) · profile avatar. With zero groups only the
//  avatar shows — there is no drawer or schedule to open yet.
//

import SwiftUI

struct HomeHeaderView: View {
    let avatarUrl: String?
    let showsGroupControls: Bool
    var onMenu: () -> Void
    var onUpcoming: () -> Void
    var onProfile: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if showsGroupControls {
                circleButton(action: onMenu) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            Spacer()

            if showsGroupControls {
                Button(action: onUpcoming) {
                    HStack(spacing: 6) {
                        Text("التمارين القادمة")
                            .font(.appCallout)
                            .foregroundStyle(.white)
                        Image(systemName: "chevron.forward") // points left in RTL, matching the mockup
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(Capsule().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            circleButton(action: onProfile) {
                profileAvatar
            }
        }
        .padding(.horizontal, 16)
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func circleButton<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var profileAvatar: some View {
        if let urlString = avatarUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.gray.opacity(0.7))
                @unknown default:
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Color.gray.opacity(0.7))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

#Preview {
    ZStack {
        Color.black
        VStack {
            HomeHeaderView(
                avatarUrl: nil,
                showsGroupControls: true,
                onMenu: {}, onUpcoming: {}, onProfile: {}
            )
            Spacer()
        }
    }
}
