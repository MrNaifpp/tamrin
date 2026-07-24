//
//  LoginOnbord.swift
//  Sirr
//
//  Created by naif ali alshahrani on 12/08/1447 AH.
//

import SwiftUI


struct LoginOnbord: View {
    @ObservedObject var vm: AuthViewModel
    var onNavigateToLogin: (() -> Void)?

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Container: 60% of page, rounded bottom-left and bottom-right
                    let containerHeight = geometry.size.height * 0.65
                    let containerWidth = geometry.size.width
                    ZStack {
                        // Icons – fixed x and y positions
                        Text("⚽")
                            .font(.system(size: 54))
                            .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
                            .position(x: containerWidth * 0.22, y: containerHeight * 0.34)
                        Text("🎾")
                            .font(.system(size: 46))
                            .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)
                            .position(x: containerWidth * 0.48, y: containerHeight * 0.24)
                        Text("🏀")
                            .font(.system(size: 50))
                            .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)
                            .position(x: containerWidth * 0.28, y: containerHeight * 0.50)
                        Text("🏃")
                            .font(.system(size: 52))
                            .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)
                            .position(x: containerWidth * 0.78, y: containerHeight * 0.30)
                        Text("🚴")
                            .font(.system(size: 48))
                            .shadow(color: .black.opacity(0.1), radius: 6, x: 0, y: 3)
                            .position(x: containerWidth * 0.74, y: containerHeight * 0.54)
                        // Text block (centered, on top of icons)
                        VStack(spacing: 6) {
                            Spacer(minLength: 0)
                            Text("تمريــن")
                                .font(.subheadline)
                                .foregroundStyle(Color(white: 0.45))
                            Text("تجربــة مثاليـــة")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundStyle(.black)
                            Text("لإدارة التماريـن")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundStyle(.black)
                            HStack(spacing: 2) {
                                Text("تبـدأ ")
                                    .foregroundStyle(.black)
                                Text("مـن هنـــا")
                                    .foregroundStyle(Color(red: 0.35, green: 0.72, blue: 0.45))
                            }
                            .font(.title)
                            .fontWeight(.bold)
                            .padding(.bottom, 24)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(true)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: containerHeight)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0,
                            bottomLeadingRadius: 32,
                            bottomTrailingRadius: 32,
                            topTrailingRadius: 0
                        )
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.85, green: 0.94, blue: 0.88),
                                    Color(red: 0.96, green: 0.97, blue: 0.96)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    )
                    .shadow(color: .black.opacity(0.12), radius: 16, x: 0, y: 8)
                    // Second area: dark charcoal background (rounded top)
                    VStack(spacing: 0) {
                        Text("أنشئ وسجِّل في التمارين بطريقة رائعة، وادفع أو اجمع القطة بسهولة.")
                            .font(.body)
                            .foregroundStyle(Color(.black.opacity(0.5)))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.top, 24)
                            .padding(.bottom, 20)

                        Button {
                            onNavigateToLogin?()
                        } label: {
                            Text("سجل بالبريد الالكتروني")
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: TamrinControlMetrics.actionHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .fill(Color.black)
                                )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)

                        Button {
                            Task { await vm.signInWithApple() }
                        } label: {
                            Group {
                                if vm.isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                } else {
                                    HStack(spacing: 8) {
                                        Image(systemName: "apple.logo")
                                            .font(.system(size: 18, weight: .medium))
                                        Text("المتابعة عبر Apple")
                                            .font(.headline)
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundStyle(.black)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: TamrinControlMetrics.actionHeight)
                            .background(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .fill(Color(white: 0.95))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.isLoading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 248/255.0, green: 248/255.0, blue: 247/255.0))
            }
            .ignoresSafeArea()
        }
    }
}

#Preview {
    LoginOnbord(vm: AuthViewModel())
}
