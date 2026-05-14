#!/usr/bin/env swift
// Renders the four menu-bar SVGs from handoff/ into Assets.xcassets ImageSets at
// 22×22 (@1x) and 44×44 (@2x). Each set is marked as a Template Image so AppKit
// retints it for the menu-bar appearance — except the recording state, which
// has a colored accent dot baked in.
//
// Usage:  xcrun swift scripts/sync_menubar_icons.swift

import AppKit
import Foundation

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let handoff = projectRoot.appendingPathComponent("handoff")
let assets = projectRoot.appendingPathComponent("Dictly/Dictly/Assets.xcassets")

let states: [(state: String, template: Bool)] = [
    ("idle", true),
    ("recording", false),  // has the brand-red dot
    ("processing", true),
    ("disabled", false)    // has the red slash
]

func renderSVG(_ svgURL: URL, pixelSize: CGFloat) -> CGImage? {
    guard let img = NSImage(contentsOf: svgURL) else { return nil }
    img.size = NSSize(width: pixelSize, height: pixelSize)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: Int(pixelSize), height: Int(pixelSize),
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    img.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
             from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [.compressionFactor: 1.0]) else {
        throw NSError(domain: "render", code: 1)
    }
    try data.write(to: url)
}

for (state, isTemplate) in states {
    let svg = handoff.appendingPathComponent("menubar-\(state).svg")
    guard FileManager.default.fileExists(atPath: svg.path) else {
        fputs("missing \(svg.path)\n", stderr); exit(1)
    }
    let setURL = assets.appendingPathComponent("MenuBar-\(state).imageset")
    try? FileManager.default.createDirectory(at: setURL, withIntermediateDirectories: true)

    if let existing = try? FileManager.default.contentsOfDirectory(at: setURL,
                                                                    includingPropertiesForKeys: nil) {
        for f in existing where f.pathExtension == "png" {
            try? FileManager.default.removeItem(at: f)
        }
    }

    let f1 = "menubar-\(state).png"
    let f2 = "menubar-\(state)@2x.png"
    guard let img1 = renderSVG(svg, pixelSize: 22),
          let img2 = renderSVG(svg, pixelSize: 44) else {
        fputs("failed rendering \(state)\n", stderr); exit(1)
    }
    try writePNG(img1, to: setURL.appendingPathComponent(f1))
    try writePNG(img2, to: setURL.appendingPathComponent(f2))

    let contents: [String: Any] = [
        "images": [
            ["idiom": "mac", "scale": "1x", "filename": f1],
            ["idiom": "mac", "scale": "2x", "filename": f2]
        ],
        "info": ["author": "dictly", "version": 1],
        "properties": isTemplate ? ["template-rendering-intent": "template"] : [:]
    ]
    try JSONSerialization
        .data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: setURL.appendingPathComponent("Contents.json"))
    print("✓ MenuBar-\(state).imageset (\(isTemplate ? "template" : "color"))")
}
