/// Monochrome mask of a rendered sprite, cropped to its opaque pixels plus 1 px of padding.
public struct Silhouette: Sendable {
    public var width: Int
    public var height: Int
    public var on: [Bool]

    /// `outlineOnly` keeps opaque pixels that touch transparency (a hollow outline).
    public static func mask(_ r: RenderedFrame, outlineOnly: Bool) -> Silhouette {
        var minX = r.width, minY = r.height, maxX = -1, maxY = -1
        for y in 0..<r.height { for x in 0..<r.width where r.isOpaque(x: x, y: y) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= 0 else { return Silhouette(width: 1, height: 1, on: [false]) }
        let w = maxX - minX + 3, h = maxY - minY + 3
        var on = [Bool](repeating: false, count: w * h)
        for y in minY...maxY { for x in minX...maxX where r.isOpaque(x: x, y: y) {
            let edge = !r.isOpaque(x: x - 1, y: y) || !r.isOpaque(x: x + 1, y: y)
                || !r.isOpaque(x: x, y: y - 1) || !r.isOpaque(x: x, y: y + 1)
            if !outlineOnly || edge { on[(y - minY + 1) * w + (x - minX + 1)] = true }
        } }
        return Silhouette(width: w, height: h, on: on)
    }

    /// Paints a 5×5 attention dot in the top-right corner of an RGBA buffer.
    public static func dot(into data: UnsafeMutablePointer<UInt8>, width w: Int, height h: Int) {
        let pattern = [0, 1, 1, 1, 0]
        for dy in 0..<5 { for dx in 0..<5 {
            let corner = (dy == 0 || dy == 4) && (dx == 0 || dx == 4)
            guard !corner || pattern[dx] == 1, dx < w, dy < h else { continue }
            data[(dy * w + (w - 5 + dx)) * 4 + 3] = 255
        } }
    }
}
