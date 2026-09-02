import AppKit

// Desenha o ícone TokenBar (PNG 1024x1024) via AppKit — usado pelo make-app.sh.
// Uso: swift scripts/genicon.swift <caminho-png>

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor.clear.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let rect = NSRect(x: 64, y: 64, width: size - 128, height: size - 128)
NSColor.systemTeal.setFill()
NSBezierPath(roundedRect: rect, xRadius: 180, yRadius: 180).fill()
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 560, weight: .bold),
    .foregroundColor: NSColor.white,
]
let str = NSAttributedString(string: "T", attributes: attrs)
let bounds = str.boundingRect(with: rect.size, options: .usesLineFragmentOrigin)
str.draw(at: NSPoint(x: (size - bounds.width) / 2, y: (size - bounds.height) / 2))
image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(filePath: CommandLine.arguments[1]))
