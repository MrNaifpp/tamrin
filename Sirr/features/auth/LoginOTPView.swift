//
//  LoginOTPView.swift
//  Sirr
//
//  OTP verification page after email entry.
//

import SwiftUI

struct LoginOTPView: View {
    let email: String
    @ObservedObject var vm: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var otpCode = ""
    @FocusState private var isOTPFocused: Bool

    private let pageBackground = Color(red: 248/255.0, green: 248/255.0, blue: 247/255.0)
    private let otpDigitCount = 6

    var body: some View {
        ZStack {
            pageBackground
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // Title (match pic: ادخل رمز التفعيل)
                    Text("ادخل رمز التفعيل")
                        .font(.appTitle)
                        .foregroundStyle(Color(white: 0.2))
                    Text("أرسلنا لك رمز تفعيل على بريدك")
                        .font(.appBody)
                        .foregroundStyle(Color(white: 0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Text(email)
                        .font(TamrinFont.font(size: 18, weight: .medium))
                        .foregroundStyle(Color(white: 0.3))

                    // OTP input: 6 slots with dashed lines in one rounded container (LTR fill)
                    OTPInputView(otpCode: $otpCode, digitCount: otpDigitCount, isFocused: $isOTPFocused)
                        .environment(\.layoutDirection, .leftToRight)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                    if let error = vm.errorMessage {
                        Text(error)
                            .font(.appCaption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 24)
                    }

                    // Resend
                    Button {
                        Task {
                            await vm.requestOTP(email: email)
                        }
                    } label: {
                        Text("إعادة إرسال الرمز")
                            .font(.appBody)
                            .foregroundStyle(Color(white: 0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(vm.isLoading)
                    .padding(.top, 12)

                    Spacer(minLength: 24)
                }
            }
            // Next: verify OTP with API, then app shows signup (new user) or home
            .safeAreaInset(edge: .bottom) {
                TamrinActionButton(title: "التالي", isLoading: vm.isLoading, tint: .black) {
                    Task {
                        await vm.verifyOTP(email: email, token: otpCode)
                    }
                }
                .disabled(otpCode.count < otpDigitCount)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
            }
        }
        .onAppear {
            Task {
                await vm.requestOTP(email: email)
            }
        }
        .onChange(of: otpCode) { _, newValue in
            if newValue.count == otpDigitCount, !vm.isLoading {
                Task {
                    await vm.verifyOTP(email: email, token: newValue)
                }
            }
        }
    }
}

// MARK: - 6-slot OTP input with dashed placeholders (like reference image)
private struct OTPInputView: View {
    @Binding var otpCode: String
    let digitCount: Int
    var isFocused: FocusState<Bool>.Binding

    private let slotSpacing: CGFloat = 8
    private let boxBackground = Color(white: 0.92)
    private let dashColor = Color(white: 0.7)

    private var filteredOTPBinding: Binding<String> {
        Binding(
            get: { otpCode },
            set: { newValue in
                // `isNumber` would happily keep ٠٧٧٠٦٨ — six characters that
                // look like a code, show as Arabic-Indic in the slots, and are
                // rejected by the server as an invalid token. Fold to ASCII
                // instead of filtering, so the code shown is the code sent.
                otpCode = String(newValue.asciiDigits.prefix(digitCount))
            }
        )
    }

    var body: some View {
        ZStack(alignment: .center) {
            // Single light gray rounded container
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(boxBackground)
                .frame(height: 64)

            // Six slots: digit or dashed line
            HStack(spacing: slotSpacing) {
                ForEach(0..<digitCount, id: \.self) { index in
                    ZStack {
                        if index < otpCode.count {
                            let i = otpCode.index(otpCode.startIndex, offsetBy: index)
                            Text(String(otpCode[i]))
                                .font(TamrinFont.font(size: 28, weight: .medium))
                                .foregroundStyle(Color(white: 0.2))
                        } else {
                            Circle()
                                .fill(dashColor)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                }
            }
            .padding(.horizontal, 20)

            // Hidden TextField for input (captures tap and keyboard)
            TextField("", text: filteredOTPBinding)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused(isFocused)
                .opacity(0.02)
                .frame(height: 64)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            isFocused.wrappedValue = true
        }
    }
}

#Preview {
    NavigationStack {
        LoginOTPView(email: "mohammed@gmail.com", vm: AuthViewModel())
    }
}
