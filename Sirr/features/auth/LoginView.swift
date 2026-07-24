//
//  LoginView.swift
//  Sirr
//
//  Created by naif ali alshahrani on 11/08/1447 AH.
//

import SwiftUI
import PhotosUI
import UIKit

struct LoginView: View {
    @ObservedObject var vm: AuthViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?

    private let pageBackground = Color(red: 248/255.0, green: 248/255.0, blue: 247/255.0)

    private var trimmedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEmailValid: Bool {
        let pattern = #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
        return trimmedEmail.range(of: pattern, options: .regularExpression) != nil
    }

    init(vm: AuthViewModel) {
        self.vm = vm
    }

    var body: some View {
        ZStack {
            pageBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Avatar (center)
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

                        // Text: سجـل بالبريـد الالكتروني
                        Text("سجـل بالبريـد الالكتروني")
                            .font(.appHeadline)
                            .foregroundStyle(Color(white: 0.2))
                        Text("سجـل أو أنشئ حسابك بالبريـد الالكتروني")
                            .font(.appBody)
                            .foregroundStyle(Color(white: 0.5))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        // Email field
                        TextField("", text: $email, prompt: Text("example@example").foregroundColor(Color(white: 0.6)))
                            .font(.appBody)
                            .foregroundStyle(Color(white: 0.2))
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .padding(.horizontal, 18)
                            .frame(height: 56)
                            .background(
                                RoundedRectangle(cornerRadius: 32, style: .continuous)
                                    .fill(Color(white: 0.92))
                            )
                            .padding(.horizontal, 24)
                            .padding(.top, 8)

                        if let error = vm.errorMessage {
                            Text(error)
                                .font(.appCaption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 24)
                        }

                        Spacer(minLength: 24)
                    }
                }

                // Next button fixed at bottom (navigates to OTP when tapped)
                NavigationLink(destination: LoginOTPView(email: trimmedEmail, vm: vm)) {
                    Text("التالي")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: TamrinControlMetrics.actionHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .fill(isEmailValid ? Color(red: 92/255, green: 92/255, blue: 92/255) : Color(white: 0.25))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isEmailValid)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .scrollDismissesKeyboard(.interactively)
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
    }
}

#Preview {
    NavigationStack {
        LoginView(vm: AuthViewModel())
    }
}
