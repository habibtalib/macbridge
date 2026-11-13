import Foundation

/// What two devices say to each other through the signaling server while
/// setting up a session. The server forwards these without reading them.
public enum SignalPayload: Equatable, Sendable {
    /// Controller → host: please start a session with me.
    case request
    /// Host → controller.
    case offer(sdp: String)
    /// Controller → host.
    case answer(sdp: String)
    case candidate(sdp: String, mLineIndex: Int32, mid: String?)
    /// Either side: the session is over.
    case bye
}

extension SignalPayload: Codable {
    private enum Kind: String, Codable { case request, offer, answer, candidate, bye }
    private enum CodingKeys: String, CodingKey { case kind, sdp, mLineIndex, mid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .request: self = .request
        case .offer: self = .offer(sdp: try c.decode(String.self, forKey: .sdp))
        case .answer: self = .answer(sdp: try c.decode(String.self, forKey: .sdp))
        case .candidate:
            self = .candidate(
                sdp: try c.decode(String.self, forKey: .sdp),
                mLineIndex: try c.decode(Int32.self, forKey: .mLineIndex),
                mid: try c.decodeIfPresent(String.self, forKey: .mid)
            )
        case .bye: self = .bye
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .request:
            try c.encode(Kind.request, forKey: .kind)
        case let .offer(sdp):
            try c.encode(Kind.offer, forKey: .kind)
            try c.encode(sdp, forKey: .sdp)
        case let .answer(sdp):
            try c.encode(Kind.answer, forKey: .kind)
            try c.encode(sdp, forKey: .sdp)
        case let .candidate(sdp, mLineIndex, mid):
            try c.encode(Kind.candidate, forKey: .kind)
            try c.encode(sdp, forKey: .sdp)
            try c.encode(mLineIndex, forKey: .mLineIndex)
            try c.encodeIfPresent(mid, forKey: .mid)
        case .bye:
            try c.encode(Kind.bye, forKey: .kind)
        }
    }
}
