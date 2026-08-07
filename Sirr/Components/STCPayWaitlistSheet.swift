//
//  STCPayWaitlistSheet.swift
//  Sirr
//
//  Shown when submit_payment returns seats_full. Lets the joiner add
//  themselves to the waitlist; when a seat opens, they get a push and can
//  try to claim the seat.
//

import SwiftUI

struct STCPayWaitlistSheet: View {
    let eventName: String
    let onJoin: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isJoining = false
    @State private var didJoin = false

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer().frame(height: 30)

                Image(systemName: "hourglass")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)

                Text("امتلأت المقاعد")
                    .font(TamrinFont.font(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 16)

                Text(eventName)
                    .font(TamrinFont.font(size: 15))
                    .foregroundStyle(Color(white: 0.7))
                    .padding(.top, 4)

                Text(didJoin
                     ? "أنت الآن في قائمة الانتظار. سنرسل لك تنبيهاً عندما يتوفر مقعد."
                     : "انضم لقائمة الانتظار، وسنرسل لك تنبيهاً عندما يلغي شخص ما حجزه.")
                    .font(TamrinFont.font(size: 15))
                    .foregroundStyle(Color(white: 0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 18)

                Spacer()

                Button {
                    guard !isJoining && !didJoin else {
                        dismiss()
                        return
                    }
                    Task {
                        isJoining = true
                        defer { isJoining = false }
                        await onJoin()
                        didJoin = true
                    }
                } label: {
                    HStack {
                        if isJoining {
                            ProgressView().tint(.black)
                        }
                        Text(didJoin ? "انضممت — حسنًا" : "انضم لقائمة الانتظار")
                            .font(TamrinFont.font(size: 17, weight: .bold))
                            .foregroundStyle(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.white)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isJoining)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
