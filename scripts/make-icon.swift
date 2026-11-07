// Writes Panes' app icon as an Icon Composer document (Resources/AppIcon.icon): the Focus
// layout (¼ · ½ · ¼) as Liquid Glass tiles on a blue field, the centre tile brighter like
// the drop target. Layered, so macOS 26 renders it properly in every icon style.
// Run from the project root:
//
//     swift scripts/make-icon.swift
//
// Open Resources/AppIcon.icon in Icon Composer (Xcode › Open Developer Tool) to fine-tune.
import AppKit

let side = 1024
let size = CGFloat(side)

let sky = (0.47, 0.71, 1.00)      // #78B5FF top left
let indigo = (0.15, 0.22, 0.60)   // #263899 bottom right
let dusk = (0.07, 0.10, 0.35)     // shadowed corner

let bundle = URL(fileURLWithPath: "Resources/AppIcon.icon", isDirectory: true)
let assets = bundle.appending(path: "Assets", directoryHint: .isDirectory)
try? FileManager.default.removeItem(at: bundle)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

func layer(_ name: String, draw: (CGContext) -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: assets.appending(path: name))
}

func radial(_ context: CGContext, center: CGPoint, radius: CGFloat, rgb: (Double, Double, Double), alpha: Double) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let colors = [CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, alpha])!,
                  CGColor(colorSpace: space, components: [rgb.0, rgb.1, rgb.2, 0])!]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// CG's origin is bottom-left: glow top-left, shade bottom-right.
try layer("glow.png") { radial($0, center: CGPoint(x: size * 0.12, y: size * 0.9), radius: size * 0.75, rgb: sky, alpha: 0.7) }
try layer("shade.png") { radial($0, center: CGPoint(x: size * 0.95, y: size * 0.05), radius: size * 0.7, rgb: dusk, alpha: 0.7) }

// The tiles: 560 × 400 pt, centred, 22 pt gaps, concentric-ish 40 pt corners.
let top = 312.0, height = 400.0, gap = 22.0, radius = 40.0
let left = 232.0, total = 560.0
let narrow = (total - 2 * gap) / 4, wide = narrow * 2
func tile(_ x: Double, _ width: Double) -> String {
    "<rect x=\"\(x)\" y=\"\(top)\" width=\"\(width)\" height=\"\(height)\" rx=\"\(radius)\" fill=\"#FFFFFF\"/>"
}
func svg(_ body: String) -> String {
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(side)\" height=\"\(side)\" viewBox=\"0 0 \(side) \(side)\">\n  \(body)\n</svg>\n"
}
try svg(tile(left + narrow + gap, wide)).write(to: assets.appending(path: "target.svg"), atomically: true, encoding: .utf8)
try svg(tile(left, narrow) + "\n  " + tile(left + narrow + gap + wide + gap, narrow))
    .write(to: assets.appending(path: "zones.svg"), atomically: true, encoding: .utf8)

func srgb(_ c: (Double, Double, Double)) -> String { String(format: "srgb:%.5f,%.5f,%.5f,1.00000", c.0, c.1, c.2) }

// Groups are listed front to back.
let document: [String: Any] = [
    "fill": [
        "linear-gradient": [srgb(sky), srgb(indigo)],
        "orientation": ["start": ["x": 0.15, "y": 0.0], "stop": ["x": 0.85, "y": 1.0]],
    ],
    "groups": [
        [
            "name": "Target",
            "layers": [["name": "Target", "image-name": "target.svg", "glass": true]],
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.25],
            "specular": true,
        ],
        [
            "name": "Zones",
            "layers": [["name": "Zones", "image-name": "zones.svg", "glass": true, "opacity": 0.75]],
            "shadow": ["kind": "neutral", "opacity": 0.35],
            "translucency": ["enabled": true, "value": 0.55],
            "specular": true,
        ],
        [
            "name": "Field",
            "layers": [
                ["name": "Glow", "image-name": "glow.png", "glass": false],
                ["name": "Shade", "image-name": "shade.png", "glass": false],
            ],
            "shadow": ["kind": "none", "opacity": 0],
            "translucency": ["enabled": false, "value": 0],
            "specular": false,
        ],
    ],
    "supported-platforms": ["squares": "shared"],
]
try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    .write(to: bundle.appending(path: "icon.json"))
print("Wrote \(bundle.path)")
