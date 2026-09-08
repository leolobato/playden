import Foundation

/// Steam EResult codes we care about; anything else is reported numerically.
/// Full list: https://partner.steamgames.com/doc/api/steam_api#EResult
public struct EResult: RawRepresentable, Equatable, Sendable, CustomStringConvertible {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let ok = EResult(rawValue: 1)
    public static let fail = EResult(rawValue: 2)
    public static let invalidPassword = EResult(rawValue: 5)
    public static let invalidParam = EResult(rawValue: 8)
    public static let fileNotFound = EResult(rawValue: 9)
    public static let busy = EResult(rawValue: 10)
    public static let accessDenied = EResult(rawValue: 15)
    public static let timeout = EResult(rawValue: 16)
    public static let serviceUnavailable = EResult(rawValue: 20)
    public static let tryAnotherCM = EResult(rawValue: 48)
    public static let rateLimitExceeded = EResult(rawValue: 84)
    public static let expired = EResult(rawValue: 27)
    public static let duplicateRequest = EResult(rawValue: 29)
    public static let accountLoginDeniedThrottle = EResult(rawValue: 87)

    public var description: String {
        switch self {
        case .ok: return "OK"
        case .fail: return "Fail"
        case .invalidPassword: return "InvalidPassword"
        case .invalidParam: return "InvalidParam"
        case .fileNotFound: return "FileNotFound"
        case .busy: return "Busy"
        case .accessDenied: return "AccessDenied"
        case .timeout: return "Timeout"
        case .serviceUnavailable: return "ServiceUnavailable"
        case .tryAnotherCM: return "TryAnotherCM"
        case .rateLimitExceeded: return "RateLimitExceeded"
        case .expired: return "Expired"
        case .duplicateRequest: return "DuplicateRequest"
        case .accountLoginDeniedThrottle: return "AccountLoginDeniedThrottle"
        default: return "EResult(\(rawValue))"
        }
    }
}

public enum SteamError: Error, CustomStringConvertible {
    case http(status: Int, url: String)
    case eresult(EResult, context: String)
    case protocolError(String)
    case authFailed(String)
    case authSessionExpired
    case notLoggedIn
    case crypto(String)
    case download(String)
    case prepare(String)

    public var description: String {
        switch self {
        case .http(let status, let url): return "HTTP \(status) from \(url)"
        case .eresult(let r, let ctx): return "\(ctx): \(r)"
        case .protocolError(let s): return "protocol error: \(s)"
        case .authSessionExpired: return "login session expired before it was confirmed"
        case .authFailed(let s): return "authentication failed: \(s)"
        case .notLoggedIn: return "not logged in — run `steamcli login` first"
        case .crypto(let s): return "crypto error: \(s)"
        case .download(let s): return "download error: \(s)"
        case .prepare(let s): return "prepare error: \(s)"
        }
    }
}
