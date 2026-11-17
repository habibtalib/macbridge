import Foundation

/// One line in the record of who controlled this Mac and when.
public struct SessionLogEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var deviceID: String
    public var deviceName: String
    public var started: Date
    public var ended: Date?

    public init(id: UUID = UUID(), deviceID: String, deviceName: String, started: Date, ended: Date? = nil) {
        self.id = id
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.started = started
        self.ended = ended
    }
}
