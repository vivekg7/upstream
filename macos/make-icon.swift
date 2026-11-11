// Draws Upstream's mark: a branch joining a line that rises into an arrow,
// on the brand colour. As a macOS icon set it sits in the rounded square
// every Mac icon shares; as the logo (`docs/logo.png`, for the GitHub OAuth
// App and the README) it fills a plain square, since GitHub and most other
// sites round or crop it themselves. One drawing, so the two never drift.
//
//   swift macos/make-icon.swift OUT.iconset
//   swift macos/make-icon.swift --logo docs/logo.png
import AppKit

func draw(_ px: Int, square: Bool = false) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    // Apple's grid: an 824-unit square, inset 100, corners of 185. The logo
    // is the same tile grown to the edges, so the mark keeps its proportions.
    let tile =
        square
        ? CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
        : CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let radius = square ? 0 : 185 * s
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(CGColor(srgbRed: 0x1F / 255, green: 0x6F / 255, blue: 0x8B / 255, alpha: 1))
    ctx.fillPath()
    // On a 100-unit grid over the tile; y grows upward.
    let unit = tile.width / 100
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + x * unit, y: tile.minY + y * unit)
    }
    ctx.setStrokeColor(.white)
    ctx.setFillColor(.white)
    ctx.setLineWidth(9 * unit)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    // The trunk, and the branch curving into it.
    ctx.move(to: p(50, 20))
    ctx.addLine(to: p(50, 64))
    ctx.move(to: p(30, 22))
    ctx.addCurve(to: p(50, 52), control1: p(30, 40), control2: p(50, 38))
    ctx.strokePath()
    // The arrowhead.
    ctx.move(to: p(32, 62))
    ctx.addLine(to: p(50, 82))
    ctx.addLine(to: p(68, 62))
    ctx.strokePath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let args = CommandLine.arguments.dropFirst()
if args.first == "--logo", let path = args.dropFirst().first {
    try draw(1024, square: true).write(to: URL(fileURLWithPath: path))
    exit(0)
}
let out = URL(fileURLWithPath: args.first!)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: out.appending(path: "icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: out.appending(path: "icon_\(size)x\(size)@2x.png"))
}
