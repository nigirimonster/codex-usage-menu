import AppKit
import Foundation

let options: [(String, String)] = [
    ("speedometer", "Speedometer"),
    ("sparkles", "AI"),
    ("cpu.fill", "CPU"),
    ("circle.hexagonpath.fill", "Token"),
    ("hexagon", "Hexagon")
]

let scale: CGFloat = 2
let cellWidth: CGFloat = 220
let cellHeight: CGFloat = 132
let columns = 2
let rows = Int(ceil(Double(options.count) / Double(columns)))
let size = NSSize(width: CGFloat(columns) * cellWidth, height: CGFloat(rows) * cellHeight)
let image = NSImage(size: size)

image.lockFocus()
NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
NSRect(origin: .zero, size: size).fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
paragraph.lineBreakMode = .byTruncatingTail

for (index, option) in options.enumerated() {
    let col = index % columns
    let row = index / columns
    let x = CGFloat(col) * cellWidth
    let y = CGFloat(row) * cellHeight
    let cell = NSRect(x: x + 10, y: y + 10, width: cellWidth - 20, height: cellHeight - 20)
    let card = NSBezierPath(roundedRect: cell, xRadius: 10, yRadius: 10)
    NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
    card.fill()
    NSColor(calibratedWhite: 1, alpha: 0.15).setStroke()
    card.lineWidth = 1
    card.stroke()

    let symbolConfig = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
    let symbol = NSImage(systemSymbolName: option.0, accessibilityDescription: option.1)?
        .withSymbolConfiguration(symbolConfig)

    if let symbol {
        let iconRect = NSRect(x: x + (cellWidth - 44) / 2, y: y + 21, width: 44, height: 44)
        NSColor.white.set()
        symbol.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
    } else {
        "N/A".draw(in: NSRect(x: x + 40, y: y + 32, width: cellWidth - 80, height: 30), withAttributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
            .paragraphStyle: paragraph
        ])
    }

    option.1.draw(in: NSRect(x: x + 16, y: y + 72, width: cellWidth - 32, height: 20), withAttributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ])

    option.0.draw(in: NSRect(x: x + 16, y: y + 94, width: cellWidth - 32, height: 18), withAttributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.62),
        .paragraphStyle: paragraph
    ])
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not render icon sheet")
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
