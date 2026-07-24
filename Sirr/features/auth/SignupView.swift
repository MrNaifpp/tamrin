//
//  SignupView.swift
//  Sirr
//
//  Created by naif ali alshahrani on 11/08/1447 AH.
//

import SwiftUI
import PhotosUI
import UIKit

/// Preferred position options for the signup form.
private enum PreferredPosition: String, CaseIterable {
    case goalkeeper = "حارس"
    case defense = "دفاع"
    case midfield = "وسط"
    case attack = "هجوم"
}

struct SignupView: View {
    @ObservedObject var vm: AuthViewModel
    var onBack: (() -> Void)?
    /// When true, user already signed in via OTP — show "Continue to home" instead of signup form.
    var isPostOTP: Bool = false
    var onComplete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var fullName = ""
    @State private var preferredPosition: PreferredPosition = .midfield
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?

    private let pageBackground = Color(red: 248/255.0, green: 248/255.0, blue: 247/255.0)

    private var isFormValid: Bool {
        !fullName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        signupFormView
    }

    private var postOTPContinueView: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.55, green: 0.23, blue: 0.36),
                    Color(red: 0.10, green: 0.30, blue: 0.23)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer(minLength: 48)
                Text("مرحباً")
                    .font(.appTitle)
                    .foregroundStyle(.white)
                Text("أكمل إنشاء حسابك أو انتقل إلى الصفحة الرئيسية")
                    .font(.appBody)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Spacer(minLength: 24)

                Button {
                    onComplete?()
                } label: {
                    Text("التالي - الصفحة الرئيسية")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: TamrinControlMetrics.actionHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 25, style: .continuous)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 48)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private var signupFormView: some View {
        ZStack {
            pageBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Avatar (center) — same as LoginView
                        PhotosPicker(selection: $selectedItem, matching: .images) {
                            ZStack {
                                Circle()
                                    .fill(Color(white: 0.88))
                                    .frame(width: 120, height: 120)
                                if let data = selectedImageData, let uiImage = UIImage(data: data) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 120)
                                        .clipShape(Circle())
                                } else {
                                    Image(systemName: "person.fill")
                                        .font(.system(size: 48))
                                        .foregroundStyle(Color(white: 0.65))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .onChange(of: selectedItem) { newItem in
                            Task {
                                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                                    selectedImageData = data
                                }
                            }
                        }
                        .padding(.top, 16)

                        // Title: كمــل ملفـك الشخـصي
                        Text("كمــل ملفـك الشخـصي")
                            .font(.appHeadline)
                            .foregroundStyle(Color(white: 0.2))

                        // Full name — اسـم الكريـم
                        VStack(alignment: .leading, spacing: 8) {
                            Text("اسـم الكريـم")
                                .font(.appBody)
                                .foregroundStyle(Color(white: 0.5))
                            TextField("", text: $fullName, prompt: Text("اسـم الكريـم").foregroundColor(Color(white: 0.6)))
                                .font(.appBody)
                                .foregroundStyle(Color(white: 0.2))
                                .padding(.horizontal, 18)
                                .frame(height: 56)
                                .background(
                                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                                        .fill(Color(white: 0.92))
                                )
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                        // Preferred position — المركـز المفضـل — select حارس دفاع وسط هجوم
                        VStack(alignment: .leading, spacing: 8) {
                            Text("المركـز المفضـل")
                                .font(.appBody)
                                .foregroundStyle(Color(white: 0.5))
                            Menu {
                                ForEach(PreferredPosition.allCases, id: \.self) { position in
                                    Button(position.rawValue) {
                                        preferredPosition = position
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(preferredPosition.rawValue)
                                        .font(.appBody)
                                        .foregroundStyle(Color(white: 0.2))
                                    Spacer(minLength: 12)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Color(white: 0.45))
                                }
                                .padding(.horizontal, 18)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .fill(Color(white: 0.92))
                            )
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                        // Back to login link
                        Button(action: {
                            if let onBack {
                                onBack()
                            } else {
                                dismiss()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Text("لديك حساب بالفعل؟")
                                    .foregroundStyle(Color(white: 0.5))
                                Text("تسجيل الدخول")
                                    .font(.appBodySemibold)
                                    .foregroundStyle(Color(white: 0.3))
                            }
                            .font(.appBody)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isLoading)
                        .padding(.top, 16)

                        Spacer(minLength: 24)
                    }
                }

                // Next button: create user record (auth + profile) then app shows main page
                Button {
                    Task {
                        await vm.completeProfile(
                            fullName: fullName.trimmingCharacters(in: .whitespaces),
                            preferredPosition: preferredPosition.rawValue,
                            imageData: selectedImageData
                        )
                    }
                } label: {
                    Group {
                        if vm.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("التالي")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: TamrinControlMetrics.actionHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                            .fill(isFormValid ? Color(red: 92/255, green: 92/255, blue: 92/255) : Color(white: 0.25))
                    )
                }
                .buttonStyle(.plain)
                .disabled(vm.isLoading || !isFormValid)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .scrollDismissesKeyboard(.interactively)
        .navigationBarBackButtonHidden(true)
        .onAppear { vm.errorMessage = nil }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    if let onBack {
                        onBack()
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SignupView(vm: AuthViewModel(), onBack: {})
    }
}
