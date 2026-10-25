import D65Core
import Foundation

/// Imported primary spectra, one set per display identity (versioned JSON). A display's spectra
/// depend on its panel, not its mode, so they are keyed by identity alone.
@MainActor public final class PrimarySpectraStore {
    private struct File: Codable { var schemaVersion = 1; var spectra: [String: PrimarySpectra] }
    public let url: URL
    public private(set) var spectra: [String: PrimarySpectra] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data),
           file.schemaVersion == 1 {
            spectra = file.spectra
        }
    }

    public func spectra(for displayIdentity: String) -> PrimarySpectra? { spectra[displayIdentity] }

    public func save(_ value: PrimarySpectra, for displayIdentity: String) throws {
        spectra[displayIdentity] = value
        try write()
    }

    public func remove(for displayIdentity: String) throws {
        spectra[displayIdentity] = nil
        try write()
    }

    private func write() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(spectra: spectra)).write(to: url, options: .atomic)
    }
}
