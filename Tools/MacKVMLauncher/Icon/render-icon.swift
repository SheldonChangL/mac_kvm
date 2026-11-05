// Renders the MacKVM app icon (1024 px) to the path given as the first argument.
// Two connected displays make the remote-control concept readable at small sizes.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: alpha
  )
}

func rounded(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
  NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

let bitmap = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: Int(size),
  pixelsHigh: Int(size),
  bitsPerSample: 8,
  samplesPerPixel: 4,
  hasAlpha: true,
  isPlanar: false,
  colorSpaceName: .deviceRGB,
  bytesPerRow: 0,
  bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext

// Keep a generous clear margin so macOS can apply its own icon mask cleanly.
let body = CGRect(x: 84, y: 84, width: 856, height: 856)
let iconShape = rounded(body, radius: 198)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -16), blur: 38, color: color(0x030817, 0.45).cgColor)
color(0x101A36).setFill()
iconShape.fill()
context.restoreGState()

iconShape.addClip()
NSGradient(colors: [color(0x253D72), color(0x101A36), color(0x11182E)])!
  .draw(in: body, angle: -45)

// Soft blue light behind the connection, kept broad enough to survive downscaling.
context.saveGState()
context.setShadow(offset: .zero, blur: 110, color: color(0x3C7BFF, 0.5).cgColor)
color(0x254E9E, 0.34).setFill()
NSBezierPath(ovalIn: CGRect(x: 300, y: 365, width: 430, height: 330)).fill()
context.restoreGState()

// The two displays have matching geometry and distinct luminous edge colors.
let leftScreen = CGRect(x: 190, y: 430, width: 300, height: 280)
let rightScreen = CGRect(x: 534, y: 430, width: 300, height: 280)

func drawScreen(_ rect: CGRect, rim: UInt32, top: UInt32, bottom: UInt32, z: CGFloat) {
  let shell = rounded(rect, radius: 48)
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -z), blur: 30, color: color(rim, 0.36).cgColor)
  color(rim).setFill()
  shell.fill()
  context.restoreGState()

  let inset = rect.insetBy(dx: 13, dy: 13)
  let face = rounded(inset, radius: 38)
  context.saveGState()
  face.addClip()
  NSGradient(colors: [color(top), color(bottom)])!.draw(in: inset, angle: -90)
  context.restoreGState()

  // A calm screen glow gives depth without adding small, noisy interface details.
  context.saveGState()
  context.setShadow(offset: CGSize(width: 0, height: -2), blur: 34, color: color(rim, 0.34).cgColor)
  color(0xFFFFFF, 0.08).setFill()
  NSBezierPath(ovalIn: CGRect(x: rect.minX + 30, y: rect.minY + 155, width: rect.width - 60, height: 170)).fill()
  context.restoreGState()

  let stand = rounded(
    CGRect(x: rect.midX - 19, y: rect.minY - 47, width: 38, height: 49), radius: 15)
  color(rim).setFill()
  stand.fill()
  rounded(CGRect(x: rect.midX - 75, y: rect.minY - 67, width: 150, height: 22), radius: 11).fill()
}

// Draw the left display first so the right display reads as the active endpoint.
drawScreen(leftScreen, rim: 0x42D6E7, top: 0x274A77, bottom: 0x182B4A, z: 9)
drawScreen(rightScreen, rim: 0x8B7CFF, top: 0x354783, bottom: 0x1A2851, z: 13)

// One broad connection joins the displays. A bright center node carries the KVM link.
let link = NSBezierPath()
link.move(to: CGPoint(x: 474, y: 578))
link.curve(to: CGPoint(x: 550, y: 578), controlPoint1: CGPoint(x: 484, y: 622), controlPoint2: CGPoint(x: 540, y: 622))
link.lineWidth = 24
link.lineCapStyle = .round
context.saveGState()
context.setShadow(offset: .zero, blur: 26, color: color(0x54DFFF, 0.8).cgColor)
color(0x65E5F3).setStroke()
link.stroke()
context.restoreGState()

let node = CGRect(x: 493, y: 562, width: 38, height: 38)
context.saveGState()
context.setShadow(offset: .zero, blur: 22, color: color(0xFFFFFF, 0.72).cgColor)
color(0xF4FEFF).setFill()
NSBezierPath(ovalIn: node).fill()
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! bitmap.representation(using: .png, properties: [:])!
  .write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
