import Foundation

/// Unmodified CIE source tables are bundled for offline, reproducible target calculation.
/// Provenance, licensing and validation are in Resources/CIE/README.md and scripts/check_cie_data.py.
enum CIESpectralData {
    enum DataError: Error { case missingResource(String), invalidTable, missingSpectrum }

    static let spectrum = try? load("CIE_std_illum_D65.csv", columns: 2, wavelengths: 300...830)
    static let twoDegreeD65 = try? d65(using: "CIE_cfb_stv_2deg.csv")
    static let tenDegreeD65 = try? d65(using: "CIE_cfb_stv_10deg.csv")

    static func resource(_ filename: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: filename, withExtension: nil, subdirectory: "CIE") else {
            throw DataError.missingResource(filename)
        }
        return try Data(contentsOf: url)
    }

    static func load(_ filename: String, columns: Int, wavelengths: ClosedRange<Int>) throws -> [[Double]] {
        let data = try resource(filename)
        guard let text = String(data: data, encoding: .utf8) else { throw DataError.invalidTable }
        return try parse(text, columns: columns, wavelengths: wavelengths)
    }

    /// Require the complete integer-nanometre grid; no interpolation, NaN filling or extrapolation.
    static func parse(_ text: String, columns: Int, wavelengths: ClosedRange<Int>) throws -> [[Double]] {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count == wavelengths.count else { throw DataError.invalidTable }
        return try zip(wavelengths, lines).map { wavelength, line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            let values = fields.compactMap { Double($0) }
            guard fields.count == columns, values.count == columns,
                  values.allSatisfy({ $0.isFinite && $0 >= 0 }), values[0] == Double(wavelength) else {
                throw DataError.invalidTable
            }
            return values
        }
    }

    private static func d65(using filename: String) throws -> XYZ {
        guard let spectrum else { throw DataError.missingSpectrum }
        let functions = try load(filename, columns: 4, wavelengths: 390...830)
        return try integrate(functions: functions, spectrum: spectrum)
    }

    /// Standard equal-step summation: Σ S(λ) CMF(λ) Δλ, normalized to Y=1.
    /// CMFs are supplied only on 390...830 nm. The D65 SPD covers this whole interval exactly.
    static func integrate(functions: [[Double]], spectrum: [[Double]]) throws -> XYZ {
        guard !functions.isEmpty, !spectrum.isEmpty else { throw DataError.invalidTable }
        var byWavelength: [Double: Double] = [:]
        for row in spectrum {
            guard row.count == 2, row.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  byWavelength.updateValue(row[1], forKey: row[0]) == nil else { throw DataError.invalidTable }
        }
        var sums = [Double](repeating: 0, count: 3)
        var previousWavelength: Double?
        for row in functions {
            guard row.count == 4, row.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  previousWavelength.map({ row[0] == $0 + 1 }) ?? true,
                  let energy = byWavelength[row[0]] else { throw DataError.invalidTable }
            for channel in 0..<3 { sums[channel] += energy * row[channel + 1] }
            previousWavelength = row[0]
        }
        guard sums.allSatisfy(\.isFinite), sums[1] > 0 else { throw DataError.invalidTable }
        return XYZ(x: sums[0] / sums[1], y: 1, z: sums[2] / sums[1])
    }
}
