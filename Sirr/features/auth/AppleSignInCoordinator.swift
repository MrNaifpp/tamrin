//
//  AppleSignInCoordinator.swift
//  Sirr
//

import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

@MainActor
final class AppleSignInCoordinator: NSObject {
    struct Result {
        let idToken: String
        let nonce: String
        let fullName: PersonNameComponents?
        let email: String?
    }

    private var continuation: CheckedContinuation<Result, Error>?
    private var currentNonce: String?
    private var retainCycleBreaker: AppleSignInCoordinator?

    func signIn() async throws -> Result {
        let raw = Self.randomNonce()
        currentNonce = raw

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(raw)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        retainCycleBreaker = self

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            controller.performRequests()
        }
    }

    private func finish(result: Result) {
        continuation?.resume(returning: result)
        continuation = nil
        retainCycleBreaker = nil
    }

    private func finish(error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
        retainCycleBreaker = nil
    }

    private static func randomNonce(length: Int = 32) -> String {
        precondition(length > 0)
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        var output = ""
        var remaining = length
        while remaining > 0 {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else { continue }
            if byte < charset.count {
                output.append(charset[Int(byte)])
                remaining -= 1
            }
        }
        return output
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = credential.identityToken,
            let idToken = String(data: tokenData, encoding: .utf8),
            let nonce = currentNonce
        else {
            finish(error: NSError(
                domain: "AppleSignIn",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Apple did not return a valid identity token"]
            ))
            return
        }
        finish(result: Result(
            idToken: idToken,
            nonce: nonce,
            fullName: credential.fullName,
            email: credential.email
        ))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(error: error)
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first(where: { $0.isKeyWindow }) ?? windows.first!
    }
}
