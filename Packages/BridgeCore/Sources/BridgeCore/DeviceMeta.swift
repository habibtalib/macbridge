import Foundation

/// What this Mac remembers about a paired device beyond the pairing itself.
/// Kept apart from `PairedDevice`, so pairing data stays as it was.
public struct DeviceMeta: Codable, Equatable, Sendable {
    /// A name chosen on this Mac, shown instead of the device's own.
    public var alias: String?
    public var isFavourite = false
    /// When this Mac last controlled the device.
    public var lastConnected: Date?
    /// Ask on this Mac before the device may start a session.
    public var asksFirst = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        isFavourite = try c.decodeIfPresent(Bool.self, forKey: .isFavourite) ?? false
        lastConnected = try c.decodeIfPresent(Date.self, forKey: .lastConnected)
        asksFirst = try c.decodeIfPresent(Bool.self, forKey: .asksFirst) ?? false
    }
}

/// What the text in the connect field means.
public enum ConnectInput: Equatable, Sendable {
    case empty
    /// Names one paired Mac: Return connects to it.
    case device(PairedDevice)
    /// A pairing code shown by another Mac.
    case pairingCode(String)
    /// Anything else narrows the list.
    case search

    /// `names`: the name each device is shown under (alias or own name), by ID.
    public static func parse(_ text: String, devices: [PairedDevice], names: [String: String] = [:]) -> ConnectInput {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .empty }
        let matches = filter(devices, query, names: names)
        let id = normalizedID(query)
        if let exact = devices.first(where: { $0.id == id || (names[$0.id] ?? $0.name).caseInsensitiveCompare(query) == .orderedSame }) {
            return .device(exact)
        }
        if matches.isEmpty, PairingCode(query) != nil { return .pairingCode(query) }
        if matches.count == 1 { return .device(matches[0]) }
        return .search
    }

    /// Devices whose name or ID contains the text.
    public static func filter(_ devices: [PairedDevice], _ text: String, names: [String: String] = [:]) -> [PairedDevice] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return devices }
        let id = normalizedID(query)
        return devices.filter {
            (names[$0.id] ?? $0.name).localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
                || (!id.isEmpty && $0.id.contains(id))
        }
    }

    private static func normalizedID(_ text: String) -> String {
        text.lowercased().filter { $0 != "-" && $0 != " " }
    }
}
