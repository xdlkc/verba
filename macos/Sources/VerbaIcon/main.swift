import AppKit
import Foundation

// Usage: VerbaIcon <output.iconset> [--dev]
@main
struct VerbaIconApp {
    static func main() {
        let args = CommandLine.arguments
        let outDir = args.count > 1 ? args[1] : "AppIcon.iconset"
        let isDev = args.contains("--dev")

        let fm = FileManager.default
        try? fm.removeItem(atPath: outDir)
        try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let sizes: [(Int, String)] = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]

        for (px, name) in sizes {
            let png = renderIcon(size: px, devBadge: isDev)
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
            try! png.write(to: url)
        }
    }

    static func renderIcon(size: Int, devBadge: Bool) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let ctx = NSGraphicsContext.current!.cgContext
        let s = CGFloat(size)

        // Outer macOS icon margin (~9.5%)
        let inset = s * 0.095
        let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let corner = cardRect.width * 0.225
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()

        // Rich slate-ink radial gradient background
        let cs = CGColorSpaceCreateDeviceRGB()
        let bgColors = [
            CGColor(srgbRed: 0.145, green: 0.160, blue: 0.205, alpha: 1),
            CGColor(srgbRed: 0.082, green: 0.092, blue: 0.120, alpha: 1),
        ] as CFArray
        let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1])!
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
            options: []
        )

        // Subtle warm glow behind the waveform
        let glowColors = [
            CGColor(srgbRed: 0.910, green: 0.333, blue: 0.169, alpha: 0.26),
            CGColor(srgbRed: 0.910, green: 0.333, blue: 0.169, alpha: 0.0),
        ] as CFArray
        let glow = CGGradient(colorsSpace: cs, colors: glowColors, locations: [0, 1])!
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: s * 0.5, y: s * 0.52),
            startRadius: 0,
            endCenter: CGPoint(x: s * 0.5, y: s * 0.52),
            endRadius: cardRect.width * 0.48,
            options: []
        )

        // Asymmetric acoustic bars forming an abstract "V" + dialogue wave motif
        let bars: [(CGFloat, CGFloat, Bool)] = [
            (0.28, 0.28, false),
            (0.39, 0.44, true),
            (0.50, 0.54, false),
            (0.61, 0.38, true),
            (0.72, 0.24, false),
        ]
        let barW = cardRect.width * 0.078
        for (nx, nh, isCoral) in bars {
            let h = cardRect.height * nh
            let x = s * nx - barW * 0.5
            let y = s * 0.52 - h * 0.5
            let r = CGRect(x: x, y: y, width: barW, height: h)
            let p = CGPath(roundedRect: r, cornerWidth: barW * 0.5, cornerHeight: barW * 0.5, transform: nil)
            ctx.addPath(p)
            if isCoral {
                ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.36, blue: 0.19, alpha: 1))
            } else {
                ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.965, blue: 0.98, alpha: 0.96))
            }
            ctx.fillPath()
        }

        // Subtitle ribbon bar underneath
        let lineW = cardRect.width * 0.44
        let lineH = max(2, cardRect.height * 0.048)
        let lineRect = CGRect(x: s * 0.5 - lineW * 0.5, y: s * 0.21, width: lineW, height: lineH)
        ctx.addPath(CGPath(roundedRect: lineRect, cornerWidth: lineH * 0.5, cornerHeight: lineH * 0.5, transform: nil))
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.36, blue: 0.19, alpha: 0.92))
        ctx.fillPath()

        if devBadge && size >= 64 {
            // Diagonal DEV badge in bottom-right corner
            ctx.saveGState()
            ctx.translateBy(x: cardRect.maxX - cardRect.width * 0.16, y: cardRect.minY + cardRect.height * 0.16)
            ctx.rotate(by: .pi / 4)
            let bw = cardRect.width * 0.58
            let bh = cardRect.height * 0.15
            ctx.setFillColor(CGColor(srgbRed: 0.91, green: 0.33, blue: 0.17, alpha: 1))
            ctx.fill(CGRect(x: -bw / 2, y: -bh / 2, width: bw, height: bh))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: bh * 0.62, weight: .black),
                .foregroundColor: NSColor.white,
            ]
            let label = NSAttributedString(string: "DEV", attributes: attrs)
            let ts = label.size()
            label.draw(at: NSPoint(x: -ts.width / 2, y: -ts.height / 2))
            ctx.restoreGState()
        }

        ctx.restoreGState()

        // Crisp 1px inner border
        ctx.addPath(cardPath)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
        ctx.setLineWidth(max(1, s * 0.012))
        ctx.strokePath()

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
