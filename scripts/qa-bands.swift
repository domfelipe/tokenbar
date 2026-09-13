import Foundation
import CoreGraphics
import ImageIO

// usage: tb-bands <img.png> <x0> <x1> <y0> <y1> [minHeight]
// Mede FAIXAS horizontais de tinta (alpha>20 e brilho>60) numa coluna: serve
// para provar, linha a linha, o que pintou (ex.: a coluna de custo do ledger —
// 27 linhas com "~$X.XX" e 3 com "—").
let a = CommandLine.arguments
guard a.count >= 6, let x0 = Int(a[2]), let x1 = Int(a[3]), let y0 = Int(a[4]), let y1 = Int(a[5]) else {
    FileHandle.standardError.write("usage: tb-bands <img> x0 x1 y0 y1 [minHeight]\n".data(using: .utf8)!); exit(2)
}
let minHeight = a.count > 6 ? Int(a[6]) ?? 4 : 4
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { exit(3) }
let w = img.width, h = img.height
var buf = [UInt8](repeating: 0, count: w * h * 4)
guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(4) }
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
print("image: \(w)x\(h)  coluna x=\(x0)..\(x1)  y=\(y0)..\(y1)")
var bandStart = -1, inkInBand = 0, minX = Int.max, maxX = Int.min, band = 0
func flush(_ end: Int) {
    guard bandStart >= 0 else { return }
    let height = end - bandStart
    if height >= minHeight {
        let inkWidth = maxX >= minX ? maxX - minX + 1 : 0
        print(String(format: "faixa %2d  y=%4d..%4d  altura=%3d  tinta=%5d  x=%4d..%4d  largura=%3d",
                     band, bandStart, end - 1, height, inkInBand, x0 + minX, x0 + maxX, inkWidth))
        band += 1
    }
    bandStart = -1; inkInBand = 0; minX = Int.max; maxX = Int.min
}
var gap = 0
for y in y0..<min(y1, h) {
    var rowInk = 0
    for x in x0..<min(x1, w) {
        let alpha = buf[(y * w + x) * 4 + 3]
        let lum = Int(buf[(y * w + x) * 4]) + Int(buf[(y * w + x) * 4 + 1]) + Int(buf[(y * w + x) * 4 + 2])
        if alpha > 20 && lum > 60 {
            rowInk += 1
            minX = min(minX, x - x0); maxX = max(maxX, x - x0)
        }
    }
    if rowInk > 0 {
        if bandStart < 0 { bandStart = y }
        inkInBand += rowInk
        gap = 0
    } else if bandStart >= 0 {
        gap += 1
        if gap > 3 { flush(y - gap + 1) }
    }
}
flush(min(y1, h))
