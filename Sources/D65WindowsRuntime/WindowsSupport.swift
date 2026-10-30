#if os(Windows)
import Foundation
import WinSDK

// Small helpers shared by the Windows adapters.

/// A NUL-terminated UTF-16 copy of `string` that lives as long as the returned array.
func wide(_ string: String) -> [UInt16] { Array(string.utf16) + [0] }

/// Reads a fixed-size WCHAR array imported as a tuple (e.g. `szDevice`) up to its NUL.
func string<T>(fromWideTuple tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let units = raw.bindMemory(to: UInt16.self)
        let end = units.firstIndex(of: 0) ?? units.count
        return String(decoding: units[..<end], as: UTF16.self)
    }
}

/// Resolves a function from a system DLL at run time. Used for APIs whose headers are not part of
/// Swift's WinSDK module (dxva2, the DNS-SD service API, shcore).
func systemFunction<T>(_ library: String, _ name: String, as _: T.Type) -> T? {
    let module = wide(library).withUnsafeBufferPointer { LoadLibraryW($0.baseAddress) }
    guard let module, let address = GetProcAddress(module, name) else { return nil }
    return unsafeBitCast(address, to: T.self)
}

/// Runs `body` on the main actor from any thread, including a Win32 or Winsock callback thread.
func onMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

extension String {
    /// Calls `body` with a temporary NUL-terminated UTF-16 pointer.
    func withWide<R>(_ body: (UnsafePointer<UInt16>) -> R) -> R {
        let buffer = wide(self)
        return buffer.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
#endif
