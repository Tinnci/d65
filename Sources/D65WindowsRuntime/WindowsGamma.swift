#if os(Windows)
import D65Display
import Foundation
import WinSDK

public enum WindowsGammaError: Error, CustomStringConvertible {
    case noDeviceContext(String)
    case readFailed(String)
    case writeFailed(String)
    public var description: String {
        switch self {
        case .noDeviceContext(let name): "could not open a device context for \(name)"
        case .readFailed(let name): "could not read the gamma ramp of \(name)"
        case .writeFailed(let name):
            "Windows refused the gamma ramp for \(name). It rejects ramps far from neutral unless " +
            "HKLM\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ICM\\GdiIcmGammaRange is 256; HDR mode ignores ramps"
        }
    }
}

/// The display's GDI gamma ramp (256 entries per channel), the Windows counterpart of the Mac's
/// transfer table. Unlike macOS, Windows does not reset the ramp when the process exits, so every
/// change must be restored explicitly; the engine always does.
public struct WindowsGammaBackend: TransferTableBackend {
    public let display: WindowsDisplay
    public init(display: WindowsDisplay) { self.display = display }

    public func probe() throws -> DisplayTransferSnapshot {
        var ramp = [UInt16](repeating: 0, count: 768)
        try withDeviceContext { dc in
            let ok = ramp.withUnsafeMutableBytes { GetDeviceGammaRamp(dc, $0.baseAddress) }
            guard ok else { throw WindowsGammaError.readFailed(display.deviceName) }
        }
        let channel = { (index: Int) in ramp[(index * 256)..<((index + 1) * 256)].map { Double($0) / 65535 } }
        return DisplayTransferSnapshot(displayID: display.id, red: channel(0), green: channel(1), blue: channel(2))
    }

    public func restore(_ snapshot: DisplayTransferSnapshot) throws {
        guard snapshot.displayID == display.id, snapshot.count > 0 else { throw WindowsGammaError.writeFailed(display.deviceName) }
        var ramp: [UInt16] = []
        ramp.reserveCapacity(768)
        for table in [snapshot.red, snapshot.green, snapshot.blue] {
            for index in 0..<256 {
                // Resample when the source table is not 256 long; the ramp format is fixed.
                let position = Double(index) / 255 * Double(table.count - 1)
                let lower = Int(position), upper = min(table.count - 1, lower + 1)
                let value = table[lower] + (table[upper] - table[lower]) * (position - Double(lower))
                ramp.append(UInt16(max(0, min(65535, (value * 65535).rounded()))))
            }
        }
        try withDeviceContext { dc in
            let ok = ramp.withUnsafeMutableBytes { SetDeviceGammaRamp(dc, $0.baseAddress) }
            guard ok else { throw WindowsGammaError.writeFailed(display.deviceName) }
        }
    }

    private func withDeviceContext(_ body: (HDC) throws -> Void) throws {
        guard let dc = display.deviceName.withWide({ CreateDCW($0, nil, nil, nil) }) else {
            throw WindowsGammaError.noDeviceContext(display.deviceName)
        }
        defer { DeleteDC(dc) }
        try body(dc)
    }
}
#endif
