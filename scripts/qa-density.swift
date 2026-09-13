import Foundation
import CoreGraphics
import ImageIO

// usage: tb-pixels <img.png> [cols] [rows] [x y w h]
// Mapa ASCII de cobertura de pixel (alpha > corte): onde NADA foi pintado o
// alpha é 0 (ImageRenderer sem fundo), então o desenho aparece como "tinta".
let args = CommandLine.arguments
guard args.count > 1 else { FileHandle.standardError.write("usage: tb-pixels <img> [cols rows x y w h]\n".data(using: .utf8)!); exit(2) }
let cols = args.count > 2 ? Int(args[2]) ?? 90 : 90
let rows = args.count > 3 ? Int(args[3]) ?? 60 : 60
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      var img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("cannot load\n".data(using: .utf8)!); exit(3)
}
if args.count >= 8, let x = Int(args[4]), let y = Int(args[5]), let w = Int(args[6]), let h = Int(args[7]),
   let cropped = img.cropping(to: CGRect(x: x, y: y, width: w, height: h)) {
    img = cropped
}
let w = img.width, h = img.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(4) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
print("image: \(w)x\(h)  buckets: \(cols)x\(rows)")
let ramp = Array(" .:-=+*#%@")
for row in 0..<rows {
    var line = ""
    for col in 0..<cols {
        let x0 = col * w / cols, x1 = max(x0 + 1, (col + 1) * w / cols)
        let y0 = row * h / rows, y1 = max(y0 + 1, (row + 1) * h / rows)
        var ink = 0, total = 0
        for y in stride(from: y0, to: y1, by: max(1, (y1 - y0) / 6)) {
            for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 6)) {
                total += 1
                let alpha = buf[(y * w + x) * 4 + 3]
                let rgb = Int(buf[(y * w + x) * 4]) + Int(buf[(y * w + x) * 4 + 1]) + Int(buf[(y * w + x) * 4 + 2])
                if alpha > 20 && rgb > 60 { ink += 1 }
            }
        }
        let frac = total == 0 ? 0 : Double(ink) / Double(total)
        line.append(ramp[min(ramp.count - 1, Int(frac * Double(ramp.count - 1) * 3.2))])
    }
    print(String(format: "%4d |%@|", h - row * h / rows, line))
}
