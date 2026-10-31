import Foundation
import CoreGraphics
import ImageIO

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as! [[String: Any]]
let attachments = manifest.flatMap { $0["attachments"] as? [[String: Any]] ?? [] }
guard let attachment = attachments.first(where: { ($0["suggestedHumanReadableName"] as? String ?? "").contains("正文像素") }),
      let filename = attachment["exportedFileName"] as? String,
      let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(filename) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(data: nil, width: image.width, height: image.height,
                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let data = context.data?.assumingMemoryBound(to: UInt8.self) else {
    fatalError("Missing readable body screenshot")
}
context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
var ink = 0
for pixel in 0..<(image.width * image.height) {
    let offset = pixel * 4
    if data[offset] < 170 && data[offset+1] < 170 && data[offset+2] < 170 && data[offset+3] > 128 { ink += 1 }
}
guard ink > 200 else { fatalError("Body screenshot is blank: only \(ink) dark pixels. Accessibility labels alone do not prove rendering.") }
print("Reader body renders visible glyphs: \(ink) dark pixels in \(image.width)x\(image.height) screenshot")
