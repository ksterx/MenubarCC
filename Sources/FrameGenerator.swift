import Cocoa

struct AnimationFrames {
    let walk: [NSImage]
    let bounce: [NSImage]
    let pulse: [NSImage]
    let staticFrame: NSImage
}

private let iconPointHeight: CGFloat = 16

func generateFrames(from source: NSImage) -> AnimationFrames {
    guard let tiff = source.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cgSource = rep.cgImage else {
        fatalError("Cannot get CGImage from source")
    }

    let cropped = cropTransparent(cgSource)
    let cw = cropped.width
    let ch = cropped.height
    let pad = 36
    let canvasW = cw + pad
    let canvasH = 44
    let cy = (canvasH - ch) / 2

    let cs = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    func blank() -> CGContext {
        CGContext(
            data: nil, width: canvasW, height: canvasH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: bitmapInfo
        )!
    }

    func makeImage(_ ctx: CGContext) -> NSImage {
        let cgImg = ctx.makeImage()!
        let img = NSImage(cgImage: cgImg, size: NSSize(width: canvasW, height: canvasH))
        let scale = iconPointHeight / CGFloat(canvasH)
        img.size = NSSize(width: CGFloat(canvasW) * scale, height: iconPointHeight)
        return img
    }

    // CG origin is bottom-left; PIL origin is top-left.
    // PIL: paste(crab, (x, topY))  →  CG: draw at y = canvasH - topY - ch
    func drawCrab(_ ctx: CGContext, x: Int, topY: Int) {
        let cgY = canvasH - topY - ch
        ctx.draw(cropped, in: CGRect(x: x, y: cgY, width: cw, height: ch))
    }

    // Walk: crab slides right → left
    let walkN = 14
    var walk: [NSImage] = []
    for i in 0..<walkN {
        let t = Double(i) / Double(walkN - 1)
        let x = Int((1 - t) * Double(pad))
        let ctx = blank()
        drawCrab(ctx, x: x, topY: cy)
        walk.append(makeImage(ctx))
    }

    // Bounce: asymmetric arc (ease-out up, ease-in down)
    let upN = 3, hangN = 1, downN = 5, bounceH = 16
    var bounce: [NSImage] = []

    func addBounce(_ yOffset: Int) {
        let ctx = blank()
        drawCrab(ctx, x: pad / 2, topY: cy - yOffset)
        bounce.append(makeImage(ctx))
    }

    for i in 0..<upN {
        let t = Double(i + 1) / Double(upN)
        addBounce(Int((1 - pow(1 - t, 2)) * Double(bounceH)))
    }
    for _ in 0..<hangN { addBounce(bounceH) }
    for i in 0..<downN {
        let t = Double(i + 1) / Double(downN)
        addBounce(Int((1 - pow(t, 2)) * Double(bounceH)))
    }

    // Pulse: alpha flash (sine wave)
    let pulseN = 8
    var pulse: [NSImage] = []
    for i in 0..<pulseN {
        let alpha = (128.0 + 127.0 * sin(2 * .pi * Double(i) / Double(pulseN))) / 255.0
        let ctx = blank()
        ctx.setAlpha(CGFloat(alpha))
        drawCrab(ctx, x: pad / 2, topY: cy)
        pulse.append(makeImage(ctx))
    }

    // Static (idle)
    let sctx = blank()
    drawCrab(sctx, x: pad / 2, topY: cy)
    let staticFrame = makeImage(sctx)

    return AnimationFrames(walk: walk, bounce: bounce, pulse: pulse, staticFrame: staticFrame)
}

private func cropTransparent(_ image: CGImage) -> CGImage {
    let w = image.width, h = image.height
    guard let data = image.dataProvider?.data,
          let ptr = CFDataGetBytePtr(data) else { return image }

    let bpr = image.bytesPerRow
    let bpp = image.bitsPerPixel / 8
    var minX = w, minY = h, maxX = 0, maxY = 0

    for y in 0..<h {
        for x in 0..<w {
            let offset = y * bpr + x * bpp
            let alpha = ptr[offset + bpp - 1]
            if alpha > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }

    guard maxX >= minX, maxY >= minY else { return image }
    let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    return image.cropping(to: rect) ?? image
}
