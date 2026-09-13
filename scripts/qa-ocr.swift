import Foundation
import Vision
import ImageIO
import CoreGraphics

let args = CommandLine.arguments
guard args.count > 1 else { FileHandle.standardError.write("usage: tb-ocr <img> [x y w h]\n".data(using: .utf8)!); exit(2) }
let url = URL(fileURLWithPath: args[1])
guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
      var img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("cannot load \(args[1])\n".data(using: .utf8)!); exit(3)
}
if args.count >= 6, let x = Int(args[2]), let y = Int(args[3]), let w = Int(args[4]), let h = Int(args[5]) {
    if let cropped = img.cropping(to: CGRect(x: x, y: y, width: w, height: h)) { img = cropped }
}
print("image: \(img.width)x\(img.height)")
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.usesLanguageCorrection = false
req.minimumTextHeight = 0.05
let handler = VNImageRequestHandler(cgImage: img, options: [:])
try handler.perform([req])
let obs = req.results ?? []
print("observations: \(obs.count)")
for o in obs {
    guard let top = o.topCandidates(1).first else { continue }
    let bb = o.boundingBox
    print(String(format: "x=%.3f y=%.3f w=%.3f h=%.3f conf=%.2f | %@", bb.origin.x, bb.origin.y, bb.size.width, bb.size.height, top.confidence, top.string))
}
