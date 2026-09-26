import AppKit

/// Ask's glyph: a speech bubble with three dots, its top-right corner left
/// open for two sparkles.
///
/// The bubble is SF Symbols' own `ellipsis.bubble`, drawn the way the toolbar
/// draws `text.bubble` and `bubble.left.and.bubble.right` beside it, so the
/// three are one family: the same outline, line and size, measured rather than
/// copied. The layout follows the picture the user chose, in shares of the
/// bubble's outer width: the big sparkle's horizontal axis on the top line,
/// its right point on the right line's axis; the small sparkle on that axis,
/// over where the right line starts; the top line ending short of the big one.
/// One colour, as the glyphs beside it are: the toolbar's, or the accent while
/// the panel is open.
///
/// The page's marks in the margin take the same drawing as a mask
/// (`maskDataURL`), so they show the very same sign.
enum AskGlyph {
    /// How the toolbar draws its symbols. Measured against `text.bubble` there:
    /// 18 × 17 points of ink, which body text at the large scale gives.
    static let toolbar = NSImage.SymbolConfiguration(textStyle: .body, scale: .large)

    // Shares of the bubble's outer width, measured off the picture.
    private static let bigRadius: CGFloat = 0.199
    private static let smallRadius: CGFloat = 0.09
    /// The small sparkle's centre, below the frame's outer top.
    private static let smallDrop: CGFloat = 0.21
    /// Between the end of the top line and the big sparkle's left point.
    private static let topGap: CGFloat = 0.12
    /// Where the right line starts, below the frame's outer top.
    private static let rightStart: CGFloat = 0.39

