import CryptoKit
import Foundation

/// This install's long-term signing key. The public half is what other
/// devices store when they pair; the device ID is derived from it, so an ID
/// cannot be claimed without the matching private key.
public struct Identity: Sendable {
    public let privateKey: Curve25519.Signing.PrivateKey

    public init(privateKey: Curve25519.Signing.PrivateKey = .init()) {
        self.privateKey = privateKey
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }
    public var deviceID: String { DeviceID.derive(fromPublicKey: publicKey) }

    public func sign(_ message: Data) -> Data {
        // Signing with a valid Ed25519 key does not fail in practice.
        (try? privateKey.signature(for: message)) ?? Data()
    }

    public static func verify(_ signature: Data, of message: Data, publicKey: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}

public enum DeviceID {
    /// 16 characters: the first 80 bits of SHA-256(public key), base32.
    /// The server computes the same value to check a device's claim.
    public static func derive(fromPublicKey publicKey: Data) -> String {
        Base32.encode(Data(SHA256.hash(data: publicKey).prefix(10)), alphabet: Base32.lowercase)
    }

    /// `abcd-efgh-ijkl-mnop`, easier to compare by eye.
    public static func grouped(_ id: String) -> String {
        stride(from: 0, to: id.count, by: 4).map { offset -> Substring in
            let start = id.index(id.startIndex, offsetBy: offset)
            return id[start..<(id.index(start, offsetBy: 4, limitedBy: id.endIndex) ?? id.endIndex)]
        }.joined(separator: "-")
    }
}

public enum Base32 {
    /// RFC 4648, lower case. Used for device IDs.
    public static let lowercase = Array("abcdefghijklmnopqrstuvwxyz234567")
    /// Crockford: no I, L, O or U, so codes survive being read aloud and typed.
    public static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func encode(_ data: Data, alphabet: [Character]) -> String {
        var output = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                output.append(alphabet[Int((buffer >> UInt32(bits)) & 31)])
            }
        }
        if bits > 0 {
            output.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)])
        }
        return output
    }

    /// Decodes whole bytes; returns nil on a character outside the alphabet.
    public static func decode(_ text: String, alphabet: [Character]) -> Data? {
        var output = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return output
    }
}
