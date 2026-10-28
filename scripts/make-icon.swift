import AppKit

// Gera o ícone 1024×1024: squircle com gradiente (YouTube → Instagram → TikTok)
// e o símbolo da TV de tubo em branco, tela em vidro translúcido.
let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Área do ícone segundo o grid da Apple (824 px com margem para sombra).
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor.black.setFill()
shape.fill()
ctx.restoreGState()

shape.addClip()
let gradient = NSGradient(colors: [
    NSColor(red: 1.00, green: 0.23, blue: 0.25, alpha: 1),
    NSColor(red: 0.86, green: 0.18, blue: 0.55, alpha: 1),
    NSColor(red: 0.45, green: 0.22, blue: 0.85, alpha: 1),
    NSColor(red: 0.10, green: 0.75, blue: 0.85, alpha: 1),
], atLocations: [0, 0.38, 0.68, 1], colorSpace: .deviceRGB)!
gradient.draw(in: rect, angle: -45)

// Brilho superior sutil (luz batendo no material).
let gloss = NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
gloss.draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

// Símbolo: mesma grade 120×120 do app (CRTVGlyph), ocupando 72% do ícone, eixo Y invertido.
let glyphSize = rect.width * 0.72
let k = glyphSize / 120
ctx.saveGState()
ctx.translateBy(x: rect.midX - glyphSize / 2, y: rect.midY + glyphSize / 2)
ctx.scaleBy(x: k, y: -k)

let screen = CGPath(roundedRect: CGRect(x: 24, y: 44, width: 72, height: 52), cornerWidth: 13, cornerHeight: 13, transform: nil)
ctx.addPath(screen)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
ctx.fillPath()

ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(8)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

ctx.addPath(CGPath(roundedRect: CGRect(x: 12, y: 32, width: 96, height: 76), cornerWidth: 24, cornerHeight: 24, transform: nil))
ctx.move(to: CGPoint(x: 45, y: 15)); ctx.addLine(to: CGPoint(x: 60, y: 32)); ctx.addLine(to: CGPoint(x: 75, y: 15))
ctx.move(to: CGPoint(x: 60, y: 55)); ctx.addLine(to: CGPoint(x: 60, y: 86))
ctx.move(to: CGPoint(x: 47, y: 74)); ctx.addLine(to: CGPoint(x: 60, y: 87)); ctx.addLine(to: CGPoint(x: 73, y: 74))
ctx.strokePath()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
