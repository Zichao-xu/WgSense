// Canonical geometry of the approved bilateral-breakthrough WgSense mark.
// Run: xcrun swift branding/GenerateAppIcon.swift [--check]
// All catalog sizes and the SVG master are generated together; never edit PNGs.
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Plane {
    let color: String
    let points: [[CGFloat]]
}

let canvas: CGFloat = 1254
let tile = CGRect(x: 102, y: 104, width: 1050, height: 1044)
let radius: CGFloat = 154
enum BrandAppearance: String, CaseIterable {
    case light, dark
    var background: String { self == .light ? "E9E8E2" : "101214" }
    var foreground: String { self == .light ? "101214" : "E9E8E2" }
    func resolve(_ color: String) -> String { color == "E9E8E2" ? foreground : color }
}
let planes = [
    Plane(color: "E9E8E2", points: [
        [474,599], [574,359], [740,277], [619,598],
        [1152,461], [1152,588], [574,738], [600,649], [533,665], [560,579]
    ]),
    Plane(color: "E9E8E2", points: [
        [102,700], [474,599], [433,714], [588,677],
        [509,886], [318,966], [403,764], [102,840]
    ]),
    Plane(color: "EF4236", points: [[742,479], [1027,403], [1027,461], [742,534]])
]
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let catalog = root.appendingPathComponent("platforms/macos/WgSense/Assets.xcassets/AppIcon.appiconset")
let checking = CommandLine.arguments.contains("--check")

func color(_ hex: String) -> CGColor {
    let value = UInt32(hex, radix: 16)!
    return CGColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                   green: CGFloat((value >> 8) & 255) / 255,
                   blue: CGFloat(value & 255) / 255, alpha: 1)
}

func bitmap(_ size: Int) -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
              bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func render(_ size: Int, appearance: BrandAppearance = .dark) -> CGImage {
    // Supersample the tiny menu/Finder representations as well as the master.
    let factor = size <= 256 ? 4 : 2
    let context = bitmap(size * factor)
    let scale = CGFloat(size * factor) / canvas
    context.translateBy(x: 0, y: CGFloat(size * factor))
    context.scaleBy(x: scale, y: -scale)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.setFillColor(color(appearance.background))
    context.fill(tile)
    for plane in planes {
        context.beginPath()
        context.move(to: CGPoint(x: plane.points[0][0], y: plane.points[0][1]))
        for p in plane.points.dropFirst() { context.addLine(to: CGPoint(x: p[0], y: p[1])) }
        context.closePath()
        context.setFillColor(color(appearance.resolve(plane.color)))
        context.fillPath()
    }
    let output = bitmap(size)
    output.interpolationQuality = .high
    output.draw(context.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
    return output.makeImage()!
}

func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "PNG export failed")
    return data as Data
}

func persist(_ data: Data, at url: URL) throws {
    if checking {
        let actual = try? Data(contentsOf: url)
        // PNG compression and subpixel edge coverage can vary across macOS SDKs.
        // Compare decoded pixels, allowing <1 channel level of average variation.
        let matches = url.pathExtension == "png"
            ? actual.map { samePixels($0, data) } ?? false
            : actual == data
        guard matches else {
            throw NSError(domain: "WgSenseBrand", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Stale or missing brand asset: \(url.lastPathComponent). Regenerate all sizes."])
        }
    } else {
        try data.write(to: url, options: .atomic)
    }
}

func samePixels(_ actual: Data, _ expected: Data) -> Bool {
    func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    guard let a = decode(actual), let b = decode(expected),
          a.width == b.width, a.height == b.height,
          a.alphaInfo != .none, a.alphaInfo != .noneSkipLast, a.alphaInfo != .noneSkipFirst else { return false }
    let first = bitmap(a.width), second = bitmap(b.width)
    let rect = CGRect(x: 0, y: 0, width: a.width, height: a.height)
    first.draw(a, in: rect); second.draw(b, in: rect)
    let bytes = a.width * a.height * 4
    let p = first.data!.assumingMemoryBound(to: UInt8.self)
    let q = second.data!.assumingMemoryBound(to: UInt8.self)
    var difference = 0
    for i in 0..<bytes { difference += abs(Int(p[i]) - Int(q[i])) }
    return Double(difference) / Double(bytes) < 0.75
}

let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: catalog.appendingPathComponent("Contents.json"))) as! [String: Any]
let entries = contents["images"] as! [[String: String]]
precondition(entries.count == 10, "Audit the macOS icon slot count before changing the catalog")
let expected = Set(entries.compactMap { $0["filename"] })
let present = Set(try FileManager.default.contentsOfDirectory(atPath: catalog.path).filter { $0.hasSuffix(".png") })
precondition(present.subtracting(expected).isEmpty, "Remove orphan icon PNGs from the catalog")
for entry in entries {
    let points = Int(entry["size"]!.split(separator: "x")[0])!
    let scale = Int(entry["scale"]!.dropLast())!
    let size = points * scale
    try persist(png(render(size)), at: catalog.appendingPathComponent(entry["filename"]!))
}

func number(_ value: CGFloat) -> String { String(Int(value)) }
func svg(for appearance: BrandAppearance) -> String {
let polygons = planes.map { plane in
    let points = plane.points.map { "\(number($0[0])),\(number($0[1]))" }.joined(separator: " ")
    return "    <polygon fill=\"#\(appearance.resolve(plane.color))\" points=\"\(points)\"/>"
}.joined(separator: "\n")
return """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1254 1254">
  <title>WgSense — bilateral breakthrough</title>
  <defs><clipPath id="tile"><rect x="102" y="104" width="1050" height="1044" rx="154"/></clipPath></defs>
  <g clip-path="url(#tile)">
    <rect x="102" y="104" width="1050" height="1044" fill="#\(appearance.background)"/>
\(polygons)
  </g>
</svg>

"""
}

let brandCatalog = catalog.deletingLastPathComponent().appendingPathComponent("BrandIcon.imageset")
if !checking { try FileManager.default.createDirectory(at: brandCatalog, withIntermediateDirectories: true) }
let brandContents = """
{
  "images": [
    { "filename": "brand-light.png", "idiom": "universal" },
    { "filename": "brand-dark.png", "idiom": "universal", "appearances": [{ "appearance": "luminosity", "value": "dark" }] }
  ],
  "info": { "author": "xcode", "version": 1 }
}

"""
try persist(Data(brandContents.utf8), at: brandCatalog.appendingPathComponent("Contents.json"))
for appearance in BrandAppearance.allCases {
    try persist(png(render(1024, appearance: appearance)), at: brandCatalog.appendingPathComponent("brand-\(appearance.rawValue).png"))
    let suffix = appearance == .dark ? "" : "-light"
    try persist(Data(svg(for: appearance).utf8), at: root.appendingPathComponent("branding/wgsense-icon\(suffix).svg"))
}
print("\(checking ? "Verified" : "Generated") 10/10 AppIcon sizes and 2/2 adaptive BrandIcon appearances, with both SVG masters.")
