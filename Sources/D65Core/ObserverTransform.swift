import Foundation

/// Relative spectral power of a display's three primaries, each measured on its full-drive patch.
///
/// A three-primary display only ever emits mixtures of these three spectra, so they fix the exact
/// 3×3 relation between any two observers' XYZ for that display (see `ObserverTransform`). Only the
/// spectral shape matters; each primary's scale is free.
public struct PrimarySpectra: Codable, Sendable, Equatable {
    public let wavelengths: [Double]
    public let red: [Double]
    public let green: [Double]
    public let blue: [Double]
    /// Where the data came from, e.g. the imported file's name.
    public var source: String

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case noRows
        case badRow(line: Int)
        case unevenSteps
        case stepTooCoarse(Double)
        case insufficientRange(ClosedRange<Double>)
        case negativeValue(line: Int)
        case emptyPrimary(String)

        public var description: String {
            switch self {
            case .noRows: "No spectral rows found. Expected lines of: wavelength, red, green, blue."
            case .badRow(let line): "Line \(line) isn't four numbers: wavelength, red, green, blue."
            case .unevenSteps: "Wavelengths must rise in equal steps."
            case .stepTooCoarse(let step): "A \(step) nm step is too coarse; use 10 nm or finer."
            case .insufficientRange(let range): "The data covers \(Int(range.lowerBound))–\(Int(range.upperBound)) nm; it must cover at least 400–700 nm."
            case .negativeValue(let line): "Line \(line) has a negative power; zero or positive values only."
            case .emptyPrimary(let name): "The \(name) primary has no power anywhere."
            }
        }
    }

    public init(wavelengths: [Double], red: [Double], green: [Double], blue: [Double], source: String) throws {
        guard wavelengths.count >= 2, [red.count, green.count, blue.count].allSatisfy({ $0 == wavelengths.count }) else {
            throw ImportError.noRows
        }
        let step = wavelengths[1] - wavelengths[0]
        guard step > 0, zip(wavelengths, wavelengths.dropFirst()).allSatisfy({ abs(($1 - $0) - step) < 1e-6 }) else {
            throw ImportError.unevenSteps
        }
        guard step <= 10 else { throw ImportError.stepTooCoarse(step) }
        let range = wavelengths[0]...wavelengths[wavelengths.count - 1]
        guard range.lowerBound <= 400, range.upperBound >= 700 else { throw ImportError.insufficientRange(range) }
        for (name, values) in [("red", red), ("green", green), ("blue", blue)] where !values.contains(where: { $0 > 0 }) {
            throw ImportError.emptyPrimary(name)
        }
        self.wavelengths = wavelengths; self.red = red; self.green = green; self.blue = blue; self.source = source
    }

    /// Lines of `wavelength,red,green,blue` (comma, tab or space separated). Lines starting with
    /// `#` and a non-numeric header row are skipped.
    public init(csv text: String, source: String) throws {
        var wavelengths: [Double] = [], red: [Double] = [], green: [Double] = [], blue: [Double] = []
        for (index, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: { $0 == "," || $0 == "\t" || $0 == " " || $0 == ";" }).map(String.init)
            let values = fields.compactMap(Double.init)
            if wavelengths.isEmpty, values.count != fields.count { continue } // header
            guard fields.count == 4, values.count == 4, values.allSatisfy(\.isFinite) else { throw ImportError.badRow(line: index + 1) }
            guard values[1...].allSatisfy({ $0 >= 0 }) else { throw ImportError.negativeValue(line: index + 1) }
            wavelengths.append(values[0]); red.append(values[1]); green.append(values[2]); blue.append(values[3])
        }
        guard !wavelengths.isEmpty else { throw ImportError.noRows }
        try self.init(wavelengths: wavelengths, red: red, green: green, blue: blue, source: source)
    }

    public var range: ClosedRange<Double> { wavelengths[0]...wavelengths[wavelengths.count - 1] }

    /// Linear interpolation onto the CIE 1 nm grid; zero outside the measured range.
    func power(_ channel: Int, at nanometres: Double) -> Double {
        let values = [red, green, blue][channel]
        guard range.contains(nanometres) else { return 0 }
        let step = wavelengths[1] - wavelengths[0]
        let position = (nanometres - wavelengths[0]) / step
        let lower = min(Int(position.rounded(.down)), wavelengths.count - 1)
        let upper = min(lower + 1, wavelengths.count - 1)
        let t = position - Double(lower)
        return values[lower] * (1 - t) + values[upper] * t
    }
}

/// The exact relation between two observers' XYZ for one three-primary display.
///
/// For such a display every colour is `P · w` for primary weights `w`, where `P`'s columns are the
/// primaries' tristimulus values under the observer. So `XYZ_to = P_to · P_from⁻¹ · XYZ_from`. A probe
/// that reports CIE 1931 XYZ can therefore steer to a white that another observer sees as D65.
public enum ObserverTransform {
    public enum TransformError: Error, Equatable {
        case missingObserverData(Observer)
        case degeneratePrimaries
    }

    /// Columns are the red, green and blue primaries' XYZ under `observer`.
    public static func primaryMatrix(_ spectra: PrimarySpectra, observer: Observer) throws -> Matrix3x3 {
        guard let functions = CIESpectralData.functions(for: observer) else { throw TransformError.missingObserverData(observer) }
        var columns = [[Double]](repeating: [0, 0, 0], count: 3)
        for row in functions {
            for channel in 0..<3 {
                let power = spectra.power(channel, at: row[0])
                guard power > 0 else { continue }
                for component in 0..<3 { columns[channel][component] += power * row[component + 1] }
            }
        }
        let matrix = Matrix3x3([
            columns[0][0], columns[1][0], columns[2][0],
            columns[0][1], columns[1][1], columns[2][1],
            columns[0][2], columns[1][2], columns[2][2],
        ])
        guard matrix.inverted() != nil else { throw TransformError.degeneratePrimaries }
        return matrix
    }

    /// `XYZ_to = matrix · XYZ_from` for this display.
    public static func matrix(from: Observer, to: Observer, spectra: PrimarySpectra) throws -> Matrix3x3 {
        guard from != to else { return .identity }
        let source = try primaryMatrix(spectra, observer: from)
        guard let inverse = source.inverted() else { throw TransformError.degeneratePrimaries }
        return try primaryMatrix(spectra, observer: to).multiplied(by: inverse)
    }

    /// The chromaticity, in the probe's observer, this display's white must have for `viewer` to see D65.
    public static func target(measuredIn probe: Observer, d65For viewer: Observer, spectra: PrimarySpectra) throws -> Chromaticity {
        guard let d65 = viewer.d65 else { throw TransformError.missingObserverData(viewer) }
        guard probe != viewer else { return d65 }
        let white = try matrix(from: viewer, to: probe, spectra: spectra).multiplied(by: d65.xyz())
        guard let chromaticity = white.chromaticity else { throw TransformError.degeneratePrimaries }
        return chromaticity
    }
}
