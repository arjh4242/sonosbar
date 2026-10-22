// Tegner SonosBars programikon og laver AppIcon.icns.
// Kør: swift Icon/make-icon.swift   (fra SonosBar-mappen)
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Tegner ikonet på et 1024×1024-lærred (macOS' ikon-gitter: 824×824 felt med 100 px margen)
func drawIcon(in ctx: CGContext) {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let tile = canvas.insetBy(dx: 100, dy: 100)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Skygge under feltet
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.35).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(color(0x1B1E25).cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Baggrund: mørk grafit-gradient
    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [color(0x3A4050).cgColor, color(0x15171D).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
    ctx.restoreGState()

    // Højttaler
    let body = CGRect(x: 250, y: 215, width: 360, height: 594)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 72, cornerHeight: 72, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.5).cgColor)
    ctx.addPath(bodyPath); ctx.setFillColor(color(0xE9EBEF).cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let front = CGGradient(colorsSpace: nil, colors: [color(0xFAFBFC).cgColor, color(0xC5CAD3).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(front, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    func cone(center: CGPoint, radius r: CGFloat) {
        // Kant, membran og støvhætte
        ctx.setFillColor(color(0x9BA1AC).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        let inner = r * 0.86
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
        ctx.clip()
        let g = CGGradient(colorsSpace: nil, colors: [color(0x2E333D).cgColor, color(0x0E1014).cgColor] as CFArray,
                           locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: center.x - r * 0.2, y: center.y + r * 0.25), startRadius: 0,
                               endCenter: center, endRadius: inner, options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        let cap = r * 0.3
        ctx.setFillColor(color(0x4A505C).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - cap, y: center.y - cap, width: 2 * cap, height: 2 * cap))
    }
    cone(center: CGPoint(x: body.midX, y: 400), radius: 128)   // bas
    cone(center: CGPoint(x: body.midX, y: 670), radius: 58)    // diskant

    // Lydbølger i orange
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0xFF9F0A).cgColor)
    let origin = CGPoint(x: 600, y: 512)
    for (i, radius) in [CGFloat(140), 220].enumerated() {
        ctx.setLineWidth(i == 0 ? 44 : 40)
        ctx.setAlpha(i == 0 ? 1 : 0.75)
        ctx.addArc(center: origin, radius: radius, startAngle: -.pi / 4.2, endAngle: .pi / 4.2, clockwise: false)
        ctx.strokePath()
    }
    ctx.setAlpha(1)
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Icon")
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: dir.appendingPathComponent("AppIcon-1024.png"))
// Saml alle størrelser i én .icns-fil, som build.sh lægger ind i appen
let icns = dir.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil fejlede")
try? FileManager.default.removeItem(at: iconset)
print("Færdig: \(icns.path)")
