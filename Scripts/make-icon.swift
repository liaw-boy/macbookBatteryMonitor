// 產生 App 圖示：仰躺在無線充電墊上的布偶貓（照片去背）
//   swiftc -O Scripts/make-icon.swift -o build/make-icon && build/make-icon Resources/AppIcon.icns
//   build/make-icon --preview icon.png [--size 512]   只輸出單張 PNG（預設 1024×1024）
//   --bg mint|peach|night|sky                          背景色（預設薄荷綠，即內建圖示）
//   --cat <去背 PNG>                                   貓咪圖（預設 Resources/icon-cat.png）
// 設定裡可切換的其他背景色：
//   for bg in peach night sky; do build/make-icon --bg $bg --size 512 --preview Resources/AppIcons/icon-$bg.png; done
import AppKit
import ImageIO

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}
let previewPath = option("--preview")
let previewSize = option("--size").flatMap(Int.init) ?? 1024
/// 背景色：mint（薄荷綠，內建圖示）、peach（暖杏色）、night（深夜藍）、sky（天空藍）
let background = option("--bg") ?? "mint"
let catPath = option("--cat") ?? "Resources/icon-cat.png"
let output = arguments.first { !$0.hasPrefix("--") && ![previewPath, catPath, background, option("--size")].contains($0) } ?? "Resources/AppIcon.icns"
let catImage: CGImage = {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: catPath) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("讀不到貓咪圖：\(catPath)") }
    return image
}()

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// 以 1024×1024 為座標、左上角為原點作畫
struct Painter {
    let ctx: CGContext
    let scale: CGFloat

    func fill(_ path: CGPath, _ color: CGColor) {
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor) {
        fill(CGPath(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2), transform: nil), color)
    }

    func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ color: CGColor) { ellipse(cx, cy, r, r, color) }

    func stroke(_ path: CGPath, _ color: CGColor, width: CGFloat) {
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    /// 座標系是上下翻轉的，圖片要再翻回來畫
    func image(_ image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    func shadow(_ dy: CGFloat, blur: CGFloat, alpha: CGFloat, _ draw: () -> Void) {
        ctx.saveGState()
        // 陰影的位移與模糊不受座標變換影響，要自己換算；底圖原點在左下，往下是負的
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: rgb(0x000000, alpha))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        draw()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

extension Painter {
    func linear(_ path: CGPath, _ colors: [CGColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
        ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// 帶顏色的光暈（陰影不偏移，只有模糊）
    func glow(_ color: CGColor, blur: CGFloat, dy: CGFloat = 0, _ draw: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: color)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        draw()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 圓角閃電，中心在 (x, y)，高度約 148 × size
    func bolt(_ x: CGFloat, _ y: CGFloat, size: CGFloat) -> CGPath {
        let points: [(CGFloat, CGFloat)] = [(22, -74), (-42, 10), (-6, 10), (-20, 74), (44, -12), (8, -12)]
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: x + $0.0 * size, y: y + $0.1 * size) })
        path.closeSubpath()
        return path
    }

    /// 去背的貓咪照片，外圍加一圈白色描邊與陰影
    func cat(in rect: CGRect) {
        shadow(12, blur: 26, alpha: 0.28) {
            ctx.saveGState()
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for i in 0..<24 {
                let angle = CGFloat(i) / 24 * 2 * .pi
                image(catImage, in: rect.offsetBy(dx: cos(angle) * 9, dy: sin(angle) * 9))
            }
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(rgb(0xFFFFFF))
            ctx.fill(rect.insetBy(dx: -20, dy: -20))
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        image(catImage, in: rect)
    }
}

/// 發光的無線充電墊，貓躺在上面，上方是充電的波紋與閃電小徽章
func drawPad(_ p: Painter, center c: CGPoint) {
    // 墊子的厚度與頂面
    p.glow(rgb(0x1E3A66, 0.3), blur: 30, dy: 16) {
        p.ellipse(c.x, c.y + 22, 340, 78, rgb(0xC9D4E3))
    }
    p.linear(CGPath(ellipseIn: CGRect(x: c.x - 340, y: c.y - 74, width: 680, height: 148), transform: nil),
             [rgb(0xFFFFFF), rgb(0xE3EAF4)], [0, 1], from: CGPoint(x: 0, y: c.y - 74), to: CGPoint(x: 0, y: c.y + 74))
    // 頂面發光的綠色充電環
    p.glow(rgb(0x22C55E, 0.8), blur: 24) {
        p.stroke(CGPath(ellipseIn: CGRect(x: c.x - 250, y: c.y - 46, width: 500, height: 92), transform: nil), rgb(0x3BD872), width: 12)
    }
}

func drawChargingWaves(_ p: Painter, center c: CGPoint) {
    // 往上擴散的三道弧線
    for (i, radius) in [70.0, 112.0, 154.0].enumerated() {
        let arc = CGMutablePath()
        arc.addArc(center: CGPoint(x: c.x, y: c.y + 120), radius: radius, startAngle: -.pi * 0.78, endAngle: -.pi * 0.22, clockwise: false)
        p.glow(rgb(0x22C55E, 0.5), blur: 14) { p.stroke(arc, rgb(0xFFFFFF, 1 - CGFloat(i) * 0.22), width: 18) }
    }
    // 閃電小徽章
    p.glow(rgb(0x1E3A66, 0.25), blur: 18, dy: 8) { p.circle(c.x, c.y + 120, 52, rgb(0x2FC567)) }
    let boltPath = p.bolt(c.x + 1, c.y + 120, size: 0.42)
    p.stroke(boltPath, rgb(0xFFFFFF), width: 5)
    p.fill(boltPath, rgb(0xFFFFFF))
}

func drawIcon(_ p: Painter) {
    let ctx = p.ctx

    // macOS 圖示的圓角方形底；薄荷綠呼應充電的綠色，其他顏色可在設定裡切換
    let colors: (top: UInt32, bottom: UInt32)
    switch background {
    case "peach": colors = (0xFFE9D2, 0xF3B486)
    case "night": colors = (0x34467A, 0x141C38)
    case "sky": colors = (0x9CCBF5, 0x5B93D3)
    default: colors = (0xD3F5E6, 0x6CCBAA)
    }
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    p.shadow(10, blur: 24, alpha: 0.25) { p.fill(squircle, rgb(colors.bottom)) }
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: srgb, colors: [rgb(colors.top), rgb(colors.bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    let aspect = CGFloat(catImage.height) / CGFloat(catImage.width)
    drawPad(p, center: CGPoint(x: 512, y: 800))
    p.cat(in: CGRect(x: 160, y: 425, width: 700, height: 700 * aspect))
    drawChargingWaves(p, center: CGPoint(x: 512, y: 185))
    ctx.restoreGState()
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    // 換成 1024 單位、左上角為原點
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: s / 1024, y: -s / 1024)
    drawIcon(Painter(ctx: ctx, scale: s / 1024))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

if let previewPath {
    try! render(size: previewSize).write(to: URL(fileURLWithPath: previewPath))
    print("✅ \(previewPath)")
    exit(0)
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "✅ \(output)" : "iconutil 失敗")
