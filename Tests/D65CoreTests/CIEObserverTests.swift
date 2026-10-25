import CryptoKit
import XCTest
@testable import D65Core

final class CIEObserverTests: XCTestCase {
    func testBundledDatasetsMatchOfficialCIEChecksumsAndMetadata() throws {
        let sources = [
            ("CIE_xyz_1931_2deg.csv", "_metadata.json", "17cca777db64b17170f06f67ce9d3ab7",
             "fa663e3535a7e0763a745993a1f0a192eb0275ac46ad2d1befd7626841e713c1"),
            ("CIE_cfb_stv_2deg.csv", "_metadata.json", "472cc50b14a6cf41ba9f08f8935aedc8",
             "a10751ec8aecdb023f16ba079557e7fb794806884fe3da982dd63da285f872a9"),
            ("CIE_cfb_stv_10deg.csv", "_metadata.json", "c8504e70d7f4760253a0a4d3a42b7d20",
             "9019a35f8f51215e245f818e87d4251147d1925a8fbe9a49944fe7f011f16e38"),
            ("CIE_std_illum_D65.csv", "_metadata_v2.json", "03d4eb9b837c60671627c946fb534deb",
             "e76f210bffff3d552ef7113025da5f325d5dfec200dd4b878b1a2f3a507032cb")
        ]
        for (filename, suffix, md5, sha256) in sources {
            let data = try CIESpectralData.resource(filename)
            XCTAssertEqual(Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined(), md5)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), sha256)
            let metadata = try JSONDecoder().decode(Metadata.self, from: CIESpectralData.resource(filename + suffix))
            XCTAssertEqual(metadata.checksums.first { $0.hashMethod == "md5" }?.checksum, md5)
            XCTAssertEqual(metadata.checksums.first { $0.hashMethod == "sha256" }?.checksum, sha256)
        }
    }

    func testD65TargetsMatchIndependentDecimalIntegration() throws {
        // Python Decimal summation of the checked source tables, not rounded published xy values.
        let expected: [(Observer, Double, Double, Double, Double)] = [
            (.cie2015TwoDegree, 0.9475535585704792, 1.0754043433613863, 0.3134524493261819, 0.3308018280244443),
            (.cie2015TenDegree, 0.9472085246870145, 1.0714337379222504, 0.3137862794872099, 0.3312747629577068)
        ]
        for (observer, x, z, chromaX, chromaY) in expected {
            let target = try XCTUnwrap(observer.d65)
            let xyz = target.xyz()
            XCTAssertEqual(xyz.x, x, accuracy: 1e-13)
            XCTAssertEqual(xyz.y, 1)
            XCTAssertEqual(xyz.z, z, accuracy: 1e-13)
            XCTAssertEqual(target.x, chromaX, accuracy: 1e-14)
            XCTAssertEqual(target.y, chromaY, accuracy: 1e-14)
        }
        XCTAssertEqual(Observer.cie1931TwoDegree.d65, .d65, "preserve the existing rounded sRGB white")
        XCTAssertNotEqual(Observer.cie2015TwoDegree.d65, Observer.cie2015TenDegree.d65)
    }

    func testEveryObserversD65IsNeutralInItsOwnMetricReference() throws {
        for observer in Observer.allCases {
            let target = try XCTUnwrap(observer.d65)
            let lab = Lab(xyz: target.xyz(), white: target.xyz())
            XCTAssertEqual(lab.a, 0, accuracy: 1e-12)
            XCTAssertEqual(lab.b, 0, accuracy: 1e-12)
            for metric in WhiteErrorMetric.allCases {
                XCTAssertEqual(metric.whiteError(target.xyz(luminance: 142), target: target), 0, accuracy: 1e-10)
            }
            let sample = Chromaticity(x: target.x - 0.003, y: target.y - 0.002).xyz()
            XCTAssertEqual(WhiteErrorMetric.ciede2000.whiteError(sample, target: target),
                           ColorDifference.deltaE00(sample, target.xyz(), white: target.xyz()), accuracy: 1e-12)
        }
    }

    func testIntegrationUsesAlignedOneNanometreSummationAndNormalizesY() throws {
        let functions = [[390.0, 1, 0, 0], [391.0, 0, 1, 0], [392.0, 0, 0, 1]]
        let spectrum = [[390.0, 2], [391.0, 3], [392.0, 5]]
        let result = try CIESpectralData.integrate(functions: functions, spectrum: spectrum)
        XCTAssertEqual(result.x, 2.0 / 3, accuracy: 1e-15)
        XCTAssertEqual(result.y, 1)
        XCTAssertEqual(result.z, 5.0 / 3, accuracy: 1e-15)
        XCTAssertThrowsError(try CIESpectralData.integrate(functions: functions, spectrum: Array(spectrum.dropLast())))
        XCTAssertThrowsError(try CIESpectralData.integrate(functions: functions, spectrum: [[390, 0], [391, 0], [392, 0]]))
        XCTAssertThrowsError(try CIESpectralData.integrate(functions: functions, spectrum: spectrum + [[390, 2]]))
    }

    func testInvalidTablesAreRejectedRatherThanSilentlyRepaired() {
        let invalid = ["390,1,2,3\n392,1,2,3", "390,1,2,3\n390,1,2,3", "390,NaN,2,3\n391,1,2,3",
                       "390,1,2\n391,1,2,3", "390,-1,2,3\n391,1,2,3", "390,1,2,3"]
        for text in invalid {
            XCTAssertThrowsError(try CIESpectralData.parse(text, columns: 4, wavelengths: 390...391))
        }
    }
}

private struct Metadata: Decodable {
    struct Checksum: Decodable { let hashMethod: String; let checksum: String }
    let checksums: [Checksum]
}
