import Foundation
import EpicCore

// Developer tool: signs in with a code on this terminal and saves the launcher session for the live tests.
// Usage: epic-dev sign-in <session.json> | epic-dev check <session.json>

let arguments = CommandLine.arguments
guard arguments.count == 3, ["sign-in", "check"].contains(arguments[1]) else {
    print("usage: epic-dev sign-in|check <session.json>"); exit(2)
}
let url = URL(fileURLWithPath: arguments[2])
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
let auth = EpicAuth()

func save(_ session: EpicSession) throws {
    try encoder.encode(session).write(to: url, options: .atomic)
    chmod(url.path, 0o600)
}

do {
    var session: EpicSession
    if arguments[1] == "sign-in" {
        let authorization = try await auth.startDeviceAuthorization()
        print("Open \(authorization.completeVerificationURL.absoluteString)")
        print("or enter \(authorization.userCode) at \(authorization.verificationURL.absoluteString)")
        print("The page shows Fortnite branding; that's expected. Waiting up to \(Int(authorization.expiresAt.timeIntervalSinceNow / 60)) minutes…")
        fflush(stdout)
        session = try await auth.completeDeviceAuthorization(authorization)
        try save(session)
        print("Signed in as \(session.displayName). Saved \(url.path)")
    } else {
        session = try await auth.refresh(try decoder.decode(EpicSession.self, from: Data(contentsOf: url)))
        try save(session)
    }
    let api = EpicLibraryAPI()
    let assets = try await api.assets(platform: .windows, accessToken: session.accessToken)
    let library = try await api.libraryItems(accessToken: session.accessToken)
    let code = try await auth.exchangeCode(accessToken: session.accessToken)
    print("Windows assets: \(assets.count). Library items: \(library.count). Launch code: \(code.isEmpty ? "missing" : "ok")")
} catch EpicError.correctiveAction(let url) {
    print("Epic needs you to accept updated terms. Open \(url?.absoluteString ?? "https://www.epicgames.com") in a browser where you're signed in, accept, then run this again.")
    exit(1)
} catch {
    print("Failed: \(error.localizedDescription) (\(error))"); exit(1)
}
