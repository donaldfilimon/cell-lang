/// Swift bridge for Cell language host.
/// Minimal, C-callable surface so Zig can verify Swift linkage.

@_cdecl("cell_swift_probe")
public func cell_swift_probe() -> Int32 {
    // Avoid heavy Foundation dependency; pure Swift stdlib.
    let name = "cell-swift"
    return Int32(name.utf8.count)
}

/// Value type ≈ Cell `copy` ownership.
public struct CellValueBox: Equatable, Sendable {
    public var tag: Int64
    public var payload: Int64

    public init(tag: Int64, payload: Int64) {
        self.tag = tag
        self.payload = payload
    }
}
