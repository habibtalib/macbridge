import CryptoKit
import Foundation

/// A device this Mac has paired with.
public struct PairedDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var publicKey: Data
    public var name: String
    /// True on the Mac that showed the pairing code: the other device was
    /// given the right to control this one. Pairing does not grant the reverse.
    public var mayControlThisMac: Bool

    public init(id: String, publicKey: Data, name: String, mayControlThisMac: Bool) {
        self.id = id
        self.publicKey = publicKey
        self.name = name
        self.mayControlThisMac = mayControlThisMac
    }
}

/// One-time pairing.
///
/// The Mac to be controlled shows a 16-character code. The code is an 80-bit
/// secret: typing it into the other Mac proves the person is looking at this
/// screen. Both Macs derive an encryption key from it and use that key to
/// exchange their public keys through the signaling server. The server sees
/// only a lookup tag and ciphertext, so it can neither read the keys nor swap
/// in its own, and 80 bits is far beyond guessing in the code's lifetime.
public struct PairingCode: Equatable, Sendable {
    public static let lifetime: TimeInterval = 10 * 60

    private let secret: Data

    public init() {
        secret = Data((0..<10).map { _ in UInt8.random(in: .min ... .max) })
    }

    /// Parses what the user typed: case, spaces and dashes are ignored, and
    /// the letters Crockford leaves out are read as the digits they resemble.
    public init?(_ text: String) {
        let cleaned = text.uppercased().compactMap { character -> Character? in
            switch character {
            case "-", " ": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return character
            }
        }
        guard cleaned.count == 16, let secret = Base32.decode(String(cleaned), alphabet: Base32.crockford),
              secret.count == 10 else { return nil }
        self.secret = secret
    }

    /// `XXXX-XXXX-XXXX-XXXX`
    public var display: String {
        DeviceID.grouped(Base32.encode(secret, alphabet: Base32.crockford))
    }

    /// What the server uses to route the pairing messages. Reveals nothing
    /// useful about the code.
    public var tag: String {
        derive("tag", bytes: 8).map { String(format: "%02x", $0) }.joined()
    }

    private var key: SymmetricKey { SymmetricKey(data: derive("key", bytes: 32)) }

    private func derive(_ purpose: String, bytes: Int) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data("macbridge-pair-v1".utf8),
            info: Data(purpose.utf8),
            outputByteCount: bytes
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    // MARK: - Messages

    public enum Side: String, Sendable {
        /// The Mac that typed the code and will control the other.
        case controller
        /// The Mac that showed the code and will be controlled.
        case host
    }

    public struct Introduction: Codable, Equatable, Sendable {
        public var publicKey: Data
        public var name: String

        public init(publicKey: Data, name: String) {
            self.publicKey = publicKey
            self.name = name
        }
    }

    /// Encrypts this device's introduction for the other side.
    public func seal(_ introduction: Introduction, from side: Side) -> Data? {
        guard let plaintext = try? JSONEncoder().encode(introduction),
              let box = try? ChaChaPoly.seal(plaintext, using: key, authenticating: Data(side.rawValue.utf8))
        else { return nil }
        return box.combined
    }

    /// Decrypts the other side's introduction. Fails unless it was sealed with
    /// the same code by the expected side, so a message cannot be reflected
    /// back to its sender.
    public func open(_ sealed: Data, from side: Side) -> Introduction? {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed),
              let plaintext = try? ChaChaPoly.open(box, using: key, authenticating: Data(side.rawValue.utf8)),
              let introduction = try? JSONDecoder().decode(Introduction.self, from: plaintext),
              introduction.publicKey.count == 32, introduction.name.count <= 128
        else { return nil }
        return introduction
    }
}
