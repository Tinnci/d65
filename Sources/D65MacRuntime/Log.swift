#if os(macOS)
import os

/// Unified-log categories for the Mac host. Read them with
/// `log stream --predicate 'subsystem == "dev.tinnci.d65"' --level info`.
///
/// Levels: `notice` for things that happened once and should survive on disk (launch, quit,
/// corrections, sessions); `info` for context that helps explain a later error; `debug` for
/// per-sample and per-frame detail; `error` when an operation failed; `fault` for a broken invariant.
/// Display names, IDs, states and error codes are public; phone names and paths stay private.
public enum Log {
    public static let subsystem = "dev.tinnci.d65"
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    public static let display = Logger(subsystem: subsystem, category: "display")
    public static let correction = Logger(subsystem: subsystem, category: "correction")
    public static let ddc = Logger(subsystem: subsystem, category: "ddc")
    public static let session = Logger(subsystem: subsystem, category: "session")
    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let store = Logger(subsystem: subsystem, category: "store")
}
#endif