    /// A template image unless a colour is given.
    static func image(_ configuration: NSImage.SymbolConfiguration = toolbar, color: NSColor? = nil) -> NSImage {
        guard let symbol = NSImage(systemSymbolName: "ellipsis.bubble", accessibilityDescription: "Ask")?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        let frame = Frame(symbol, scale: 8)
        let width = frame.right - frame.left
        let half = frame.line / 2
        let big = bigRadius * width, small = smallRadius * width
        let topAxis = frame.top + half, rightAxis = frame.right - half
        // As much room below as above, so the bubble sits where its
        // neighbours' do: the toolbar centres what it is given.
        let pad = max(0, big - topAxis) + 0.3
        let size = NSSize(width: symbol.size.width, height: symbol.size.height + pad * 2)

        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            let ink = color ?? .black
            let place = NSRect(x: 0, y: pad, width: symbol.size.width, height: symbol.size.height)
            if color == nil {
                symbol.draw(in: place)
            } else {
                NSImage(size: symbol.size, flipped: false) { rect in
                    symbol.draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }.draw(in: place)
            }

            // The line ends are measured at the scale the symbol is drawn at:
            // the system draws its lines a little differently at each, and ends
            // sized at another scale left a step on one side.
            let device = max(1, (abs(context.cgContext.userSpaceToDeviceSpaceTransform.a) * 4).rounded() / 4)
            let drawn = Frame(symbol, scale: device)
            let bigCentre = NSPoint(x: rightAxis - big, y: topAxis + pad)
            let topCut = bigCentre.x - big - topGap * width - half
            let rightCut = frame.top + rightStart * width + half
            let across = drawn.span(column: topCut), along = drawn.span(row: rightCut)
            let topEnd = NSPoint(x: topCut, y: (across.from + across.to) / 2 + pad)
            let rightEnd = NSPoint(x: (along.from + along.to) / 2, y: rightCut + pad)

            context.saveGraphicsState()
            // What may go: the frame beyond the two cuts, its round corner with
            // it. What stays: the bubble's hole, with the dots in it (pulled in a
            // third of a point, or the line's soft inner edge stays behind as a
            // hairline), and a half-disc at each cut, where the line's own
            // pixels make its round end with nothing drawn over them.
            let inner = max(0.5, frame.radius - frame.line)
            let keep = NSBezierPath(rect: NSRect(x: -100, y: -100, width: size.width + 200, height: size.height + 200))
            keep.append(NSBezierPath(
                roundedRect: NSRect(x: -20, y: frame.top + frame.line + 0.35 + pad, width: frame.right - frame.line - 0.35 + 20, height: 60),
                xRadius: inner, yRadius: inner
            ))
            for (end, radius) in [(topEnd, (across.to - across.from) / 2), (rightEnd, (along.to - along.from) / 2)] {
                keep.append(NSBezierPath(ovalIn: NSRect(x: end.x - radius, y: end.y - radius, width: radius * 2, height: radius * 2)))
            }
            keep.windingRule = .evenOdd
            keep.addClip()
            context.compositingOperation = .destinationOut
            NSBezierPath(rect: NSRect(x: topCut, y: -100, width: size.width + 100, height: rightEnd.y + 100)).fill()
            context.restoreGraphicsState()

            ink.set()
            sparkle(x: bigCentre.x, y: bigCentre.y, radius: big).fill()
            sparkle(x: rightAxis, y: frame.top + smallDrop * width + pad, radius: small).fill()
            return true
        }
        image.isTemplate = color == nil
        image.accessibilityDescription = "Ask"
        return image
    }

    /// The glyph as a PNG data URL, black on clear, for the page to mask with.
    static let maskDataURL: String = {
        let glyph = image()
        let scale: CGFloat = 4
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(glyph.size.width * scale), pixelsHigh: Int(glyph.size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else { return "" }
        rep.size = glyph.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        glyph.draw(in: NSRect(origin: .zero, size: glyph.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }()

    /// Where the symbol's frame is, from coverage in a bitmap of it: outer top,
    /// left and right edges, the line, and the corner's radius. Coverage, not
    /// a threshold: a threshold made the line a tenth of a point too thick.
    private struct Frame {
        var top: CGFloat = 1.8
        var left: CGFloat = 1.8
        var right: CGFloat = 19.1
        var line: CGFloat = 1.1
        var radius: CGFloat = 4
        private let rep: NSBitmapImageRep?
        private let scale: CGFloat

        init(_ symbol: NSImage, scale: CGFloat) {
            self.scale = scale
            let width = Int((symbol.size.width * scale).rounded()), height = Int((symbol.size.height * scale).rounded())
            rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
            guard let rep else { return }
            rep.size = symbol.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            symbol.draw(in: NSRect(origin: .zero, size: symbol.size))
            NSGraphicsContext.restoreGraphicsState()

            // Down a column 60 % of the way along, and along a row 45 % of the
            // way down: clear of the corners and the tail.
            let across = span(column: symbol.size.width * 0.6)
            let along = span(row: symbol.size.height * 0.45)
            top = across.from
            right = along.to
            line = ((across.to - across.from) + (along.to - along.from)) / 2
            var x = 0
            let row = Int(symbol.size.height * 0.45 * scale)
            while x < width, alpha(x, row) == 0 { x += 1 }
            left = (CGFloat(x) + 1 - alpha(x, row)) / scale
            // In from the outer corner along the diagonal, the first ink is on
            // the corner's arc, R(1 - 1/√2) in along each axis.
            var step: CGFloat = 0
            while step < 12 * scale, alpha(Int(right * scale - step), Int(top * scale + step)) < 0.5 { step += 1 }
            radius = step / scale / (1 - 1 / 2.0.squareRoot())
        }

        private func alpha(_ x: Int, _ y: Int) -> CGFloat {
            guard let rep, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return 0 }
            return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
        }

        /// The line down the column at `x` points, from the top. Rows run from
        /// the top, as the flipped drawing does.
        func span(column x: CGFloat) -> (from: CGFloat, to: CGFloat) {
            guard let rep else { return (top, top + line) }
            let column = Int(x * scale)
            var y = 0
            while y < rep.pixelsHigh, alpha(column, y) == 0 { y += 1 }
            let from = CGFloat(y) + 1 - alpha(column, y)
            var cover: CGFloat = 0
            while y < rep.pixelsHigh, alpha(column, y) > 0 { cover += alpha(column, y); y += 1 }
            return (from / scale, (from + cover) / scale)
        }

        /// The line along the row at `y` points, from the right.
        func span(row y: CGFloat) -> (from: CGFloat, to: CGFloat) {
            guard let rep else { return (right - line, right) }
            let row = Int(y * scale)
            var x = rep.pixelsWide - 1
            while x > 0, alpha(x, row) == 0 { x -= 1 }
            let to = CGFloat(x) + alpha(x, row)
            var cover: CGFloat = 0
            while x > 0, alpha(x, row) > 0 { cover += alpha(x, row); x -= 1 }
            return ((to - cover) / scale, to / scale)
        }
    }

    /// Four points with curved sides between them.
    private static func sparkle(x: CGFloat, y: CGFloat, radius r: CGFloat) -> NSBezierPath {
        let k = 0.2 * r
        let points = [NSPoint(x: x, y: y - r), NSPoint(x: x + r, y: y), NSPoint(x: x, y: y + r), NSPoint(x: x - r, y: y)]
        let bends = [NSPoint(x: x + k, y: y - k), NSPoint(x: x + k, y: y + k), NSPoint(x: x - k, y: y + k), NSPoint(x: x - k, y: y - k)]
        let path = NSBezierPath()
        path.move(to: points[0])
        for index in 0..<4 {
            let from = points[index], to = points[(index + 1) % 4], bend = bends[index]
            // A quadratic curve in the cubic form NSBezierPath takes.
            path.curve(to: to,
                       controlPoint1: NSPoint(x: from.x + 2 / 3 * (bend.x - from.x), y: from.y + 2 / 3 * (bend.y - from.y)),
                       controlPoint2: NSPoint(x: to.x + 2 / 3 * (bend.x - to.x), y: to.y + 2 / 3 * (bend.y - to.y)))
        }
        path.close()
        return path
    }
}
