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
        case .malformedResponse: "The store returned an unexpected or incomplete response. Please retry."
        case .storage(let detail): "Playden couldn’t access your saved sign-in. Unlock your Mac and retry. (\(detail))"
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
/// For stores without an account: no identity, and sign-in is unavailable.
public struct NoSourceAuth: SourceAuth {
    public init() {}
    public func identity() async throws -> SourceIdentity? { nil }
    public func signInWithQR(onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    public func signIn(accountName: String, password: String,
                       codeProvider: @escaping @Sendable (GuardChallenge) async throws -> String,
                       onEvent: @escaping @Sendable (AuthenticationEvent) -> Void) async throws -> SourceIdentity { throw SourceFailure.unavailable }
    public func cancelSignIn() async {}
    public func signOut() async throws {}
}
public protocol GameSource: Sendable {
    var id: String { get }
    var displayName: String { get }
    var auth: any SourceAuth { get }
    var capabilities: SourceCapabilities { get }
    func ownedGames() async throws -> [SourceGameRecord]
    func metadata(for game: SourceGameRecord) async throws -> SourceGameRecord
    func downloadSizeAccountKey() async throws -> String?
    func downloadSize(for game: SourceGameRecord) async throws -> DownloadSizeEstimate?
    func installer(for game: SourceGameRecord) throws -> any Installer
    func storePageURL(for id: GameID) -> URL?
    func storePageAllows(host: String) -> Bool
    func artworkFallbacks(for id: GameID) -> [URL]
    func externalInstallations(for games: [SourceGameRecord]) async throws -> [InstallationRecord]
    func locate(_ installation: InstallationRecord) async throws -> URL
}
public extension GameSource {
    var capabilities: SourceCapabilities { SourceCapabilities(account: .steam, acquisition: .download) }
    func downloadSizeAccountKey() async throws -> String? { nil }
    func downloadSize(for game: SourceGameRecord) async throws -> DownloadSizeEstimate? { nil }
    /// Public store page; nil hides the action.
    func storePageURL(for id: GameID) -> URL? { nil }
    /// Hosts the store page may navigate within.
    func storePageAllows(host: String) -> Bool { false }
    /// Art tried after the record's own cover fails.
    func artworkFallbacks(for id: GameID) -> [URL] { [] }
    /// External sources report the installations they found; Playden never owns these files.
    func externalInstallations(for games: [SourceGameRecord]) async throws -> [InstallationRecord] { [] }
    /// Resolves an external installation to its app, wherever it is now.
    func locate(_ installation: InstallationRecord) async throws -> URL { throw ExternalLocationFailure.missing }
}
