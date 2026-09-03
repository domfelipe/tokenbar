public struct FileCursor: Sendable, Codable, Equatable {
    public var offset: UInt64

    public init(offset: UInt64) {
        self.offset = offset
    }
}
