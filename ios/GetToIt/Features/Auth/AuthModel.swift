import AuthenticationServices
import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class AuthModel {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(userID: UUID)
    }

    private(set) var state: State = .loading
    var errorMessage: String?
    private var currentNonce: String?

    /// Follows the stored session and every sign-in or sign-out after it.
    func listen() async {
        for await (_, session) in await Backend.client.auth.authStateChanges {
            if let session {
                state = .signedIn(userID: session.user.id)
            } else {
                state = .signedOut
            }
        }
    }

    /// Called by SignInWithAppleButton before Apple's sheet appears.
    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Nonce.random()
        currentNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Nonce.sha256(nonce)
    }

    func complete(_ result: Result<ASAuthorization, Error>) async {
        errorMessage = nil
        do {
            guard
                let credential = try result.get().credential as? ASAuthorizationAppleIDCredential,
                let tokenData = credential.identityToken,
                let idToken = String(data: tokenData, encoding: .utf8),
                let nonce = currentNonce
            else {
                errorMessage = "Apple didn't send a sign-in token. Try again."
                return
            }

            let session = try await Backend.client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            )

            // Apple shares the name only on the very first sign-in, so save it then.
            if let name = credential.fullName {
                let fullName = PersonNameComponentsFormatter().string(from: name)
                if !fullName.isEmpty {
                    try? await Backend.client
                        .from("profiles")
                        .update(["display_name": fullName])
                        .eq("id", value: session.user.id.uuidString)
                        .execute()
                }
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // The user closed Apple's sheet. Nothing to report.
        } catch {
            errorMessage = "Sign-in didn't go through. \(error.localizedDescription)"
        }
    }

    func signOut() async {
        try? await Backend.client.auth.signOut()
    }
}
