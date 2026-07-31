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
    @State private var showsOTP = false

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
            // Next: the stock iOS 26 action button, so the fill, press
            // animation and disabled treatment all come from the platform.
            .safeAreaInset(edge: .bottom) {
                TamrinActionButton(title: "التالي", tint: .black) {
                    showsOTP = true
                }
                .disabled(!isEmailValid)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .scrollDismissesKeyboard(.interactively)
        .navigationDestination(isPresented: $showsOTP) {
            LoginOTPView(email: trimmedEmail, vm: vm)
        }
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
