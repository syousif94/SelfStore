import AppKit
// Renders the SelfStore icon (1024x1024 PNG). Usage: swift make-icon.swift out.png [mac]
let args = CommandLine.arguments
let out = args[1], mac = args.count > 2
let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let inset: CGFloat = mac ? 100 : 0
let rect = NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let path = mac ? NSBezierPath(roundedRect: rect, xRadius: rect.width*0.225, yRadius: rect.width*0.225) : NSBezierPath(rect: rect)
NSGradient(colors: [NSColor(red: 0.20, green: 0.55, blue: 1.0, alpha: 1), NSColor(red: 0.36, green: 0.25, blue: 0.95, alpha: 1)])!.draw(in: path, angle: -60)
let cfg = NSImage.SymbolConfiguration(pointSize: rect.width*0.5, weight: .semibold).applying(.init(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let sz = sym.size
sym.draw(in: NSRect(x: rect.midX - sz.width/2, y: rect.midY - sz.height/2 - rect.width*0.02, width: sz.width, height: sz.height))
NSGraphicsContext.restoreGraphicsState()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
