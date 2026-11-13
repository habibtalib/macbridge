import Foundation

/// Proof, attached to session setup messages, that they come from the paired
/// device and not from the signaling server or anyone else on it.
///
/// - A `request` is signed with a timestamp. The host accepts it only from a
///   device allowed to control it, only if it is fresh, and only if it is newer
///   than the last one from that device, so a recorded request cannot be replayed.
/// - An `offer` or `answer` is signed over the DTLS certificate fingerprints in
///   its SDP. WebRTC refuses a connection whose certificate does not match the
///   SDP, so a valid signature means the encrypted channel ends at the paired
///   device. Replaying an old offer or answer is useless: its certificate's
///   private key existed only in that earlier session.
/// - ICE candidates and `bye` are not signed; they cannot redirect or read a
///   session, only disturb it, which the server could do anyway.
public struct SignalAuth: Codable, Equatable, Sendable {
    public var signature: Data
    /// Milliseconds since 1970; only meaningful on a `request`.
    public var timestamp: Int64?

    private enum CodingKeys: String, CodingKey {
        case signature = "sig"
        case timestamp = "ts"
    }
}

public enum SessionAuth {
    /// How far a request's clock may differ from ours.
    public static let requestWindow: TimeInterval = 60

    public enum Failure: Error, Equatable {
        case unsigned
        case badSignature
        case stale
        case replayed
        case noFingerprint
    }

    /// Signs `payload` for sending from `identity` to `peerID`.
    /// Returns nil for payloads that travel unsigned.
    public static func sign(
        _ payload: SignalPayload, to peerID: String, identity: Identity, now: Date = Date()
    ) -> SignalAuth? {
        let timestamp: Int64? = payload == .request ? Int64(now.timeIntervalSince1970 * 1000) : nil
        guard let message = message(for: payload, from: identity.deviceID, to: peerID, timestamp: timestamp) else {
            return nil
        }
        return SignalAuth(signature: identity.sign(message), timestamp: timestamp)
    }

    /// Checks a payload received from `peer`. Payloads that travel unsigned pass.
    ///
    /// - Parameter lastRequestTimestamp: the newest request timestamp already
    ///   accepted from this peer, if any.
    /// - Returns: the request's timestamp when the payload is a request, for
    ///   the caller to remember.
    @discardableResult
    public static func verify(
        _ payload: SignalPayload, auth: SignalAuth?, from peer: PairedDevice, to ownID: String,
        lastRequestTimestamp: Int64? = nil, now: Date = Date()
    ) throws -> Int64? {
        switch payload {
        case .candidate, .bye:
            return nil
        case .request, .offer, .answer:
            break
        }
        guard let auth else { throw Failure.unsigned }
        if case .offer = payload, fingerprints(in: payload).isEmpty { throw Failure.noFingerprint }
        if case .answer = payload, fingerprints(in: payload).isEmpty { throw Failure.noFingerprint }
        guard let message = message(for: payload, from: peer.id, to: ownID, timestamp: auth.timestamp),
              Identity.verify(auth.signature, of: message, publicKey: peer.publicKey) else {
            throw Failure.badSignature
        }
        guard payload == .request else { return nil }
        guard let timestamp = auth.timestamp else { throw Failure.badSignature }
        let age = abs(now.timeIntervalSince1970 - Double(timestamp) / 1000)
        guard age <= requestWindow else { throw Failure.stale }
        if let lastRequestTimestamp, timestamp <= lastRequestTimestamp { throw Failure.replayed }
        return timestamp
    }

    /// The bytes that get signed. Sender and receiver IDs are included so a
    /// signature made for one pair of devices means nothing to another.
    private static func message(for payload: SignalPayload, from: String, to: String, timestamp: Int64?) -> Data? {
        let body: String
        switch payload {
        case .request:
            guard let timestamp else { return nil }
            body = "request|\(timestamp)"
        case .offer:
            body = "offer|" + fingerprints(in: payload).joined(separator: ",")
        case .answer:
            body = "answer|" + fingerprints(in: payload).joined(separator: ",")
        case .candidate, .bye:
            return nil
        }
        return Data("macbridge-signal-v1|\(from)|\(to)|\(body)".utf8)
    }

    /// Every `a=fingerprint:` value in the SDP, lower-cased, sorted and
    /// de-duplicated. These are the certificates WebRTC will accept.
    static func fingerprints(in payload: SignalPayload) -> [String] {
        let sdp: String
        switch payload {
        case let .offer(text), let .answer(text): sdp = text
        default: return []
        }
        let prefix = "a=fingerprint:"
        let values = sdp.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return Array(Set(values)).sorted()
    }
}
