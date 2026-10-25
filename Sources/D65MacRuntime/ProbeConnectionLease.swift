/// Admission is held until restoration completes, even when the TCP connection has disappeared.
@MainActor struct ProbeConnectionLease {
    private(set) var owner: ObjectIdentifier?
    mutating func claim(_ candidate: ObjectIdentifier) -> Bool {
        guard owner == nil else { return false }
        owner = candidate
        return true
    }
    mutating func release(_ candidate: ObjectIdentifier) {
        if owner == candidate { owner = nil }
    }
}
