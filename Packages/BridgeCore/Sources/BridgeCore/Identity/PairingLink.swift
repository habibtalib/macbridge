import Foundation

/// What the Mac's pairing QR code holds: the code and the server it is waiting on,
/// so a new iPhone or iPad can go online and pair from one scan.
/// `macbridge://pair?code=XXXX-XXXX-XXXX-XXXX&server=ws%3A%2F%2Fhost%3A8787`
public struct PairingLink: Equatable, Sendable {
    public var code: String
    public var server: String?

    public init(code: String, server: String?) {
        self.code = code
        self.server = server
    }

    public var url: URL? {
        var parts = URLComponents()
        parts.scheme = "macbridge"
        parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "code", value: code)]
        if let server, !server.isEmpty { parts.queryItems?.append(URLQueryItem(name: "server", value: server)) }
        return parts.url
    }

    /// Reads a scanned or opened link, or a bare pairing code (older Macs show only the code).
    /// A server that is not a ws:// or wss:// address is dropped.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if PairingCode(trimmed) != nil {
            self.init(code: trimmed, server: nil)
            return
        }
        guard let parts = URLComponents(string: trimmed), parts.scheme?.lowercased() == "macbridge",
              parts.host?.lowercased() == "pair",
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value, PairingCode(code) != nil
        else { return nil }
        let server = parts.queryItems?.first(where: { $0.name == "server" })?.value
        self.init(code: code, server: server.flatMap { BridgeModel.parseServerURL($0) != nil ? $0 : nil })
    }
}
