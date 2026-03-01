//
//  EditProfileSheet.swift
//  Sirr
//
//  Edit profile full-screen sheet: same behavior as add event page (toolbar, dismiss).
//

import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#endif

struct EditProfileSheet: View {
    @ObservedObject var authVM: AuthViewModel
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImageData: Data?

    private let sheetBackground = Color(white: 0.18)

    var body: some View {
        NavigationStack {
            ZStack {
                sheetBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // Title and description
                        Text("عدل حسابك")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                        Text("عرف بنفسك، هذا اسمك وصورتك اللي بيشوفونها الناس.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(white: 0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.top, 4)

                        // Avatar picker (circle + pencil)
                        PhotosPicker(selection: $selectedItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                ZStack {
                                    Circle()
                                        .fill(Color(white: 0.28))
                                        .frame(width: 120, height: 120)
                                    if let data = selectedImageData, let uiImage = UIImage(data: data) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 120, height: 120)
                                            .clipShape(Circle())
                                    } else if let urlString = authVM.currentProfile?.avatarUrl, let url = URL(string: urlString) {
                                        AsyncImage(url: url) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image
                                                    .resizable()
                                                    .scaledToFill()
                                            case .failure, .empty:
                                                Image(systemName: "person.fill")
                                                    .font(.system(size: 48))
                                                    .foregroundStyle(Color(white: 0.5))
                                            @unknown default:
                                                Image(systemName: "person.fill")
                                                    .font(.system(size: 48))
                                                    .foregroundStyle(Color(white: 0.5))
                                            }
                                        }
                                        .frame(width: 120, height: 120)
                                        .clipShape(Circle())
                                    } else {
                                        Image(systemName: "person.fill")
                                            .font(.system(size: 48))
                                            .foregroundStyle(Color(white: 0.5))
                                    }
                                }
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 36, height: 36)
                                    .overlay {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                    .offset(x: -4, y: -4)
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
                        .padding(.top, 24)

                        // Name text field
                        TextField("", text: $name, prompt: Text("الاسم").foregroundColor(Color(white: 0.5)))
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(white: 0.25))
                            )
                            .padding(.horizontal, 24)
                            .padding(.top, 24)

                        // Save button
                        Button {
                            Task {
                                await authVM.updateProfile(
                                    name: name.trimmingCharacters(in: .whitespaces),
                                    position: authVM.currentProfile?.position ?? "",
                                    imageData: selectedImageData
                                )
                                if authVM.errorMessage == nil {
                                    isPresented = false
                                    dismiss()
                                }
                            }
                        } label: {
                            Text("حفظ")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 52)
                                .background(
                                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                                        .fill(Color.white)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(authVM.isLoading)
                        .padding(.horizontal, 24)
                        .padding(.top, 28)
                        .padding(.bottom, 32)
                    }
                }
            }
            .environment(\.layoutDirection, .rightToLeft)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isPresented = false
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .toolbarBackground(sheetBackground, for: .navigationBar)
            .onAppear {
                Task {
                    await authVM.loadCurrentProfile()
                    name = authVM.currentProfile?.name ?? ""
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    EditProfileSheet(authVM: AuthViewModel(), isPresented: .constant(true))
}
#endif
