import Foundation

/// Display identity is transient. Account identifiers and tokens belong to the credential boundary.
public struct SourceIdentity: Equatable, Sendable {
    public let sourceID: String
    public let displayName: String
    public init(sourceID: String, displayName: String) { self.sourceID = sourceID; self.displayName = displayName }
}
public enum GuardChallenge: Equatable, Sendable { case authenticator, email }
public enum AuthenticationEvent: Equatable, Sendable {
    case qrChallenge(URL, expiresAt: Date)
    case awaitingApproval
    case expired
}
public enum SourceFailure: Error, Equatable, Sendable, LocalizedError {
    case signedOut, expired, accessDenied, network, throttled, credentialsRejected, cancelled, unavailable, malformedResponse, storage(String)
    public var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in to refresh your library."
        case .expired: "Your sign-in has expired. Sign in again to continue."
        case .accessDenied: "Steam denied access to the requested content. Retry, or check that your account owns this edition."
        case .network: "The store can’t be reached. Check your connection and try again."
        case .throttled: "The store is receiving too many requests. Wait a moment, then retry."
        case .credentialsRejected: "The store couldn’t verify those details. Check your account name, password or code."
        case .cancelled: "Sign-in was cancelled."
        case .unavailable: "The store couldn’t complete the request. Try again shortly."
        case .malformedResponse: "The store returned an incomplete library. Your cached games have been kept."
        case .storage(let detail): "Big Screen couldn’t access your saved sign-in. Unlock your Mac and retry. (\(detail))"
        }
    }
}
public protocol SourceAuth: Sendable {
    func identity() async throws -> SourceIdentity?
    func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity
    func signIn(accountName: String, password: String,
                codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity
    func cancelSignIn() async
    func signOut() async throws
}
public protocol GameSource: Sendable {
    var id: String { get }
    var displayName: String { get }
    var auth: any SourceAuth { get }
    func ownedGames() async throws -> [SourceGameRecord]
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord
    func installer(for game: SourceGameRecord) throws -> any Installer
}
