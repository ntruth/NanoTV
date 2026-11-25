import AppKit

// Luma / 拾光 —— 棱镜光圈图标
// 深空底色 + 极光光晕 + 锥形色环光圈 + 六边形光孔 + 金属镜圈。

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    FileHandle.standardError.write(Data("no graphics context\n".utf8))
    exit(1)
}
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a).cgColor
}

func nsColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func point(_ center: CGPoint, _ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
    CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
}

func drawRadial(_ center: CGPoint, _ radius: CGFloat,
                _ colors: [CGColor], _ locations: [CGFloat]) {
    guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: colors as CFArray,
                                    locations: locations) else { return }
    ctx.drawRadialGradient(gradient,
                           startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius,
                           options: [])
}

let squircleRect = CGRect(x: 68, y: 68, width: 888, height: 888)
let squircle = CGPath(roundedRect: squircleRect,
                      cornerWidth: 210, cornerHeight: 210,
                      transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// 底色：深墨蓝 → 近黑
if let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [color(0.105, 0.118, 0.185), color(0.030, 0.034, 0.060)] as CFArray,
                         locations: [0, 1]) {
    ctx.drawLinearGradient(base,
                           start: CGPoint(x: 512, y: 956),
                           end: CGPoint(x: 512, y: 68),
                           options: [])
}

// 极光光晕
drawRadial(CGPoint(x: 706, y: 700), 640,
           [color(0.18, 0.90, 0.80, 0.50),
            color(0.44, 0.36, 0.98, 0.30),
            color(0.98, 0.38, 0.68, 0.0)],
           [0, 0.50, 1])

drawRadial(CGPoint(x: 268, y: 286), 500,
           [color(1.0, 0.68, 0.34, 0.26),
            color(1.0, 0.40, 0.56, 0.0)],
           [0, 1])

// 斜向高光扫过
ctx.saveGState()
ctx.translateBy(x: 512, y: 512)
ctx.rotate(by: -0.55)
if let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(1, 1, 1, 0.0),
                                   color(1, 1, 1, 0.055),
                                   color(1, 1, 1, 0.0)] as CFArray,
                          locations: [0, 0.5, 1]) {
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: -520, y: 0),
                           end: CGPoint(x: 520, y: 0),
                           options: [])
}
ctx.restoreGState()

let center = CGPoint(x: 512, y: 512)

// 中央柔光
drawRadial(center, 380,
           [color(1, 1, 1, 0.12), color(1, 1, 1, 0.0)],
           [0, 1])

// 锥形色环（棱镜色散）
let palette = [
    nsColor(0.31, 0.88, 0.99),
    nsColor(0.33, 0.56, 1.00),
    nsColor(0.56, 0.43, 1.00),
    nsColor(0.85, 0.40, 0.95),
    nsColor(1.00, 0.42, 0.64),
    nsColor(1.00, 0.64, 0.38),
    nsColor(0.46, 0.93, 0.62),
    nsColor(0.31, 0.88, 0.99)
]

func samplePalette(_ t: CGFloat) -> NSColor {
    let count = palette.count - 1
    let scaled = max(0, min(CGFloat(count) - 0.0001, t * CGFloat(count)))
    let index = Int(scaled)
    let fraction = scaled - CGFloat(index)
    let a = palette[index]
    let b = palette[index + 1]
    return nsColor(
        a.redComponent + (b.redComponent - a.redComponent) * fraction,
        a.greenComponent + (b.greenComponent - a.greenComponent) * fraction,
        a.blueComponent + (b.blueComponent - a.blueComponent) * fraction
    )
}

let irisRadius: CGFloat = 240
let steps = 200
for step in 0..<steps {
    let t0 = CGFloat(step) / CGFloat(steps)
    let t1 = CGFloat(step + 1) / CGFloat(steps)
    let a0 = -CGFloat.pi / 2 + t0 * 2 * .pi
    let a1 = -CGFloat.pi / 2 + t1 * 2 * .pi
    let wedge = CGMutablePath()
    wedge.move(to: center)
    wedge.addArc(center: center, radius: irisRadius,
                 startAngle: a0, endAngle: a1, clockwise: false)
    wedge.closeSubpath()
    ctx.addPath(wedge)
    ctx.setFillColor(samplePalette(t0).cgColor)
    ctx.fillPath()
}

// 六边形光孔
let holeRadius: CGFloat = 96
let hexagon = CGMutablePath()
for index in 0..<6 {
    let angle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 3
    let vertex = point(center, holeRadius, angle)
    if index == 0 {
        hexagon.move(to: vertex)
    } else {
        hexagon.addLine(to: vertex)
    }
}
hexagon.closeSubpath()

ctx.saveGState()
ctx.addPath(hexagon)
ctx.clip()
if let holeGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [color(0.075, 0.086, 0.135), color(0.020, 0.024, 0.042)] as CFArray,
                                 locations: [0, 1]) {
    let holeBox = hexagon.boundingBox
    ctx.drawLinearGradient(holeGradient,
                           start: CGPoint(x: holeBox.midX, y: holeBox.maxY),
                           end: CGPoint(x: holeBox.midX, y: holeBox.minY),
                           options: [])
}
drawRadial(center, holeRadius * 1.1,
           [color(0.35, 0.85, 1.0, 0.22), color(0.35, 0.85, 1.0, 0.0)],
           [0, 1])
ctx.restoreGState()

// 光孔边缘
ctx.addPath(hexagon)
ctx.setStrokeColor(color(1, 1, 1, 0.30))
ctx.setLineWidth(2.4)
ctx.strokePath()

// 叶片分割线
for index in 0..<6 {
    let baseAngle = -CGFloat.pi / 2 + CGFloat(index) * CGFloat.pi / 3
    let inner = point(center, holeRadius, baseAngle)
    let outer = point(center, irisRadius - 2, baseAngle + 0.42)
    ctx.setStrokeColor(color(1, 1, 1, 0.20))
    ctx.setLineWidth(2.2)
    ctx.move(to: inner)
    ctx.addLine(to: outer)
    ctx.strokePath()
}

// 金属外圈
ctx.setStrokeColor(color(1, 1, 1, 0.16))
ctx.setLineWidth(30)
ctx.strokeEllipse(in: CGRect(x: center.x - 300, y: center.y - 300, width: 600, height: 600))

ctx.setStrokeColor(color(1, 1, 1, 0.55))
ctx.setLineWidth(2.6)
ctx.strokeEllipse(in: CGRect(x: center.x - 272, y: center.y - 272, width: 544, height: 544))

ctx.setStrokeColor(color(1, 1, 1, 0.12))
ctx.setLineWidth(1.4)
ctx.strokeEllipse(in: CGRect(x: center.x - 318, y: center.y - 318, width: 636, height: 636))

// 左上高光弧
ctx.setStrokeColor(color(1, 1, 1, 0.62))
ctx.setLineWidth(5)
ctx.addArc(center: center, radius: 300,
           startAngle: CGFloat.pi * 0.60, endAngle: CGFloat.pi * 0.86,
           clockwise: false)
ctx.strokePath()

// 暗角
drawRadial(center, 740,
           [color(0, 0, 0, 0), color(0, 0, 0, 0.42)],
           [0.55, 1])

ctx.restoreGState()

// 外框细边
ctx.addPath(squircle)
ctx.setStrokeColor(color(1, 1, 1, 0.10))
ctx.setLineWidth(2)
ctx.strokePath()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
