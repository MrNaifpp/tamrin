//
//  AuthViewModel.swift
//  Sirr
//
//  Created by naif ali alshahrani on 11/08/1447 AH.
//

import Foundation
import Supabase
import Combine
import AuthenticationServices
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sirr", category: "Auth")

@MainActor
class AuthViewModel: ObservableObject {
    @Published var isAuthenticated = false
    /// When true, user just verified OTP and is new — show signup/onboarding instead of home.
    @Published var isNewUserAfterOTP = false
    @Published var errorMessage: String?
    @Published var isLoading = false
    /// Current user profile from users table (for edit profile sheet).
    @Published var currentProfile: UserRecord? = nil

    func login(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AuthService.shared.signIn(email: email, password: password)
            isAuthenticated = true
            logger.info("Login succeeded")
        } catch {
            logger.error("Login failed: \(error.localizedDescription)")
            if let urlError = error as? URLError { logger.error("URLError: \(String(describing: urlError))") }
            errorMessage = error.localizedDescription
        }
    }

    func signup(email: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AuthService.shared.signUp(email: email, password: password)
            isAuthenticated = true
            logger.info("Signup succeeded")
        } catch {
            logger.error("Signup failed: \(error.localizedDescription)")
            if let urlError = error as? URLError { logger.error("URLError: \(String(describing: urlError))") }
            errorMessage = error.localizedDescription
        }
    }

    func checkSession() async {
        do {
            let s = try await AuthService.shared.session()
            if s != nil {
                isAuthenticated = true
                logger.info("Check session succeeded (has session)")
            } else {
                logger.info("Check session succeeded (no session)")
            }
        } catch {
            logger.error("Check session failed: \(error.localizedDescription)")
        }
    }

    func requestOTP(email: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AuthService.shared.requestOTP(email: email)
            logger.info("Request OTP succeeded")
        } catch {
            logger.error("Request OTP failed: \(error.localizedDescription)")
            if let urlError = error as? URLError { logger.error("URLError: \(String(describing: urlError))") }
            if error.localizedDescription.lowercased().contains("magic link") {
                errorMessage = "تعذر إرسال رمز التفعيل. تأكد من تفعيل البريد في Supabase (SMTP أو Email)."
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func verifyOTP(email: String, token: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let isNewUser = try await AuthService.shared.verifyOTP(email: email, token: token)
            isAuthenticated = true
            isNewUserAfterOTP = isNewUser
            logger.info("Verify OTP succeeded (isNewUser: \(isNewUser))")
        } catch {
            logger.error("Verify OTP failed: \(error.localizedDescription)")
            if let urlError = error as? URLError { logger.error("URLError: \(String(describing: urlError))") }
            errorMessage = error.localizedDescription
        }
    }

    /// Launch native Apple sign-in sheet and exchange the identity token for a Supabase session.
    func signInWithApple() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let appleResult = try await AppleSignInCoordinator().signIn()
            let isNew = try await AuthService.shared.signInWithApple(
                idToken: appleResult.idToken,
                nonce: appleResult.nonce
            )
            isAuthenticated = true
            isNewUserAfterOTP = isNew
            logger.info("Apple sign-in succeeded (isNewUser: \(isNew))")
        } catch {
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue { return }
            logger.error("Apple sign-in failed: \(error.localizedDescription)")
            if let urlError = error as? URLError { logger.error("URLError: \(String(describing: urlError))") }
            errorMessage = "تعذر تسجيل الدخول عبر Apple. حاول مرة أخرى."
        }
    }

    /// Call when user finishes signup/onboarding after OTP so app shows home next.
    func clearNewUserAfterOTP() {
        isNewUserAfterOTP = false
    }

    /// Sign out and return to login flow (for testing and normal use).
    func logout() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await AuthService.shared.signOut()
            isAuthenticated = false
            isNewUserAfterOTP = false
            logger.info("Logout succeeded")
        } catch {
            logger.error("Logout failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Complete signup: ensure auth user (anonymous if needed), create profile, then go to main.
    func completeProfile(fullName: String, preferredPosition: String, imageData: Data?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let session = try? await AuthService.shared.session() else {
                logger.error("Complete profile failed: no session")
                errorMessage = "يجب تسجيل الدخول أولاً"
                return
            }
            var avatarUrl: String?
            if let imageData {
                avatarUrl = await AuthService.shared.uploadAvatar(userId: session.user.id, imageData: imageData)
            }
            try await AuthService.shared.createOrUpdateProfile(
                fullName: fullName,
                preferredPosition: preferredPosition,
                avatarUrl: avatarUrl
            )
            isAuthenticated = true
            isNewUserAfterOTP = false
            logger.info("Complete profile succeeded")
        } catch {
            logger.error("Complete profile failed: \(error.localizedDescription)")
            if let urlError = error as? URLError { logger.error("URLError: \(String(describing: urlError))") }
            errorMessage = error.localizedDescription
        }
    }

    /// Load current user profile from users table (for edit profile sheet).
    func loadCurrentProfile() async {
        do {
            currentProfile = try await AuthService.shared.getCurrentUserProfile()
            logger.info("Load current profile succeeded")
        } catch {
            logger.error("Load current profile failed: \(error.localizedDescription)")
            currentProfile = nil
        }
    }

    /// Save the user's STC Pay number on their profile. Pass the raw input the user typed;
    /// normalization happens here. Sets `errorMessage` on validation failure.
    func saveSTCPayNumber(rawInput: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        guard let canonical = STCPay.normalize(rawInput) else {
            errorMessage = "رقم STC Pay غير صالح"
            logger.error("Save STC Pay number failed: invalid input")
            return
        }
        do {
            try await AuthService.shared.updateSTCPayNumber(canonical)
            // Reflect locally without a roundtrip.
            if let profile = currentProfile {
                currentProfile = UserRecord(
                    userId: profile.userId,
                    name: profile.name,
                    position: profile.position,
                    avatarUrl: profile.avatarUrl,
                    stcPayNumber: canonical
                )
            }
            logger.info("Save STC Pay number succeeded")
        } catch {
            logger.error("Save STC Pay number failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Update profile (name, position, optional new avatar). Reloads currentProfile on success.
    func updateProfile(name: String, position: String, imageData: Data?) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let session = try? await AuthService.shared.session() else {
                logger.error("Update profile failed: no session")
                errorMessage = "يجب تسجيل الدخول أولاً"
                return
            }
            var avatarUrl: String? = currentProfile?.avatarUrl
            if let imageData {
                if let url = await AuthService.shared.uploadAvatar(userId: session.user.id, imageData: imageData) {
                    avatarUrl = url
                }
            }
            try await AuthService.shared.updateProfile(name: name, position: position, avatarUrl: avatarUrl)
            currentProfile = UserRecord(
                userId: session.user.id,
                name: name,
                position: position,
                avatarUrl: avatarUrl,
                stcPayNumber: currentProfile?.stcPayNumber
            )
            logger.info("Update profile succeeded")
        } catch {
            logger.error("Update profile failed: \(error.localizedDescription)")
            if let urlError = error as? URLError { logger.error("URLError: \(String(describing: urlError))") }
            errorMessage = error.localizedDescription
        }
    }
}
