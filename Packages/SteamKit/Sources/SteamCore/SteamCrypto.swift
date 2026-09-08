import Foundation
import Security
import CommonCrypto
import CryptoKit

public enum SteamCrypto {

    // MARK: RSA (password encryption for login)

    /// Encrypts `message` with RSA-PKCS1 using a public key given as hex modulus +
    /// hex exponent (the format IAuthenticationService/GetPasswordRSAPublicKey returns).
    public static func rsaEncryptPKCS1(message: Data, modulusHex: String, exponentHex: String) throws -> Data {
        guard let modulus = Data(hexString: modulusHex), let exponent = Data(hexString: exponentHex) else {
            throw SteamError.crypto("bad RSA key hex")
        }
        // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
        let der = derSequence([derInteger(modulus), derInteger(exponent)])
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw SteamError.crypto("SecKeyCreateWithData: \(error.map { String(describing: $0.takeRetainedValue()) } ?? "?")")
        }
        guard let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, message as CFData, &error) else {
            throw SteamError.crypto("RSA encrypt: \(error.map { String(describing: $0.takeRetainedValue()) } ?? "?")")
        }
        return cipher as Data
    }

    private static func derInteger(_ raw: Data) -> Data {
        var body = raw
        while body.count > 1 && body.first == 0 { body.removeFirst() }  // strip leading zeros
        if let first = body.first, first & 0x80 != 0 { body.insert(0, at: body.startIndex) }
        var out = Data([0x02])
        out.append(derLength(body.count))
        out.append(body)
        return out
    }

    private static func derSequence(_ parts: [Data]) -> Data {
        let body = parts.reduce(Data(), +)
        var out = Data([0x30])
        out.append(derLength(body.count))
        out.append(body)
        return out
    }

    private static func derLength(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    // MARK: Steam symmetric scheme (depot chunks, encrypted manifest filenames)

    /// Steam's symmetric encryption: the first 16 bytes are the AES-256-ECB-encrypted
    /// IV; the remainder is AES-256-CBC(iv) with PKCS7 padding.
    public static func symmetricDecrypt(_ data: Data, key: Data) throws -> Data {
        guard data.count > 16, key.count == 32 else {
            throw SteamError.crypto("symmetricDecrypt: bad input (\(data.count) bytes, key \(key.count))")
        }
        let iv = try aes(data.subdata(in: data.startIndex..<data.startIndex + 16),
                         key: key, iv: nil, options: CCOptions(kCCOptionECBMode), operation: CCOperation(kCCDecrypt))
        let body = try aes(data.subdata(in: data.startIndex + 16..<data.endIndex),
                           key: key, iv: iv, options: 0, operation: CCOperation(kCCDecrypt))
        // CBC used PKCS7 padding but CommonCrypto only strips it when asked; do it manually
        // so ECB (no padding) and CBC can share one helper.
        guard let pad = body.last, pad >= 1, pad <= 16, body.count >= Int(pad) else {
            throw SteamError.crypto("symmetricDecrypt: bad padding")
        }
        return body.subdata(in: body.startIndex..<body.endIndex - Int(pad))
    }

    private static func aes(_ data: Data, key: Data, iv: Data?, options: CCOptions, operation: CCOperation) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    if let iv {
                        return iv.withUnsafeBytes { ivPtr in
                            CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                                    keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                    dataPtr.baseAddress, data.count,
                                    outPtr.baseAddress, outPtr.count, &written)
                        }
                    }
                    return CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                                   keyPtr.baseAddress, key.count, nil,
                                   dataPtr.baseAddress, data.count,
                                   outPtr.baseAddress, outPtr.count, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw SteamError.crypto("CCCrypt status \(status)") }
        return out.prefix(written)
    }

    public static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }
}

public extension Data {
    init?(hexString: String) {
        let hex = hexString.count % 2 == 0 ? hexString : "0" + hexString
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
